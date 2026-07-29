// dictate-daemon — hold a key anywhere, speak, release, text lands at the cursor.
//
//   right ⌥  record → whisper → paste verbatim          (~400ms)
//   right ⌘  record → whisper → local LLM → paste       (~1.5–3s, restructured)
//
// The two are separate keys rather than one key plus a setting so that the fast
// path stays provably untouched: dictating a commit message or a command must
// never go near a model that rewrites words.
// Menu bar: mic idle, mic.fill recording, ellipsis transcribing. No cloud, no telemetry.
// Paths, logging and subprocesses live in Core.swift; capture in Recorder.swift.
import Cocoa
import AVFoundation
import ApplicationServices
import IOKit.hid

redirectLogToFile()

// MARK: - Daemon

/// Which hotkey started the take, and therefore what happens to the text.
enum Mode {
    case raw      // right ⌥ — whisper only
    case refine   // right ⌘ — whisper, then the local LLM

    /// The device-specific modifier bit, not the generic mask: with the left key of
    /// the same pair also held, the generic mask stays set on release and the take
    /// would never stop.
    var keycode: Int64 { self == .raw ? 61 : 54 }
    var flagBit: UInt64 { self == .raw ? 0x40 : 0x10 }  // NX_DEVICERALTKEYMASK / NX_DEVICERCMDKEYMASK
    var label: String { self == .raw ? "raw" : "refine" }
}

final class Dictator: NSObject {
    private var statusItem: NSStatusItem!
    private var eventTap: CFMachPort?
    private let recorder = Recorder()
    // Serial: utterances transcribe and paste in the order they were spoken, and a
    // new recording can start while the previous one is still transcribing.
    private let work = DispatchQueue(label: "dictate.transcribe")
    // Separate from `work`: model loading blocks for up to 60s per server, and an
    // utterance spoken during startup must not queue behind it.
    private let boot = DispatchQueue(label: "dictate.boot")
    private var recordingMode: Mode?
    private var inFlight = 0
    private var seq = 0
    private var startedAt = Date()
    private var wavURL = URL(fileURLWithPath: "/dev/null")

    func setup() {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        icon("mic")

        let menu = NSMenu()
        for line in ["hold right ⌥ — dictate verbatim", "hold right ⌘ — dictate, AI-restructured"] {
            let info = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Reveal Log", action: #selector(revealLog), keyEquivalent: "l"))
        menu.addItem(NSMenuItem(title: "Quit dictate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.items.forEach { if $0.action == #selector(revealLog) { $0.target = self } }
        statusItem.menu = menu

        log("root: \(rootDir)")
        if !FileManager.default.fileExists(atPath: modelPath) {
            log("model: MISSING at \(modelPath) — run: dictate doctor")
        }

        if AXIsProcessTrusted() {
            log("accessibility: trusted — paste will work")
        } else {
            // The full path, because the grant is made in a file picker and the app
            // lives several folders deep. "DictateDaemon.app" alone sent a past
            // session hunting for a `bin/` binary that has not existed since 7ce26f0.
            log("accessibility: NOT trusted — transcripts will stay on the clipboard; in System Settings → Privacy & Security → Accessibility add (⌘⇧G to paste the path): \(Bundle.main.bundleURL.path) — it appears in the list as \"DictateDaemon\". Re-toggle after every rebuild, then: dictate stop && dictate start")
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }

        requestMic { granted in
            log("microphone: \(granted ? "granted" : "DENIED — enable in System Settings → Privacy & Security → Microphone")")
            if granted { _ = self.recorder.prepare() }
        }
        ensureServer()
        startTap()
    }

    @objc private func revealLog() {
        NSWorkspace.shared.selectFile(logPath, inFileViewerRootedAtPath: rootDir)
    }

    private func icon(_ name: String) {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "dictate")
        img?.isTemplate = true  // template = auto white/black matching menu bar appearance
        statusItem.button?.image = img
    }

    private func requestMic(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }

    private func ensureServer() {
        guard FileManager.default.fileExists(atPath: modelPath) else { return }
        spawnServer(name: "whisper", port: 8090, probe: "/",
                    cmd: "/opt/homebrew/bin/whisper-server -m '\(modelPath)' --port 8090 --host 127.0.0.1",
                    onFail: "transcription will fall back to whisper-cli (~10s/utterance)")

        // Absent model is not an error: the daemon is fully usable on right ⌥ alone,
        // and right ⌘ degrades to pasting the raw transcript rather than breaking.
        guard FileManager.default.fileExists(atPath: refineModelPath) else {
            log("refine: model missing at \(refineModelPath) — right ⌘ will paste raw transcripts; run: dictate doctor")
            return
        }
        // -ngl 99 puts every layer on Metal; without it llama.cpp runs on CPU and the
        // refine stage goes from ~1.5s to tens of seconds.
        spawnServer(name: "refine", port: 8091, probe: "/health",
                    cmd: "/opt/homebrew/bin/llama-server -m '\(refineModelPath)' --port 8091 --host 127.0.0.1 "
                       + "-ngl 99 -c 4096 -fa on --no-webui",
                    onFail: "right ⌘ will paste raw transcripts")
    }

    /// Model load is ~5–10s, so it happens once at startup and never on the hot path.
    private func spawnServer(name: String, port: Int, probe: String, cmd: String, onFail: String) {
        let t0 = Date()
        let up = "curl -s -o /dev/null --max-time 0.3 http://127.0.0.1:\(port)\(probe) && echo up"
        boot.async {
            if shell(up).contains("up") { log("\(name): already resident (\(ms(t0))ms)"); return }
            log("\(name): loading model, first use may be slow")
            // Into the repo, not /dev/null: when a server dies at load (bad model,
            // port taken, out of memory) its own stderr is the only thing that says
            // why, and discarding it leaves the daemon reporting a bare timeout.
            shell("nohup \(cmd) >> \(esc(rootDir + "/servers.log")) 2>&1 &")
            for _ in 0..<240 {
                if shell(up).contains("up") { log("\(name): resident (\(ms(t0))ms)"); return }
                Thread.sleep(forTimeInterval: 0.25)
            }
            log("\(name): FAILED to come up in 60s — \(onFail)")
        }
    }

    private func startTap() {
        // Listening to keystrokes from other apps is gated on Input Monitoring, which is
        // a *different* TCC service from Accessibility (that one covers posting the ⌘V).
        let listen = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        switch listen {
        case kIOHIDAccessTypeGranted: log("input monitoring: granted")
        case kIOHIDAccessTypeDenied:
            log("input monitoring: DENIED — in System Settings → Privacy & Security → Input Monitoring add (⌘⇧G): \(Bundle.main.bundleURL.path) — listed as \"DictateDaemon\". This is a separate grant from Accessibility; the hotkey is deaf without it.")
        default:
            log("input monitoring: not yet determined — prompting")
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }

        // flagsChanged carries the hotkey; the two tapDisabled types are how the OS
        // tells us it has muted us. Subscribing to them is what makes recovery possible.
        // keyDown is subscribed only to cancel a take (see handle): right ⌘ is half of
        // every shortcut on the system, so "held ⌘, then pressed S" must not paste a
        // fragment into the document that just saved. Nothing about the key is read
        // beyond the fact that one arrived, and the tap is listenOnly.
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByTimeout.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByUserInput.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                Unmanaged<Dictator>.fromOpaque(refcon!).takeUnretainedValue().handle(type, event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            log("event tap creation failed — add DictateDaemon.app in System Settings → Privacy & Security → Accessibility, then rerun: dictate start")
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            exit(1)
        }
        eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("event tap active")
    }

    /// Runs on the tap's callback thread. macOS disables any tap whose callback misses
    /// its deadline, so this must stay non-blocking — all real work hops to main.
    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let why = type == .tapDisabledByTimeout ? "callback too slow" : "secure input engaged"
            log("event tap DISABLED by system (\(why)) — re-enabling")
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        // A real keystroke during a take means the hold was the start of a shortcut,
        // not dictation. Discard rather than paste a fragment into the focused app.
        if type == .keyDown {
            DispatchQueue.main.async { self.cancelRec() }
            return
        }

        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard let mode: Mode = (code == Mode.raw.keycode) ? .raw
                             : (code == Mode.refine.keycode) ? .refine : nil else { return }
        let down = event.flags.rawValue & mode.flagBit != 0
        DispatchQueue.main.async { down ? self.startRec(mode) : self.stopRec(mode) }
    }

    private func startRec(_ mode: Mode) {
        guard recordingMode == nil else { return }  // the other hotkey already owns this take
        seq += 1
        wavURL = URL(fileURLWithPath: NSTemporaryDirectory() + "dictate-\(seq).wav")
        do {
            let startMs = try recorder.start(to: wavURL)
            recordingMode = mode
            startedAt = Date()
            icon(mode == .raw ? "mic.fill" : "wand.and.rays")
            // Frontmost app is the first thing you want when "it works here but not there".
            let target = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
            log("[\(seq)] rec start \(mode.label) (hw \(startMs)ms) target=\(target)")
        } catch {
            log("[\(seq)] rec start FAILED — \(error.localizedDescription)")
            icon("exclamationmark.triangle")
        }
    }

    /// A key was pressed mid-take, so the modifier hold was a shortcut. Throw the
    /// audio away without transcribing it — nothing should reach the focused app.
    private func cancelRec() {
        guard recordingMode != nil else { return }
        recordingMode = nil
        let take = recorder.stop()
        try? FileManager.default.removeItem(at: wavURL)
        log("[\(seq)] cancelled (key pressed during hold): \(String(format: "%.2f", take.seconds))s")
        if inFlight == 0 { icon("mic") }
    }

    /// An accidental brush of the key must never inject text. Whisper is a language
    /// model with a decoder that always emits *something*: fed silence it returns
    /// confident, fluent sentences ("Get there, Kevin got even faster!"). So a take
    /// that cannot plausibly contain speech is dropped before it ever reaches whisper.
    ///
    /// The peak floor is deliberately far below room tone (a quiet room with a TV on
    /// measures ~0.02–0.04) — it exists to catch a muted or dead mic, not to do voice
    /// activity detection. Every take logs its peak so this can be tuned from real use.
    private static let minSeconds = 0.35
    private static let minPeak: Float = 0.01

    private func stopRec(_ mode: Mode) {
        // Only the key that started this take may end it, so releasing the other
        // modifier mid-utterance cannot stop a recording it did not begin.
        guard recordingMode == mode else { return }
        recordingMode = nil
        let n = seq, url = wavURL, released = Date()
        let take = recorder.stop()
        let seconds = take.seconds

        if seconds < Self.minSeconds || take.peak < Self.minPeak {
            let why = seconds < Self.minSeconds ? "too short" : "silent"
            log("[\(n)] dropped (\(why)): \(String(format: "%.2f", seconds))s peak=\(String(format: "%.4f", take.peak))")
            try? FileManager.default.removeItem(at: url)
            if inFlight == 0 { icon("mic") }
            return
        }

        inFlight += 1
        icon("ellipsis")

        work.async {
            let t0 = Date()
            let raw = shell("sh '\(rootDir)/transcribe.sh' '\(url.path)'")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let transcribeMs = ms(t0)
            try? FileManager.default.removeItem(at: url)

            // refine.sh is fail-open by contract: on any error it echoes its input and
            // explains on stderr, so `txt` is never emptier than the raw transcript.
            var txt = raw, refineMs = 0
            if mode == .refine && !raw.isEmpty {
                DispatchQueue.main.async { if self.recordingMode == nil { self.icon("sparkles") } }
                let t1 = Date()
                txt = shell("printf '%s' \(esc(raw)) | sh '\(rootDir)/refine.sh'")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                refineMs = ms(t1)
                if txt.isEmpty { log("[\(n)] refine returned nothing — pasting raw"); txt = raw }
            }

            DispatchQueue.main.async {
                var pasteMs = 0
                if txt.isEmpty {
                    log("[\(n)] EMPTY transcript for \(String(format: "%.1f", seconds))s of audio at peak \(String(format: "%.3f", take.peak))")
                } else {
                    let t1 = Date()
                    self.paste(txt + " ")  // trailing space so back-to-back utterances don't fuse
                    pasteMs = ms(t1)
                }
                self.inFlight -= 1
                if self.inFlight == 0 && self.recordingMode == nil { self.icon("mic") }
                log("[\(n)] \(mode.label) audio=\(String(format: "%.1f", seconds))s peak=\(String(format: "%.3f", take.peak)) "
                    + "transcribe=\(transcribeMs)ms \(mode == .refine ? "refine=\(refineMs)ms " : "")"
                    + "paste=\(pasteMs)ms total=\(ms(released))ms "
                    + "· \(txt.isEmpty ? "(empty)" : txt)")
                // The model can silently drop a requirement, and the spoken original is
                // then gone for good. Both texts are always recoverable from the log.
                if mode == .refine && txt != raw { log("[\(n)]   raw: \(raw)") }
            }
        }
    }

    private func paste(_ text: String) {
        let pb = NSPasteboard.general
        let old = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        let stamp = pb.changeCount

        guard AXIsProcessTrusted() else {
            log("paste blocked (no accessibility) — transcript left on clipboard, ⌘V manually")
            return
        }
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)   // V
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Only restore if nothing else claimed the pasteboard meanwhile — otherwise
            // a fast second utterance would be clobbered by the first one's restore.
            guard pb.changeCount == stamp, let o = old else { return }
            pb.clearContents()
            pb.setString(o, forType: .string)
        }
    }
}

let app = NSApplication.shared
let dictator = Dictator()
dictator.setup()
app.run()
