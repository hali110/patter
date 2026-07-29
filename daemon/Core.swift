// Core.swift — paths, logging, subprocesses. Shared by the daemon and test harnesses.
import Foundation

// Derived, never hardcoded: walk up from the executable until transcribe.sh appears.
// Under LaunchServices that is DictateDaemon.app/Contents/MacOS -> repo root.
let rootDir: String = {
    var url = Bundle.main.bundleURL
    for _ in 0..<6 {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("transcribe.sh").path) {
            return url.path
        }
        url = url.deletingLastPathComponent()
    }
    return Bundle.main.bundleURL.deletingLastPathComponent().path
}()

let logPath = rootDir + "/daemon.log"
let modelPath = rootDir + "/models/ggml-large-v3-turbo.bin"
// Only loaded for the right-⌘ refine path. Absent is a supported state: the daemon
// runs normally and refine falls back to pasting the raw transcript.
let refineModelPath = rootDir + "/models/refine-q4.gguf"

private let logFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

func log(_ s: String) {
    print("\(logFormatter.string(from: Date())) \(s)")
    fflush(stdout)
}

func ms(_ since: Date) -> Int { Int(Date().timeIntervalSince(since) * 1000) }

/// Rotates the log if it has grown, then redirects stdout into it — under
/// LaunchServices the daemon's stdout goes nowhere, so it must log to a file itself.
/// A daemon that runs for months must not grow an unbounded log.
func redirectLogToFile() {
    if let size = (try? FileManager.default.attributesOfItem(atPath: logPath))?[.size] as? Int, size > 1_000_000 {
        try? FileManager.default.removeItem(atPath: logPath + ".1")
        try? FileManager.default.moveItem(atPath: logPath, toPath: logPath + ".1")
    }
    freopen(logPath, "a", stdout)
}

/// Quotes a string as one shell argument. Dictated text is arbitrary text: an
/// apostrophe in "don't" would otherwise close the quoting and the rest of the
/// sentence would be run as a command.
func esc(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

@discardableResult
func shell(_ cmd: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", cmd]
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    do { try p.run() } catch {
        log("shell: failed to spawn /bin/sh — \(error.localizedDescription)")
        return ""
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        log("shell: exit \(p.terminationStatus) — \(msg.isEmpty ? cmd : msg)")
    }
    return String(data: data, encoding: .utf8) ?? ""
}
