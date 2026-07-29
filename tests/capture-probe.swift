// capture-probe.swift — exercises the daemon's real Recorder against the mic and
// reports onset loss, so the CLAUDE.md latency budget stays honest.
//
//   swiftc -O -parse-as-library daemon/Core.swift daemon/Recorder.swift \
//       tests/capture-probe.swift -o /tmp/capture-probe && /tmp/capture-probe out.wav
//
// Compare the printed loss against the "Capture onset loss" row in CLAUDE.md, and
// feed out.wav to transcribe.sh to confirm the WAV is one whisper can read.
import AVFoundation

@main
struct Probe {
    static func main() {
        let out = URL(fileURLWithPath: CommandLine.arguments.count > 1
                      ? CommandLine.arguments[1] : NSTemporaryDirectory() + "capture-probe.wav")
        let rec = Recorder()
        guard rec.prepare() else { print("PROBE FAIL: prepare() returned false"); exit(1) }

        for trial in 1...3 {
            let wall = 1.5
            do {
                let hw = try rec.start(to: out)
                Thread.sleep(forTimeInterval: wall)
                let take = rec.stop()
                let lost = (wall - take.seconds) * 1000
                print(String(format: "trial %d: start %d ms · wall %.3fs -> captured %.3fs · onset loss %.0f ms · peak %.4f",
                             trial, hw, wall, take.seconds, lost, take.peak))
            } catch {
                print("PROBE FAIL: \(error.localizedDescription)")
                exit(1)
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        print("wav: \(out.path)")
    }
}
