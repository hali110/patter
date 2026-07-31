// Recorder.swift — in-process 16 kHz mono capture.
//
// Deliberately not ffmpeg: `-f avfoundation` spends ~300ms enumerating devices
// (video included, Continuity Camera and all) before the first sample lands, so a
// press-and-speak user loses their first syllable. AVAudioEngine costs ~100ms.
// See CLAUDE.md's latency budget; verify with tests/capture-probe.swift.
import AVFoundation
import AudioToolbox

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
    private var windowRMS: [Float] = []

    /// What a finished recording amounted to. All levels are 0…1 full scale.
    ///
    /// `peak` is the loudest single sample, which is always the speaker's voice — so
    /// it is blind to how noisy the room is. A doubling of background noise moves it
    /// by roughly nothing. `floor` is what moves: the quiet between words.
    struct Take {
        let seconds: Double
        let peak: Float
        /// 10th-percentile 21ms window — the room. ~0.0001 in a quiet room,
        /// 0.008–0.012 standing next to running machinery.
        let floor: Float
        /// 90th-percentile 21ms window — the voice.
        let speech: Float
        /// dB of voice over room. Whisper starts inventing sound tags below ~10.
        var snr: Float { floor > 0 && speech > 0 ? 20 * log10(speech / floor) : 0 }

        /// The level triplet, rendered once so that every exit path in `stopRec`
        /// prints the identical shape and `grep snr=` sees a take whether it was
        /// pasted, dropped or came back empty. One decimal on dB because the trend
        /// being watched for is ~1dB of drift in a median, which %.0f would hide.
        var levels: String { String(format: "peak=%.3f floor=%.4f snr=%.1fdB", peak, floor, snr) }
    }

    /// Allocates engine resources up front so key-down only pays for the hardware start.
    @discardableResult
    func prepare() -> Bool {
        pinToBuiltInMic()
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

    /// Captures from the built-in mic, never the system default. When the default
    /// input is Bluetooth (AirPods), opening its mic forces the headset out of its
    /// music-only profile and every stop() forces it back — freezing all other audio
    /// for ~1s on each transition. Falls back to the default input on machines with
    /// no built-in mic.
    private func pinToBuiltInMic() {
        guard let mic = Self.builtInMicID() else {
            log("capture: no built-in mic found — using system default input")
            return
        }
        guard let unit = engine.inputNode.audioUnit else {
            log("capture: input node has no audio unit — using system default input")
            return
        }
        var id = mic
        let err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global, 0, &id,
                                       UInt32(MemoryLayout<AudioDeviceID>.size))
        if err == noErr {
            log("capture: pinned to built-in mic")
        } else {
            log("capture: pinning built-in mic failed (OSStatus \(err)) — using system default input")
        }
    }

    private static func builtInMicID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return nil }

        for id in ids {
            var transport: UInt32 = 0
            var tSize = UInt32(MemoryLayout<UInt32>.size)
            var tAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &tAddr, 0, nil, &tSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { continue }
            var sAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                   mScope: kAudioObjectPropertyScopeInput,
                                                   mElement: kAudioObjectPropertyElementMain)
            var sSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &sAddr, 0, nil, &sSize) == noErr, sSize > 0 else { continue }
            return id
        }
        return nil
    }

    /// The pin from prepare() does not survive Bluetooth churn: AudioDeviceIDs are
    /// not stable, and when AirPods disconnect and rejoin the AUHAL falls back to
    /// the system default input (the AirPods) with *no* configuration-change
    /// notification — so the rebuild path never runs. Caught live in daemon.log:
    /// peak jumped 0.05→0.63 with no "configuration changed" line in between.
    /// Re-checking here, before the device is opened, is what actually prevents
    /// the audio freeze; costs a few property reads on a stopped engine.
    private func ensurePinned() {
        guard let mic = Self.builtInMicID(), let unit = engine.inputNode.audioUnit else { return }
        var current = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let readErr = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                           kAudioUnitScope_Global, 0, &current, &size)
        if readErr == noErr && current == mic { return }
        var id = mic
        let err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global, 0, &id,
                                       UInt32(MemoryLayout<AudioDeviceID>.size))
        if err == noErr {
            log("capture: pin was lost (device \(current)) — re-pinned to built-in mic")
        } else {
            log("capture: re-pinning built-in mic failed (OSStatus \(err)) — using current input")
        }
    }

    /// Starts capture into `url`. Returns the ms spent starting the hardware.
    func start(to url: URL) throws -> Int {
        let t0 = Date()
        ensurePinned()
        let f = try AVAudioFile(forWriting: url, settings: outFormat.settings,
                                commonFormat: .pcmFormatInt16, interleaved: true)
        converter?.reset()
        writeFailureLogged = false
        lock.lock(); file = f; peak = 0; windowRMS.removeAll(keepingCapacity: true); lock.unlock()
        try engine.start()
        return ms(t0)
    }

    /// Stops capture and reports what was recorded.
    func stop() -> Take {
        engine.stop()
        lock.lock()
        let (floor, speech) = levels()
        let take = Take(seconds: Double(file?.length ?? 0) / outFormat.sampleRate,
                        peak: peak, floor: floor, speech: speech)
        file = nil   // closes the file; a tap callback blocked on the lock sees nil and returns
        lock.unlock()
        return take
    }

    /// Room and voice levels, as the 10th and 90th percentile window. One sort of
    /// ~1400 floats for a 30s take — microseconds, and it happens after the engine
    /// has stopped, so it is off the tail-loss path. Caller holds `lock`.
    private func levels() -> (floor: Float, speech: Float) {
        guard !windowRMS.isEmpty else { return (0, 0) }
        let s = windowRMS.sorted()
        return (s[s.count / 10], s[s.count * 9 / 10])
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

        // Levels, tracked here because we already touch every sample. Whisper
        // hallucinates fluent sentences out of silence, so the caller needs a way to
        // tell "nothing was said" from "something was said" before it pastes. The
        // buffer is ~21ms at 16kHz, which is the window the RMS percentiles use.
        if let ch = out.int16ChannelData?[0] {
            var sumsq: Float = 0
            for i in 0..<Int(out.frameLength) {
                let a = Float(abs(Int32(ch[i]))) / 32768
                if a > peak { peak = a }
                sumsq += a * a
            }
            windowRMS.append((sumsq / Float(out.frameLength)).squareRoot())
        }

        do { try file.write(from: out) } catch {
            if !writeFailureLogged { log("capture: write failed — \(error.localizedDescription)"); writeFailureLogged = true }
        }
    }
}
