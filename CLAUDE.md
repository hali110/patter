# dictate

Hold right ⌥ anywhere on macOS, speak, release, text lands at the cursor. Fully
local. That is the entire product.

## Invariants

Break one of these and it is no longer this project.

1. **Local only.** No network except `127.0.0.1`. No cloud STT, no telemetry, no
   analytics, no crash reporting, no auto-update check.
2. **Own the stack.** Runtime deps are Apple frameworks, Homebrew `whisper-cpp`,
   and Homebrew `llama.cpp` for the right-⌘ path. Both are the same upstream
   project family and speak the same resident-server shape, which is why
   `llama.cpp` was chosen over Ollama — a second runtime and model store to own
   would have bought nothing. `jq` is macOS's own `/usr/bin/jq`, not a new dep.
   No Hammerspoon, no Electron, no Python runtime, no third-party Swift packages.
   The daemon builds with a single `swiftc` invocation and always will.
3. **One text pipeline.** Daemon and CLI both transcribe through `transcribe.sh`.
   A jargon or replacement fix improves both paths or it does not ship.
4. **One job.** Dictation. Not notes, not commands, not an assistant, not a
   settings UI. Features that do not reduce time-from-speech-to-correct-text are
   rejected on sight.

> **The right-⌘ refine path deliberately strains invariant 4.** Restructuring
> speech into a written request is arguably a second job. It stays only as long as
> it makes time-from-speech-to-*usable*-prompt shorter in real use, and it does not
> get to slow down, complicate, or add a failure mode to plain dictation. If the
> two ever conflict, plain dictation wins and this comes out. It is one key, one
> script and one prompt file precisely so that removing it stays a small change.

## Latency budget

Measured on M3 Max / `ggml-large-v3-turbo` / Metal. Re-measure with
`./dictate bench` after any change to the hot path; regressions >20% are bugs.

| Stage | Budget | Measured | Notes |
|---|---|---|---|
| Capture onset loss | ≤150 ms | 63–150 ms | CoreAudio device start. Audio before this is gone. |
| Capture tail loss | ≤25 ms | ~21 ms | One 1024-frame tap buffer, in flight at key release. |
| Release → paste | ≤600 ms | 393–561 ms in real use | Dominated by one fixed 30s encoder window. 22s of speech costs 561 ms. |
| Refine (right ⌘ only) | ≤2000 ms | 480–**2175 ms** | Local 7B on Metal. Scales with **output** length, unlike whisper. Off the right-⌥ path entirely. Top of range **breaches budget** on one 138-word take (1924/2175 ms across two runs), accepted knowingly when `refine.txt` was rewritten to stop dropping context — see the log. Median take ~1200 ms. |
| Paste | ≤10 ms | 0–7 ms | Pasteboard write + synthetic ⌘V. |
| `sh` + `curl` overhead | ~25 ms | 25 ms | Price of invariant 3. Deliberate. Do not "optimize" it. |
| Cold model load | ~10 s | — | Once, at `dictate start`. Never on the hot path. |

Facts that constrain the design, established by measurement:

- **Transcription cost is ~flat in utterance length** (5.1s → 330ms, 26.3s →
  420ms). Whisper pads to a 30-second window. Shorter utterances do not get
  faster, so there is no reason to nudge the user toward short bursts.
- **Jargon prompt costs ~20ms** (310ms → 330ms). Cheap. Keep biasing.
- **Glossary bias is recency-weighted, so the glossary must be short and ordered
  with the most important terms LAST.** Whisper conditions the decoder on the
  prompt as if it were text preceding the audio, so the terms nearest the end
  dominate and only roughly the last 15 do anything at all. Measured on one
  fixed clip: with the old 80-term glossary, `Wattson` (4th term) and `pixi`
  (12th) transcribed as "Watson" and "pixie" — *character-identical to sending
  no prompt at all*. Moving either to the end of the same 80-term list fixed it
  immediately. Reordering and cutting the list to 36 terms fixed `pytest`
  ("Piedest"), `pixi`, `ZUPT` ("ZUP"), `Wattson`, `mypy`, `ruff` and `AprilTag`
  with no code change. Corollary: **a term whisper already gets right is not
  free** — it consumes one of the few live slots. Verified-unaided terms are
  listed in `jargon.txt` as deliberately absent; do not re-add them.
- **Which fixes belong in `jargon.txt` vs `replacements.sed`** follows from the
  above. `replacements.sed` is deterministic and unbounded, the glossary is
  scarce and probabilistic. A mishear whose *wrong* form is not real English
  (`onks`/`oncs`/`anx` → ONNX, `zfail` → xfail) is a sed rule. A term whose
  mishear collides with real English belongs in the glossary and nowhere else:
  `mypy` is heard as "might be", which no anchored rule can fix without
  corrupting the phrase.
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
- **The refine LLM invents a whole request out of a near-empty one, so its gate
  also runs before the model — on word count.** Exactly the failure whisper has
  with silence, one stage later and with worse consequences: fed the single word
  "um", the 7B returned *"Check the tests, actually no, first clone the repository,
  then check the tests."* — a fabricated, plausible, entirely unspoken instruction,
  which this app would then type into the focused document. Two things caused it.
  The model had nothing to anchor on, and `refine.txt` at the time illustrated a
  rule with a concrete example, which the model regurgitated as content — prompt
  examples become output when the input is thin, so the prompt now describes rules
  instead of showing them. **Instructing the model to return short input verbatim
  does not work** — it disobeys precisely when the input is too thin, which is the
  case that matters. Anything under 12 words skips the model entirely. Nothing is
  lost by that: an utterance that short has no rambling to condense.
- **Refine cost tracks output length, not input length.** 17 words in → 321 ms,
  83 words in → 1259 ms, because generation is autoregressive. This is the opposite
  of whisper's flat 30s-window cost, so the two stages must be budgeted separately —
  a long dictation is cheap to transcribe and expensive to restructure.
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
`networktree`). Every rule added needs a case in `tests/replacements.tsv`.

**Operator actions are one command.** `dictate build`, `dictate doctor`,
`dictate test`, `dictate bench`. Never a multi-step terminal runbook, never a
manual `swiftc` incantation in the README.

## The refine path (right ⌘)

Right ⌘ does capture → `transcribe.sh` → `refine.sh` → paste. Right ⌥ is
untouched and never reaches the model.

- **llama.cpp, not Ollama.** `llama-server` is the same project family as
  `whisper-server`, is already a Homebrew formula, and speaks the same resident
  request/response shape — so invariant 2 costs nothing. Ollama would be a second
  runtime and model store to own for no capability gain.
- **Model** is `models/refine-q4.gguf` (Qwen2.5-7B-Instruct Q4_K_M, 4.4GB), resident
  on `127.0.0.1:8091` with `-ngl 99`. `dictate pull-model` fetches it. Absent, the
  daemon runs normally and right ⌘ pastes raw — never a hard failure.
- **`refine.sh` never fails closed.** Every error path prints its input unchanged
  and explains on stderr. A refine that silently ate a sentence would be strictly
  worse than not having the feature.
- **jq is `/usr/bin/jq`, shipped by macOS** — not a new dependency. It is there
  because hand-escaping JSON around arbitrary dictated text is how a transcript
  containing a quote mark silently truncates the request.
- **The prompt is data** (`refine.txt`), like `jargon.txt`. It states rules and
  deliberately shows no examples — see the hallucination note in the measured
  facts above.
- **Output is re-run through `clean.sh`.** The model is told to keep technical
  nouns verbatim and mostly does, but invariant 3 says a jargon fix holds on every
  path. Costs ~10ms of a ~1000ms stage.
- **A keystroke during a hold cancels the take.** Right ⌘ is half of every shortcut
  on macOS, so "held ⌘, then pressed S" must not paste a fragment into the document
  that just saved. The tap subscribes to `keyDown` solely to notice one arrived; it
  is listenOnly and the key is never read or logged.
- **Both texts are always logged** when refine changes anything. The model can drop
  a requirement and the spoken original is otherwise gone for good.

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
- **Deleting a worktree does not unregister its `.app`, and a stale registration
  makes the Accessibility grant unfixable.** Symptom: you select the app in the
  picker, it looks accepted, and no row ever appears — repeatedly, through resets
  and rebuilds. Cause: `lsregister -dump` listed *two* bundles claiming
  `com.haider.dictate`, one of them a deleted worktree path, so System Settings
  bound the grant to a bundle that no longer exists. Diagnose with
  `lsregister -dump | grep 'path:.*DictateDaemon'` — more than one line is the bug.
  Fix with `lsregister -u <dead path>`, then `-f <real path>`, then `tccutil reset`.
  `lsregister` lives in
  `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/`.
  Give a second checkout's bundle its own `CFBundleIdentifier` if it will ever run.
- **The Privacy list shows `CFBundleName`, not the filename.** It read `dictate`
  while the file was `DictateDaemon.app`, so the row was there and looked absent.
  Both are now `DictateDaemon`; keep them identical.
- **The Privacy list is a renderer over the TCC database, not the database.** The
  grant can be fully live with *no row visible at all* — that is how this ended:
  `dictate doctor` reported accessibility, microphone and input monitoring all
  granted while System Settings showed nothing. When the daemon calls
  `AXIsProcessTrustedWithOptions(prompt:)` / `IOHIDRequestAccess`, TCC is written
  directly; drawing the row is separate and unreliable for an ad-hoc signed app.
  **Never debug this from the UI.** `AXIsProcessTrusted()` inside the daemon is the
  only ground truth, which is what `dictate doctor` reports. A whole session went
  into re-adding an app that was already authorised.
- **Opening a Bluetooth input device freezes every other app's audio.** AirPods
  cannot do A2DP playback and mic capture at once: opening their mic forces a
  profile renegotiation, and releasing it at key-up forces another — each stalls
  all system audio for ~1s. Capture is therefore pinned to the built-in mic
  (`Recorder.pinToBuiltInMic()`, `kAudioOutputUnitProperty_CurrentDevice`), never
  the system default input. Bonus: the built-in array mic beats any Bluetooth
  headset mic for transcription.
- **Ad-hoc signing (`codesign -s -`) is why grants die on every rebuild.** TCC keys
  an app on its designated requirement; with no signing identity it falls back to
  the `cdhash`, which changes whenever the binary does, so macOS treats each build
  as a new app and orphans the old row. A self-signed code-signing certificate
  would make grants survive rebuilds — not done yet, and the reason the re-toggle
  dance exists.

## Testing

`dictate test` runs `tests/replacements.tsv` through `transcribe.sh` using
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
- **A local LLM cleanup pass on the right-⌥ path.** Still rejected, and the
  original reason stands: it adds seconds to a 400ms pipeline to fix errors that
  `replacements.sed` fixes for free. What this branch adds is a *different job* on
  a *different key* — right ⌘ restructures thinking-out-loud into a written
  request, which is not spelling cleanup and cannot be done with rules. Right ⌥
  must never touch the model. See "The refine path" below.
- **Smaller/faster models.** `large-v3-turbo` at 14x realtime is already
  overhead-bound, not compute-bound. A smaller model saves little and loses
  jargon accuracy.
