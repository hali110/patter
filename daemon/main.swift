// dictate-daemon — hold RIGHT OPTION anywhere: record → local whisper → paste at cursor.
// Menu bar: 🎤 idle, 🔴 recording, … transcribing. No cloud, no telemetry, no deps.
import Cocoa
import ApplicationServices

let toolDir = FileManager.default.homeDirectoryForCurrentUser.path + "/Documents/claude/tools/dictate"
let wavPath = NSTemporaryDirectory() + "dictate-rec.wav"

func log(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("\(ts) \(s)")
    fflush(stdout)
}

@discardableResult
func shell(_ cmd: String) -> String {
    let p = Process()
    p.launchPath = "/bin/sh"
    p.arguments = ["-c", cmd]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

final class Dictator: NSObject {
    var statusItem: NSStatusItem!
    var ffmpeg: Process?
    var busy = false

    func icon(_ name: String) {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "dictate")
        img?.isTemplate = true  // template = auto white/black matching menu bar appearance
        statusItem.button?.image = img
    }

    func setup() {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        icon("mic")
        let menu = NSMenu()
        let info = NSMenuItem(title: "hold right ⌥ to dictate", action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit dictate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        if AXIsProcessTrusted() {
            log("accessibility: trusted — paste will work")
        } else {
            log("accessibility: NOT trusted — transcripts will stay on the clipboard; grant in the dialog (or System Settings → Privacy & Security → Accessibility → your terminal), then: dictate stop && dictate start")
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        ensureServer()
        startTap()
    }

    func ensureServer() {
        shell("curl -s -o /dev/null --max-time 0.3 http://127.0.0.1:8090/ || (nohup /opt/homebrew/bin/whisper-server -m '\(toolDir)/models/ggml-large-v3-turbo.bin' --port 8090 --host 127.0.0.1 >/dev/null 2>&1 &)")
    }

    func startTap() {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, refcon in
                Unmanaged<Dictator>.fromOpaque(refcon!).takeUnretainedValue().handle(event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            print("NEEDS ACCESSIBILITY: System Settings → Privacy & Security → Accessibility → enable your terminal app, then rerun: dictate daemon")
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            exit(1)
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("event tap active")
    }

    func handle(_ event: CGEvent) {
        guard event.getIntegerValueField(.keyboardEventKeycode) == 61 else { return }  // right option
        log("right-option \(event.flags.contains(.maskAlternate) ? "down" : "up")")
        if event.flags.contains(.maskAlternate) { startRec() } else { stopRec() }
    }

    func startRec() {
        guard ffmpeg == nil, !busy else { return }
        log("rec start")
        icon("mic.fill")
        let p = Process()
        p.launchPath = "/opt/homebrew/bin/ffmpeg"
        p.arguments = ["-y", "-loglevel", "quiet", "-f", "avfoundation", "-i", ":0",
                       "-ar", "16000", "-ac", "1", wavPath]
        p.standardError = FileHandle.nullDevice
        try? p.run()
        ffmpeg = p
    }

    func stopRec() {
        guard let p = ffmpeg else { return }
        ffmpeg = nil
        busy = true
        icon("ellipsis")
        DispatchQueue.global().async {
            p.interrupt()
            p.waitUntilExit()
            let size = (try? FileManager.default.attributesOfItem(atPath: wavPath))?[.size] as? Int ?? 0
            log("rec stop, wav \(size) bytes")
            let txt = shell("sh '\(toolDir)/transcribe.sh' '\(wavPath)'")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            log("transcript: \(txt.isEmpty ? "(empty)" : txt)")
            DispatchQueue.main.async {
                if !txt.isEmpty { self.paste(txt) }
                self.icon("mic")
                self.busy = false
            }
        }
    }

    func paste(_ text: String) {
        let pb = NSPasteboard.general
        let old = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
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
            if let o = old { pb.clearContents(); pb.setString(o, forType: .string) }
        }
    }
}

let app = NSApplication.shared
let dictator = Dictator()
dictator.setup()
print("dictate-daemon running — hold right ⌥ anywhere; 🎤 in menu bar")
app.run()
