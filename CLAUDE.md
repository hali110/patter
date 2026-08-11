# patter

Hold right ⌥ anywhere on macOS, speak, release, text lands at the cursor. Fully
local. That is the entire product.

This file is the standing rules. The evidence behind them — measurements, rejected
alternatives, platform lore — is in [docs/DESIGN.md](docs/DESIGN.md). Read the
relevant section there before arguing with a rule here.

## Start here

**Run `patter doctor` first, and after anything surprising.** Every failing line names
its own fix, and its permission readings come from inside the daemon, which is the only
ground truth.

**Run the test that matches what you touched.**

| You changed | Run | Expect |
|---|---|---|
| `replacements.sed`, `clean.sh` | `patter test` | `80 passed, 0 failed` |
| `jargon.txt` — *any* edit to length or order | `tests/glossary-probe.sh` | `all 6 as expected` |
| `refine.txt`, `refine.sh` | `patter refine-test` | `14 passed, 1 failed` |
| `daemon/*.swift` | `patter format --check`, then `patter build` | `all formatted` |
| anything on the hot path | `patter bench` | inside the budget table |

**CI green does not mean the suite passed.** CI runs only `patter test` and
`patter format --check`; the other three need 4.4GB of weights, a live
`whisper-server`, or stable hardware. Run them locally.
→ [Testing](docs/DESIGN.md#testing)

**The `14 passed, 1 failed` is correct.** One red is a deliberate regression marker.
Do not delete it to get a green suite; keep the count above current so a *second* red
cannot hide behind it.

**`patter build` invalidates your Accessibility and Input Monitoring grants**, every
time. The hotkey then goes deaf **with no error anywhere** — the single most common
"it's broken" report, and not a bug in the code. Re-grant with `patter permissions`.
Do not rebuild casually while debugging something else.
→ [Ad-hoc signing](docs/DESIGN.md#ad-hoc-signing-is-why-grants-die-on-every-rebuild)

**Your own vocabulary goes in `jargon.local.txt`, never `jargon.txt`.** The shared
glossary is a fixed-size resource — only about the last 15 terms do anything — so an
appended term silently disables someone else's.
→ [Glossary and text fixes](docs/DESIGN.md#glossary-and-text-fixes)

**Before proposing a change to the hot path, read "Deliberately not doing" below.**

**What is not in this repo.** The maintainer's working notes (`*_LOG.md`, `*_TODO.md`)
are gitignored and local — they carry verbatim transcripts of real conversations. Do
not look for them, do not recreate them, and do not treat their absence as missing
documentation. `takes/` is a corpus of real recordings and is never committed.

## Invariants

Break one of these and it is no longer this project.

1. **Local only.** No network except `127.0.0.1`. No cloud STT, no telemetry, no
   analytics, no crash reporting, no auto-update check.
2. **Own the stack.** Runtime deps are Apple frameworks, Homebrew `whisper-cpp`, and
   Homebrew `llama.cpp`. `jq` is macOS's own `/usr/bin/jq`, not a new dep. No
   Hammerspoon, no Electron, no Python runtime, no third-party Swift packages. The
   daemon builds with a single `swiftc` invocation and always will.
3. **One text pipeline.** Daemon and CLI both transcribe through `transcribe.sh`. A
   jargon or replacement fix improves both paths or it does not ship.
4. **Nothing gets between the key and the cursor.** Dictation is the job on the hot
   path; anything that does not reduce time-from-speech-to-correct-text is rejected
   there on sight. Not notes, not commands, not an assistant, not a settings UI, not a
   cloud sync. Work that runs after the fact, on logs and on `takes/`, off the hot
   path, is permitted and is still subject to invariants 1–3.
   → [rescoped 2026-08-01](docs/DESIGN.md#invariant-4-rescoped)

Adding a runtime dependency is an invariant violation, not a trade-off.

The right-⌘ refine path deliberately strains invariant 4. If the two ever conflict,
plain dictation wins and refine comes out.
→ [The refine path](docs/DESIGN.md#the-refine-path)

## Latency budget

Measured on M3 Max / `ggml-large-v3-turbo` / Metal. Re-measure with `patter bench`
after any change to the hot path; **regressions >20% are bugs.** Update these numbers
here when they move.

| Stage | Budget | Measured |
|---|---|---|
| Capture onset loss | ≤150 ms | 63–150 ms |
| Capture tail loss | ≤25 ms | ~21 ms |
| Release → paste | ≤600 ms | 393–561 ms |
| Refine, short (<150 words) | ≤2000 ms | 480–1935 ms |
| Refine, long-form (150+ words) | ≤9000 ms | 2409–8850 ms |
| Paste | ≤10 ms | 0–7 ms |
| `sh` + `curl` overhead | ~25 ms | 25 ms — the price of invariant 3, do not "optimize" |
| Cold model load | ~10 s | once, at `patter start`, never on the hot path |

Refine is two rows on purpose: its cost tracks **output** length, whisper's is flat in
input length. Both rows are off the right-⌥ path entirely.
→ [Hot path and latency](docs/DESIGN.md#hot-path-and-latency)

## Rules

**Fail loud.** No `try?`, no `2>/dev/null`, no empty `catch` on the hot path. Every
failure gets a `log()` line naming the stage. A dropped utterance the user never hears
about is the worst possible bug in a dictation tool.

**Check the metadata, not just the payload.** When a stage consumes a response, ask
what the *envelope* says happened, not just whether the body looks fine. A check that
works lives outside the thing being checked.
→ [refine's `finish_reason`](docs/DESIGN.md#a-capped-generation-is-a-failure-and-must-passthrough)

**Log timings, not events.** One line per utterance with per-stage ms. `daemon.log` is
the only debugging surface a GUI daemon has — keep it greppable and bounded.

**No absolute paths.** The daemon derives the repo root from `Bundle.main.bundleURL`.
Identity too: the bundle ID is minted per checkout into a gitignored `.bundle-id`.

**Text fixes are data, not code.** New mishears go in `replacements.sed`
(word-anchored) or `jargon.txt`. Anchor every rule with `[[:<:]]…[[:>:]]` — unanchored
rules corrupt real words (`network tree` → `networktree`). Every rule added needs a
case in `tests/replacements.tsv`.

**Keep the glossary short and order it with the most important terms LAST.** Only about
the last 15 do anything. A term whisper already gets right is not free — it spends a
live slot. Never trim the shared list to make room: the probe can prove a term is
biased for, only the corpus can prove one is unnecessary.

**Never do work on the `CGEventTap` callback thread.** macOS mutes any tap that misses
its deadline and it goes silently deaf. Dispatch to main and nothing else.

**Never capture with a subprocess**, and always pin capture to the built-in mic —
opening a Bluetooth input freezes every other app's audio.

**Never debug permissions from System Settings.** The Privacy list is a renderer over
the TCC database and can show nothing while the grant is live. `patter doctor` is the
ground truth.
→ [macOS platform notes](docs/DESIGN.md#macos-platform-notes)

**Both gates run before their model, never on its confidence scores.** Whisper's own
`no_speech_prob` calls pure silence "definitely speech". Audio is gated on amplitude
(<0.35 s or peak <0.01 is dropped); refine is gated on word count (<12 words skips the
model). Do not revisit the model-side signals.
→ [Silence, gates and hallucination](docs/DESIGN.md#silence-gates-and-hallucination)

**Never put a disfluency-preserving prompt on the right-⌥ hot path.** It would paste
"um, er" into the focused document. Offline passes over `takes/` only.

**`refine.sh` never fails closed.** Every error path prints its input unchanged and
explains on stderr.

**Operator actions are one command.** `patter build`, `patter doctor`, `patter test`,
`patter bench`, `patter format`. Never a multi-step terminal runbook, never a manual
`swiftc` incantation in the README.

**Formatting is Swift-only.** `patter format` uses the toolchain's own `swift format`,
so it costs invariant 2 nothing. Shell and Markdown are deliberately not formatted.
→ [Tooling](docs/DESIGN.md#tooling)

**`takes/` is a corpus, not an output directory.** Everything in `*.pair.txt` must be
speech nobody wrote for the model. Never auto-delete it; a log line is regenerable and
a recording is not.

## Where things go

- **Reasoning behind a change** → the commit message.
- **A durable rule** → this file, in the section it extends.
- **The evidence for that rule** → [docs/DESIGN.md](docs/DESIGN.md), same commit.
- **Design notes and working state** → the maintainer's local `*_LOG.md` / `*_TODO.md`.

## Deliberately not doing

Each was measured and rejected; the measurement is in
[docs/DESIGN.md](docs/DESIGN.md#deliberately-not-doing--the-measurements-that-rejected-each).

- **Streaming / partial results** — not until 400 ms actually feels slow.
- **Always-hot mic** — privacy beats 100 ms.
- **A local LLM cleanup pass on right ⌥** — right ⌥ must never touch the model.
- **Smaller/faster models** — already overhead-bound, and it loses jargon accuracy.
