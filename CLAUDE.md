# patter

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
4. **Nothing gets between the key and the cursor.** Dictation is the job on the
   hot path, and anything that does not reduce time-from-speech-to-correct-text is
   rejected there on sight. Not notes, not commands, not an assistant, not a
   settings UI, not a cloud sync. Work that runs **after the fact, on logs and on
   `takes/`, off the hot path** is permitted — it cannot slow dictation down by
   construction — and it is still subject to invariants 1–3.

   *Rescoped 2026-08-01, from "One job. Dictation."* The reword is deliberate and
   narrow. What actually earned this rule its keep was never single-purposeness; it
   was the latency discipline that produced the budget table. The one feature that
   genuinely misfired, right ⌘, did not fail for being a second *job* — it failed
   for putting a second job **on the hot path**, and got used 11 times against ⌥'s
   164 on its first day. Worded this way the invariant still rejects every example
   it rejected before, while permitting `patter prompting` and the offline speech
   analysis in `SPEECH_TODO.md`, which had been formally in violation since
   2026-07-29 despite being unable to touch the hot path. Deleting the invariant
   outright was considered and refused: that would have discarded the discipline to
   buy something the rescope gives for free.

> **The right-⌘ refine path deliberately strains invariant 4.** Restructuring
> speech into a written request is arguably a second job. It stays only as long as
> it makes time-from-speech-to-*usable*-prompt shorter in real use, and it does not
> get to slow down, complicate, or add a failure mode to plain dictation. If the
> two ever conflict, plain dictation wins and this comes out. It is one key, one
> script and one prompt file precisely so that removing it stays a small change.

## Latency budget

Measured on M3 Max / `ggml-large-v3-turbo` / Metal. Re-measure with
`./patter bench` after any change to the hot path; regressions >20% are bugs.

| Stage | Budget | Measured | Notes |
|---|---|---|---|
| Capture onset loss | ≤150 ms | 63–150 ms | CoreAudio device start. Audio before this is gone. |
| Capture tail loss | ≤25 ms | ~21 ms | One 1024-frame tap buffer, in flight at key release. |
| Release → paste | ≤600 ms | 393–561 ms in real use | Dominated by one fixed 30s encoder window. 22s of speech costs 561 ms. |
| Refine, short (<150 words) | ≤2000 ms | 480–1935 ms | Local 7B on Metal. Median ~1200 ms. This is the row the original ⌘ design was calibrated against. |
| Refine, long-form (150+ words) | ≤9000 ms | 2409–**8850 ms** | **A separate budget on purpose, settled 2026-08-01.** Refine cost tracks **output** length because generation is autoregressive, so a two-minute utterance is intrinsically a multi-second stage — the opposite of whisper's flat 30 s window, and not something tuning fixes. Measured: a 398-word / 123.7 s take cost 5735 ms refine, 8850 ms end-to-end. Holding one ≤2000 ms row over both classes meant real use breached budget 4 times in 5, which is how a budget stops being read as one. Long thinking-out-loud is ⌘'s best case, so it is budgeted rather than gated. Both rows are off the right-⌥ path entirely. |
| Paste | ≤10 ms | 0–7 ms | Pasteboard write + synthetic ⌘V, plus two marker types (see macOS notes). |
| `sh` + `curl` overhead | ~25 ms | 25 ms | Price of invariant 3. Deliberate. Do not "optimize" it. |
| Cold model load | ~10 s | — | Once, at `patter start`. Never on the hot path. |

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
- **That split has a third case, and `Claude` is it: use both.** The rule above
  reads as a binary and is not one. `Claude` is heard as "cloud", which *is* real
  English — this file uses it twice — so the binary says glossary-only. But
  measured on real audio, **the glossary slot alone fixes it 1 take in 3**
  (re-transcribed the three real wavs with `Claude` in the last slot; two still
  said "Cloud"), because the two words are near-homophones and bias is
  probabilistic. Meanwhile the corpus says the risk is theoretical: **"cloud"
  occurs 10 times in 612 takes and is `Claude` 10 out of 10.** The resolution is
  the precedent the git rules already set — list only the forms whose literal
  reading is *not* real English (`tell cloud`, `talking to cloud`, `cloud or
  ChatGPT`) and leave the rest. No bare rule, and deliberately **no ask-form**:
  "ask the cloud provider" is a sentence a person says, exactly like the
  `get status` / `get log` forms omitted from the git rules. So: glossary for the
  probabilistic lift, narrow anchored sed for the cases it misses, and the
  ambiguous middle left alone on purpose.
- **A term whisper gets right under `say` may still be wrong in real speech.**
  `tests/glossary-probe.sh` synthesizes its audio, and `say` enunciates — it
  returns `Claude` correctly with *no prompt at all*, which would have argued the
  slot is unearned under the "verified-unaided terms are deliberately absent"
  rule. Real audio says the opposite. **The probe can prove a term is biased for;
  it cannot prove one is unnecessary.** Only the corpus can do that.
- **The segment join produces a single space, and a "bug" here was reported and
  then disproved — the disproof is the useful part.** Every multi-word rule matches
  one space, so double-spaced input would silently skip it, and `whisper-server`
  emitting one line per segment looks like it should produce doubles. It does not:
  `clean.sh` uses `tr -d '\n'`, which **deletes** the newline, and segments carry
  their own leading space, so a join yields exactly one. Verified across **all 623
  stored takes — zero contain a double space after the real join**, and re-running
  the whole corpus through the old and new `clean.sh` produced **0 differences**.
  The false alarm came from a checking harness that used `tr '\n' ' '`, which
  **replaces** the newline and therefore adds a space on top of the segment's own.
  General lesson, since it cost a wrong entry in this file: **a harness that
  reformats data before testing it can manufacture the bug it then reports** — when
  a defect appears only through a test path, reproduce it through the real one
  before believing it. The leading squeeze was kept anyway as cheap insurance for
  non-daemon callers, and `tests/replacements.tsv` keeps four double-spaced cases
  as robustness tests. Neither is evidence the daemon path was ever broken.
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
- **The prompt controls whether disfluencies survive, and the clean glossary is
  what deletes them.** Same mechanism as the two facts above, third consequence.
  It was long assumed whisper strips "um"/"uh" by rule — 212 real transcripts
  contained zero. It does not. Measured over **30 real takes** from `takes/`:
  disfluency tokens went **1 with the current glossary prompt → 4 with a disfluent
  prompt → 5 with glossary + disfluent tail**. Inspected rather than counted, and
  the recovered text is real, not hallucinated: `placed in each, um, each bag`
  (a repetition the clean prompt smoothed away) and — the important one —
  **`if it gets us within the placement, er, the pickup`, a genuine self-correction
  that the clean prompt silently repaired into "within the pickup"**. So the clean
  prose of `jargon.txt` is not just dropping filler, it is **erasing false starts
  and corrections**, which for dictation is a feature and for any analysis of how
  someone actually spoke is destruction of the signal. The recovery is partial —
  5 tokens across 30 takes is still far below real speech — so acoustics are
  likely a second cause; do not claim the prompt explains all of it. Crucially,
  **appending a disfluent tail costs the jargon bias nothing** (`Wattson` and
  `Tyler 01` survive in every ordering, probe check F), so the two are separable.
  **This must never ship on the right-⌥ hot path** — it would paste "um, er" into
  the focused document. It belongs in a second, offline pass over `takes/`, which
  is exactly where SPEECH's off-the-hot-path constraint already puts it.
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
- **`peak` cannot see how noisy the room is, so every take also logs `floor` and
  `snr`.** The loudest sample in a take is always the speaker's voice; doubling the
  background moves `peak` by roughly nothing. Measured on one bad day: peak held
  flat at 0.095 (against 0.105/0.082 on the two days before) while the 10th-percentile
  20ms window — the gaps between words, i.e. the room — went 0.0023 → 0.0035 and
  median SNR fell 17.3 → 15.9 dB, with sub-12dB takes going 11% → 25%. Speech RMS
  *rose*, so it was noise and not distance. Two takes came back as `*sad*`, whisper's
  sound-tag hallucination on noise, and one was pasted; it cleared the amplitude gate
  at peak 0.035 because the **noise itself** was loud enough to pass as signal — the
  documented limit of an absolute floor, reached in practice. Both percentiles come
  from the sample loop that already runs for peak, so they are free.

## Rules

**Fail loud.** No `try?`, no `2>/dev/null`, no empty `catch` on the hot path. Every
failure gets a `log()` line naming the stage. A dropped utterance the user never
hears about is the worst possible bug in a dictation tool — it looks like the app
worked and it silently ate a sentence.

**And check the metadata, not just the payload.** The corollary, learned the
expensive way. `refine.sh` had nine `passthrough()` paths, each naming its stage —
and still pasted truncated text for weeks, because a generation that hits
`max_tokens` returns **HTTP 200 with a syntactically perfect string**. Every check
passed: non-empty, parseable, unfenced, unquoted. The damage was declared in
`finish_reason`, a sibling field nothing read. **Defensive code that only inspects
its own output cannot see a failure the payload does not carry.** Whenever a stage
consumes a response, ask what the *envelope* says happened, not just whether the
body looks fine. Same shape as the amplitude gate: whisper's own confidence scores
call silence "definitely speech", so the check that works lives outside the thing
being checked.

**Log timings, not events.** Every utterance emits one line with per-stage ms.
`daemon.log` is the only debugging surface a GUI daemon has; treat it as the
product's black box, and keep it greppable and bounded.

**No absolute paths.** The daemon derives the repo root from
`Bundle.main.bundleURL`. Moving the checkout must never break it.

**Text fixes are data, not code.** New mishears go in `replacements.sed`
(word-anchored) or `jargon.txt`. Anchor every rule with `[[:<:]]…[[:>:]]` — BSD
sed supports it and unanchored rules corrupt real words (`network tree` →
`networktree`). Every rule added needs a case in `tests/replacements.tsv`.

**Your own vocabulary goes in `jargon.local.txt`, not `jargon.txt`**, and the reason
is the recency measurement rather than tidiness. `replacements.sed` is unbounded, so
contributors can share it freely. The glossary is not: only about the last 15 terms do
anything, so it is a **fixed-size shared resource**, and the obvious collaborative
policy — everyone appends their terms — is the one that provably fails. The last
committed term would win and every earlier contributor's vocabulary would go silently
inert, which is exactly the failure mode already recorded above, where `Wattson` and
`pixi` transcribed character-identically to sending no prompt at all. So
`transcribe.sh` appends a gitignored `jargon.local.txt` **after** the shared list,
putting your terms in the live slots on your machine and requiring nobody else's file
to change. Consequence worth stating plainly: a local overlay pushes the tail of the
shared list out of range **for you**, which is correct — those are someone else's
words. Changing `jargon.txt` itself stays a review question, and the audit rule still
holds: the probe can prove a term is biased for, only the corpus can prove one is
unnecessary, so nobody may trim the shared list to make room.

**Operator actions are one command.** `patter build`, `patter doctor`,
`patter test`, `patter bench`, `patter format`. Never a multi-step terminal
runbook, never a manual `swiftc` incantation in the README.

**Formatting is Swift-only, and the boundary is invariant 2.** `patter format`
runs `swift format`, which ships **inside the Swift toolchain `patter build`
already requires** — so it is not a new dependency and costs the invariant nothing.
`patter format --check` exits 1 on drift without writing. Two languages are
deliberately *not* formatted. **Shell** would need `shfmt`, a genuinely new
Homebrew dependency for ~740 lines whose comment blocks are hand-wrapped and are
the real documentation. **Markdown is refused outright**: `prettier` needs a Node
runtime, which invariant 2 rules out, and it would reflow the prose in the
`*_TODO.md` / `*_LOG.md` pairs — that text is the project's record, not content to
be formatted. If shell formatting is ever wanted, it is a dependency decision and
belongs in the log, not in a config file.

**`.swift-format` is tuned to the code that exists, not to the tool's defaults**,
and the difference is 163 changed lines against 1237. Defaults use 2-space indent
where this codebase has always used 4, and a 100-column limit where the long lines
are almost all single-line `log()` calls — `daemon.log` is the only debugging
surface a GUI daemon has, and a wrapped call is harder to grep in the source than
a long one. `respectsExistingLineBreaks` is on for the hand-aligned
`AudioUnitSetProperty` argument stacks. Note that swift-format's JSON parser
**rejects unknown keys**, so the config cannot carry comments — that is why this
rationale lives here. The one-time reformat is recorded in
`.git-blame-ignore-revs`, because `Recorder.swift` and `main.swift` hold the TCC,
AirPods-pin and tap-deafness knowledge and `git blame -L` is how it gets recovered.
Wire it once per clone: `git config blame.ignoreRevsFile .git-blame-ignore-revs`.

## The refine path (right ⌘)

Right ⌘ does capture → `transcribe.sh` → `refine.sh` → paste. Right ⌥ is
untouched and never reaches the model.

- **llama.cpp, not Ollama.** `llama-server` is the same project family as
  `whisper-server`, is already a Homebrew formula, and speaks the same resident
  request/response shape — so invariant 2 costs nothing. Ollama would be a second
  runtime and model store to own for no capability gain.
- **Model** is `models/refine-q4.gguf` (Qwen2.5-7B-Instruct Q4_K_M, 4.4GB), resident
  on `127.0.0.1:8091` with `-ngl 99`. `patter pull-model` fetches it. Absent, the
  daemon runs normally and right ⌘ pastes raw — never a hard failure.
- **A capped generation is a failure and must passthrough.** `refine.sh` sends
  `max_tokens: 1500` and **reads `finish_reason`**; `"length"` routes to
  `passthrough()` like any other error. This is not optional politeness — without
  it a long take is cut mid-word and pasted into the focused document with nothing
  in the log, which is the silently-ate-a-sentence bug (see "check the metadata"
  under Rules). Measured: a 398-word take used **335 of 512**, so it was ~1.5x from
  firing in normal use. **Do not "fix" a future recurrence by raising the cap** —
  that moves the cliff instead of removing it, and since generation is
  autoregressive a bigger cap is also a longer worst case. **The check is what makes
  the cliff impossible; only then is the number free to move.** It was raised 512 →
  1500 on 2026-08-01 in that order and never as a substitute — at 512 the passthrough
  boundary sat at ~400 words, which is where Haider's actual long-form takes land, so
  ⌘ would have quietly degraded to plain dictation in its single best case. It now
  sits near ~1200 words. Above it, ⌘ pastes the raw transcript and says so on stderr.
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
  the binary is ignored. Launch via LaunchServices (`open -g PatterDaemon.app`),
  which is always self-responsible.
- **launchd cannot exec from `~/Documents`** (TCC-protected) — the job dies with
  `EX_CONFIG (78)`. This is why there is an app bundle and no LaunchAgent.
- **The Accessibility grant tracks the code signature.** Re-toggle the checkbox
  after every rebuild. `patter build` re-signs and reminds you.
- **A bundled app needs `NSMicrophoneUsageDescription`** or the mic is silently
  denied instead of prompted.
- **stdout goes nowhere under LaunchServices.** The daemon `freopen`s its own log.
- **Deleting a worktree does not unregister its `.app`, and a stale registration
  makes the Accessibility grant unfixable.** Symptom: you select the app in the
  picker, it looks accepted, and no row ever appears — repeatedly, through resets
  and rebuilds. Cause: `lsregister -dump` listed *two* bundles claiming
  `com.haider.patter`, one of them a deleted worktree path, so System Settings
  bound the grant to a bundle that no longer exists. Diagnose with
  `lsregister -dump | grep 'path:.*PatterDaemon'` — more than one line is the bug.
  Fix with `lsregister -u <dead path>`, then `-f <real path>`, then `tccutil reset`.
  `lsregister` lives in
  `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/`.
  This is now prevented rather than documented: **the app bundle is generated by
  `patter build` from `daemon/Info.plist.in`, and every checkout mints its own
  `CFBundleIdentifier`** into a gitignored `.bundle-id`. Committing a fixed
  identifier would hand one person's identity to every clone and put two bundles on
  one identifier the first time anyone ran a worktree — which is no longer a rare
  case now the repo is shared. The value is *stored*, not recomputed from the path,
  so moving the checkout does not orphan the grant; "no absolute paths" applies to
  identity too. `patter doctor` counts how many live bundles claim the identifier and
  fails if it is more than one, because the symptom of the collision — no row in
  Privacy — looks like every other permission problem. `patter permissions` now
  unregisters only registrations whose **path no longer exists**; deleting a live
  sibling's registration was the old behaviour and would now destroy a working grant.
- **The Privacy list shows `CFBundleName`, not the filename.** Under the old name it
  read `dictate` while the file was `DictateDaemon.app`, so the row was there and
  looked absent. Both are now `PatterDaemon`; keep them identical.
- **The Privacy list is a renderer over the TCC database, not the database.** The
  grant can be fully live with *no row visible at all* — that is how this ended:
  `patter doctor` reported accessibility, microphone and input monitoring all
  granted while System Settings showed nothing. When the daemon calls
  `AXIsProcessTrustedWithOptions(prompt:)` / `IOHIDRequestAccess`, TCC is written
  directly; drawing the row is separate and unreliable for an ad-hoc signed app.
  **Never debug this from the UI.** `AXIsProcessTrusted()` inside the daemon is the
  only ground truth, which is what `patter doctor` reports. A whole session went
  into re-adding an app that was already authorised.
- **Restoring the clipboard fixes its *state*, never its *history* — that needs a
  marker type.** `paste()` has always saved the previous pasteboard contents and put
  them back 0.5s later, which is enough for the next ⌘V and useless against a
  clipboard manager: Maccy and friends poll `changeCount` on their own timer and
  simply win the race, so every dictation landed in the history anyway. Shortening the
  delay cannot fix it — the fix has to be declarative. Both writes now carry
  `org.nspasteboard.TransientType` and `org.nspasteboard.AutoGeneratedType`
  (nspasteboard.com's convention; the installed Maccy binary contains both literals).
  Managers test for the type's *presence*, so the value is empty, and the markers are
  advisory — one that ignores them is left exactly where it was before. **The restore
  write is marked too**, which is the half that is easy to miss: putting the original
  text back is itself a new pasteboard generation, and unmarked it gets re-recorded and
  shuffled to the top of the history. Use `declareTypes`, not `clearContents`, for a
  multi-type write: `setString` for an undeclared type fails **by returning false**, and
  a silently refused write means ⌘V pastes whatever was there before — the
  silently-ate-a-sentence bug wearing a different hat, so the Bool is checked and
  logged. `changeCount` does not move after `declareTypes`, so the `stamp` guard that
  stops a fast second utterance clobbering the first one's restore is unaffected.
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

**CI runs exactly two of the five suites, and a green tick must not be read as more
than that.** `.github/workflows/ci.yml` runs `patter test` and `patter format --check`
on every push and PR — the first is pure shell and sed, the second needs only the
Swift toolchain a macOS runner already has, so neither adds a dependency and invariant
2 is untouched (a CI service is not a runtime dep; nothing it does reaches the daemon).
Deliberately absent: `patter refine-test` needs 4.4GB of resident weights,
`glossary-probe.sh` needs `whisper-server` and synthesised audio, and `patter bench`
measures the machine it runs on, where a shared runner's numbers are noise. So **CI
covers the deterministic text pipeline and nothing model-shaped** — which happens to
be most of what a pull request touches and none of what a `jargon.txt` reorder does.
The probe stays a local gate, and that is a property of the model paths, not an
oversight to fix later.

`patter test` runs `tests/replacements.tsv` through **`clean.sh` directly** — text
in, text out, no audio and no model. That makes it fast and perfectly deterministic,
but it is worth being precise about what it therefore does *not* cover: it tests
`replacements.sed` only. **Glossary bias is not exercised by it at all**, because
nothing is ever transcribed; `tests/glossary-probe.sh` is the `say`-synthesized probe
that does that, and it is the one to reach for after reordering `jargon.txt`. The
probe reads `jargon.txt` alone and **does not see `jargon.local.txt`**, deliberately:
a suite whose expected output depended on a gitignored file would pass or fail
differently on every machine. It therefore tests the shared baseline, which is the
only part a pull request can change.

`patter refine-test` runs `tests/refine.tsv` through `refine.sh` against the live
7B, plus four short-input passthrough assertions. It **carries exactly two deliberate
red cases** and is expected to report `13 passed, 2 failed`; both reds are regression
markers for known model defects, documented in PATTER_TODO items 16a and 29. Do not
delete them to get a green suite, and keep the expected count here current — stating
it is what stops a *third* red hiding among the two. It exports
`PATTER_REFINE_TEST=1` so its cases are kept out of `takes/` — a synthetic pair in
the eval corpus is worse than no pair.

Three of the green cases are **real field pairs that used to fail**: the old prompt
dropped a person's name ("For Alex"), fabricated `Fix the job selection…` out of a
pure status report, and converted two questions into imperatives. They lock in a
measured fix rather than marking a defect, and they are the reason `refine.txt` rules
3, 4 and 5 are worded the way they are.

`tests/glossary-probe.sh` is the only test that touches whisper. It guards the
recency rule with `say`-synthesized audio and must print **all 6 as expected**.
Run it after **any** edit to `jargon.txt`'s length or ordering — not just additions,
since a reorder is what silently killed `Wattson` and `pixi` before. Checks B and C
must always disagree; that disagreement *is* the recency finding.

Real-mic accuracy cannot be tested here and is validated by use. See the note above
on `say`: the probe can prove a term is biased for, never that one is unnecessary.

`patter bench` prints the per-stage latency table above. Numbers in this file
came from it; update them here when they move.

**`takes/` is a corpus, not an output directory, and it has one rule: everything in
`*.pair.txt` must be speech nobody wrote for the model.** Opt-in via `patter takes`,
never auto-deleted, gitignored and blocked by `.githooks/pre-commit`. It is the only
thing that makes a `refine.txt` or model change measurable, and it has now been
damaged twice by mechanisms nobody had looked at — `daemon.log` rotation silently
destroying the pairs it was assumed to store, and the test suite writing its own
cases in under field-take filenames. Both times the data looked fine until it was
counted. Naming carries the provenance so a third case is visible: `*.pair.txt` is
field data, `*.synthetic-pair.txt` is excluded, `*-backfillUTC.pair.txt` is
reconstructed from `daemon.log` and is therefore **UTC-stamped where live pairs are
local** — do not join the two on time without accounting for it. General rule worth
keeping: a dataset whose durability is a *side effect* of some other component's
behaviour has no durability guarantee at all.

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
