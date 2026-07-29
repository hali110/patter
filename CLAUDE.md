# dictate

Hold right ⌥ anywhere on macOS, speak, release, text lands at the cursor. Fully
local. That is the entire product.

## Invariants

Break one of these and it is no longer this project.

1. **Local only.** No network except `127.0.0.1`. No cloud STT, no telemetry, no
   analytics, no crash reporting, no auto-update check.
2. **Own the stack.** Runtime deps are Apple frameworks + Homebrew `whisper-cpp`.
   No Hammerspoon, no Electron, no Python runtime, no third-party Swift packages.
   The daemon builds with a single `swiftc` invocation and always will.
3. **One text pipeline.** Daemon and CLI both transcribe through `transcribe.sh`.
   A jargon or replacement fix improves both paths or it does not ship.
4. **One job.** Dictation. Not notes, not commands, not an assistant, not a
   settings UI. Features that do not reduce time-from-speech-to-correct-text are
   rejected on sight.

## Latency budget

Measured on M3 Max / `ggml-large-v3-turbo` / Metal. Re-measure with
`./dictate bench` after any change to the hot path; regressions >20% are bugs.

| Stage | Budget | Measured | Notes |
|---|---|---|---|
| Capture onset loss | ≤150 ms | 63–150 ms | CoreAudio device start. Audio before this is gone. |
| Capture tail loss | ≤25 ms | ~21 ms | One 1024-frame tap buffer, in flight at key release. |
| Release → paste | ≤600 ms | 393–561 ms in real use | Dominated by one fixed 30s encoder window. 22s of speech costs 561 ms. |
| Paste | ≤10 ms | 0–7 ms | Pasteboard write + synthetic ⌘V. |
| `sh` + `curl` overhead | ~25 ms | 25 ms | Price of invariant 3. Deliberate. Do not "optimize" it. |
| Cold model load | ~10 s | — | Once, at `dictate start`. Never on the hot path. |

Facts that constrain the design, established by measurement:

- **Transcription cost is ~flat in utterance length** (5.1s → 330ms, 26.3s →
  420ms). Whisper pads to a 30-second window. Shorter utterances do not get
  faster, so there is no reason to nudge the user toward short bursts.
- **Jargon prompt costs ~20ms** (310ms → 330ms). Cheap. Keep biasing.
- **The model is resident and GPU-backed.** `whisper-server` holds ~2GB and runs
  on the Metal backend with flash attention. If a transcript takes 10s, the
  server died and `transcribe.sh` silently fell back to `whisper-cli` — check the
  log for `path=cli`.
- **Never capture with a subprocess.** `ffmpeg -f avfoundation` costs ~300ms
  before the first sample because libavdevice enumerates video devices (including
  Continuity Camera) on open. In-process `AVAudioEngine` costs 63–150ms.
- **Never do work on the `CGEventTap` callback thread.** macOS mutes any tap whose
  callback misses its deadline and the tap goes silently deaf — this cost a full
  debugging session. The callback dispatches to main and does nothing else, and
  `.tapDisabledByTimeout` / `.tapDisabledByUserInput` are subscribed and re-enable it.
- **Whisper hallucinates fluent text from silence, and the jargon prompt is what
  makes it dangerous.** Same silent file: with no prompt, `avg_logprob` is -0.565
  and the text is " ." (appropriately unsure); with the glossary prompt it is
  **-0.004** — near-total confidence in a transcript of nothing. One silent take
  produced "Get there, Kevin got even faster!". Conditioning the decoder on a
  glossary gives it fluent context to continue from, so it stops hedging on empty
  input. Since this app types into whatever document is focused, that is the worst
  failure it has.
- **The gate must run before whisper, on amplitude.** Both model-side signals were
  measured and are unusable: `no_speech_prob` returns 3.6e-10 (i.e. "definitely
  speech") on pure silence, and `avg_logprob` scores silence *more* confident than
  speech. Do not revisit them. A take under 0.35s, or peaking below 0.01 full
  scale, is dropped without ever being transcribed.
- **The peak floor catches a dead mic; it is not voice activity detection.** Real
  speech measures 0.022–0.056 peak, room tone with a TV on measures 0.016–0.035 —
  overlapping ranges, so amplitude cannot separate speech from noise, only signal
  from no-signal. Margin over the floor is ~2.2x at 50% system input volume;
  raising input volume widens it (speech at 0.03 peak uses ~10 of 16 bits). Every
  take logs its peak — tune from the log, never from a guess.

## Rules

**Fail loud.** No `try?`, no `2>/dev/null`, no empty `catch` on the hot path. Every
failure gets a `log()` line naming the stage. A dropped utterance the user never
hears about is the worst possible bug in a dictation tool — it looks like the app
worked and it silently ate a sentence.

**Log timings, not events.** Every utterance emits one line with per-stage ms.
`daemon.log` is the only debugging surface a GUI daemon has; treat it as the
product's black box, and keep it greppable and bounded.

**No absolute paths.** The daemon derives the repo root from
`Bundle.main.bundleURL`. Moving the checkout must never break it.

**Text fixes are data, not code.** New mishears go in `replacements.sed`
(word-anchored) or `jargon.txt`. Anchor every rule with `[[:<:]]…[[:>:]]` — BSD
sed supports it and unanchored rules corrupt real words (`network tree` →
`networktree`). Every rule added needs a case in `tests/cases.tsv`.

**Operator actions are one command.** `dictate build`, `dictate doctor`,
`dictate test`, `dictate bench`. Never a multi-step terminal runbook, never a
manual `swiftc` incantation in the README.

## macOS platform notes

Hard-won; re-deriving these costs hours.

- **TCC attributes a process to its "responsible process."** A daemon spawned
  from a terminal is attributed to the *terminal*, so an Accessibility grant on
  the binary is ignored. Launch via LaunchServices (`open -g DictateDaemon.app`),
  which is always self-responsible.
- **launchd cannot exec from `~/Documents`** (TCC-protected) — the job dies with
  `EX_CONFIG (78)`. This is why there is an app bundle and no LaunchAgent.
- **The Accessibility grant tracks the code signature.** Re-toggle the checkbox
  after every rebuild. `dictate build` re-signs and reminds you.
- **A bundled app needs `NSMicrophoneUsageDescription`** or the mic is silently
  denied instead of prompted.
- **stdout goes nowhere under LaunchServices.** The daemon `freopen`s its own log.

## Testing

`dictate test` runs `tests/cases.tsv` through `transcribe.sh` using
`say`-synthesized audio. It covers the text pipeline (jargon bias + replacements),
which is where regressions actually happen. Real-mic accuracy cannot be tested
here and is validated by use.

`dictate bench` prints the per-stage latency table above. Numbers in this file
came from it; update them here when they move.

## Deliberately not doing

- **Streaming / partial results.** Would cut perceived latency below 400ms but
  requires abandoning `whisper-server`'s request/response API. Not worth it until
  400ms actually feels slow.
- **Always-hot mic** to erase the 100ms onset loss. Costs a permanently lit
  recording indicator. Privacy beats 100ms.
- **A local LLM cleanup pass** between whisper and paste. Adds seconds to a
  400ms pipeline to fix errors that `replacements.sed` fixes for free.
- **Smaller/faster models.** `large-v3-turbo` at 14x realtime is already
  overhead-bound, not compute-bound. A smaller model saves little and loses
  jargon accuracy.
