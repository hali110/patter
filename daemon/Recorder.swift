// Recorder.swift — in-process 16 kHz mono capture.
//
// Deliberately not ffmpeg: `-f avfoundation` spends ~300ms enumerating devices
// (video included, Continuity Camera and all) before the first sample lands, so a
// press-and-speak user loses their first syllable. AVAudioEngine costs ~100ms.
// See CLAUDE.md's latency budget; verify with tests/capture-probe.swift.
import AVFoundation

final class Recorder {
    private let engine = AVAudioEngine()
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                          channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var file: AVAudioFile?
    private let lock = NSLock()
    private var writeFailureLogged = false
    private var observing = false
    private var peak: Float = 0

    /// What a finished recording amounted to. `peak` is 0…1 full scale.
    struct Take { let seconds: Double; let peak: Float }

    /// Allocates engine resources up front so key-down only pays for the hardware start.
    @discardableResult
    func prepare() -> Bool {
        let native = engine.inputNode.inputFormat(forBus: 0)
        guard native.sampleRate > 0 else {
            log("capture: no input device (format 0 Hz) — check Microphone permission")
            return false
        }
        guard let conv = AVAudioConverter(from: native, to: outFormat) else {
            log("capture: cannot convert \(native.sampleRate)Hz/\(native.channelCount)ch to 16kHz mono")
            return false
        }
        converter = conv
        // 1024 frames ≈ 21ms. Whatever is in the in-progress buffer when the key is
        // released is lost, so this is the tail-clipping budget — keep it small.
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: native) { [weak self] buf, _ in
            self?.append(buf)
        }
        engine.prepare()
        log("capture: ready (\(Int(native.sampleRate))Hz \(native.channelCount)ch -> 16kHz mono)")

        // Plugging in an interface changes the input format; the tap must be rebuilt.
        // Registered once — prepare() re-runs on every such change.
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                   object: engine, queue: .main) { [weak self] _ in
                guard let self else { return }
                log("capture: device configuration changed — rebuilding tap")
                self.engine.inputNode.removeTap(onBus: 0)
                self.prepare()
            }
        }
        return true
    }

    /// Starts capture into `url`. Returns the ms spent starting the hardware.
    func start(to url: URL) throws -> Int {
        let t0 = Date()
        let f = try AVAudioFile(forWriting: url, settings: outFormat.settings,
                                commonFormat: .pcmFormatInt16, interleaved: true)
        converter?.reset()
        writeFailureLogged = false
        lock.lock(); file = f; peak = 0; lock.unlock()
        try engine.start()
        return ms(t0)
    }

    /// Stops capture and reports what was recorded.
    func stop() -> Take {
        engine.stop()
        lock.lock()
        let take = Take(seconds: Double(file?.length ?? 0) / outFormat.sampleRate, peak: peak)
        file = nil   // closes the file; a tap callback blocked on the lock sees nil and returns
        lock.unlock()
        return take
    }

    private func append(_ buf: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let file, let converter else { return }

        let capacity = AVAudioFrameCount(Double(buf.frameLength) * outFormat.sampleRate / buf.format.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buf
        }
        if let error {
            if !writeFailureLogged { log("capture: conversion failed — \(error.localizedDescription)"); writeFailureLogged = true }
            return
        }
        guard out.frameLength > 0 else { return }

        // Peak level, tracked here because we already touch every sample. Whisper
        // hallucinates fluent sentences out of silence, so the caller needs a way to
        // tell "nothing was said" from "something was said" before it pastes.
        if let ch = out.int16ChannelData?[0] {
            for i in 0..<Int(out.frameLength) {
                let a = Float(abs(Int32(ch[i]))) / 32768
                if a > peak { peak = a }
            }
        }

        do { try file.write(from: out) } catch {
            if !writeFailureLogged { log("capture: write failed — \(error.localizedDescription)"); writeFailureLogged = true }
        }
    }
}
