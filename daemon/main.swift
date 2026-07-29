// dictate-daemon — hold RIGHT OPTION anywhere: record → local whisper → paste at cursor.
// Menu bar: mic idle, mic.fill recording, ellipsis transcribing. No cloud, no telemetry.
// Paths, logging and subprocesses live in Core.swift; capture in Recorder.swift.
import Cocoa
import AVFoundation
import ApplicationServices
import IOKit.hid

redirectLogToFile()

// MARK: - Daemon

final class Dictator: NSObject {
    private var statusItem: NSStatusItem!
    private var eventTap: CFMachPort?
    private let recorder = Recorder()
    // Serial: utterances transcribe and paste in the order they were spoken, and a
    // new recording can start while the previous one is still transcribing.
    private let work = DispatchQueue(label: "dictate.transcribe")
    private var recording = false
    private var inFlight = 0
    private var seq = 0
    private var startedAt = Date()
    private var wavURL = URL(fileURLWithPath: "/dev/null")

    func setup() {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        icon("mic")

        let menu = NSMenu()
        let info = NSMenuItem(title: "hold right ⌥ to dictate", action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
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
            log("accessibility: NOT trusted — transcripts will stay on the clipboard; add DictateDaemon.app in System Settings → Privacy & Security → Accessibility (re-toggle after every rebuild), then: dictate stop && dictate start")
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
        let t0 = Date()
        work.async {
            let up = shell("curl -s -o /dev/null --max-time 0.3 http://127.0.0.1:8090/ && echo up").contains("up")
            if up { log("server: already resident (\(ms(t0))ms)"); return }
            log("server: loading model, first utterance may be slow")
            shell("nohup /opt/homebrew/bin/whisper-server -m '\(modelPath)' --port 8090 --host 127.0.0.1 >/dev/null 2>&1 &")
            for _ in 0..<120 {
                if shell("curl -s -o /dev/null --max-time 0.3 http://127.0.0.1:8090/ && echo up").contains("up") {
                    log("server: resident (\(ms(t0))ms)")
                    return
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
            log("server: FAILED to come up in 30s — transcription will fall back to whisper-cli (~10s/utterance)")
        }
    }

    private func startTap() {
        // Listening to keystrokes from other apps is gated on Input Monitoring, which is
        // a *different* TCC service from Accessibility (that one covers posting the ⌘V).
        let listen = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        switch listen {
        case kIOHIDAccessTypeGranted: log("input monitoring: granted")
        case kIOHIDAccessTypeDenied:
            log("input monitoring: DENIED — enable DictateDaemon.app in System Settings → Privacy & Security → Input Monitoring")
        default:
            log("input monitoring: not yet determined — prompting")
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }

        // flagsChanged carries the hotkey; the two tapDisabled types are how the OS
        // tells us it has muted us. Subscribing to them is what makes recovery possible.
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
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
        guard event.getIntegerValueField(.keyboardEventKeycode) == 61 else { return }  // right option
        // Test the device-specific right-option bit, not .maskAlternate: with left ⌥
        // also held, maskAlternate stays set on right-⌥ release and we would never stop.
        let down = event.flags.rawValue & 0x40 != 0  // NX_DEVICERALTKEYMASK
        DispatchQueue.main.async { down ? self.startRec() : self.stopRec() }
    }

    private func startRec() {
        guard !recording else { return }
        seq += 1
        wavURL = URL(fileURLWithPath: NSTemporaryDirectory() + "dictate-\(seq).wav")
        do {
            let startMs = try recorder.start(to: wavURL)
            recording = true
            startedAt = Date()
            icon("mic.fill")
            // Frontmost app is the first thing you want when "it works here but not there".
            let target = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
            log("[\(seq)] rec start (hw \(startMs)ms) target=\(target)")
        } catch {
            log("[\(seq)] rec start FAILED — \(error.localizedDescription)")
            icon("exclamationmark.triangle")
        }
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

    private func stopRec() {
        guard recording else { return }
        recording = false
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
            let txt = shell("sh '\(rootDir)/transcribe.sh' '\(url.path)'")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let transcribeMs = ms(t0)
            try? FileManager.default.removeItem(at: url)

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
                if self.inFlight == 0 && !self.recording { self.icon("mic") }
                log("[\(n)] audio=\(String(format: "%.1f", seconds))s peak=\(String(format: "%.3f", take.peak)) "
                    + "transcribe=\(transcribeMs)ms paste=\(pasteMs)ms total=\(ms(released))ms "
                    + "· \(txt.isEmpty ? "(empty)" : txt)")
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
