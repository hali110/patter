# patter

Local jargon-aware dictation for macOS. Hold right ⌥ anywhere, speak, release —
text lands at the cursor. whisper.cpp (large-v3-turbo, Metal), ~400ms per
utterance. No cloud, no telemetry.

**Right ⌘** does the same thing but runs the transcript through a local 7B
(llama.cpp, Qwen2.5-7B-Instruct on Metal) that turns thinking-out-loud into a
written request — ~700ms–1.8s end to end. Right ⌥ is unchanged and never touches
the model. Both texts go to `daemon.log`.

**Delete Last Dictation** in the menu bar removes what was just pasted — it
backspaces the exact text, and disarms itself (item greys out) the moment you
type, click, or dictate again so it can never eat anything else.

Project rules and the latency budget live in [CLAUDE.md](CLAUDE.md).

## Use

| | |
|---|---|
| `patter start` | run the daemon — hold right ⌥ anywhere to dictate |
| `patter stop` | kill the daemon and free the resident model (~2GB) |
| `patter doctor` | check every dependency, process, and permission |
| `patter build` | rebuild + re-sign the daemon after a source change |
| `patter test` | run the jargon/replacement suite |
| `patter refine-test` | run the refine property suite (needs llama-server) |
| `patter refine "text"` | restructure text through the local LLM, no mic |
| `patter pull-model` | download the ~4.7GB refine model |
| `patter format` | run `swift format` over the daemon (`--check` exits 1 on drift) |
| `patter bench` | print the latency table |
| `patter log` | follow `daemon.log` |
| `patter` | terminal fallback: Enter records, Enter stops, transcript → stdout + clipboard |

Menu bar icon: mic = idle, filled = recording, ellipsis = transcribing.

## Setup (once)

1. `brew install whisper-cpp ffmpeg llama.cpp` — `llama.cpp` is only for the right-⌘
   refine path; without it right ⌥ works and right ⌘ pastes raw.
2. Download `ggml-large-v3-turbo.bin` into `models/` from
   [ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp) on Hugging Face.
3. `ln -s "$PWD/patter" /opt/homebrew/bin/patter`
4. `patter build && patter start`
5. Grant the two permissions it asks for, then `patter doctor` until it prints
   `all good`.
6. `git config blame.ignoreRevsFile .git-blame-ignore-revs` — per clone. The daemon
   was reformatted wholesale once, and without this `git blame` on `Recorder.swift`
   or `main.swift` attributes the TCC, AirPods-pin and tap-deafness knowledge to
   that commit instead of the commit that learned it.

### Permissions

`PatterDaemon.app` needs **both**, in System Settings → Privacy & Security:

- **Input Monitoring** — to see the right-⌥ hold.
- **Accessibility** — to post the ⌘V that pastes at your cursor.

Both grants track the code signature, so **both reset on every `patter build`** —
re-toggle the checkboxes. `patter doctor` tells you which one is missing.

The daemon must be launched by `patter start`, which uses `open -g`
(LaunchServices) so the process is its own TCC responsible process. Started as a
terminal child it is attributed to the terminal and the grants are ignored.

## Tuning

- `jargon.txt` — vocabulary bias fed to whisper as a decode prompt. Bias is
  recency-weighted: **put the most important terms last, and keep the list short.**
  Only about the last 15 terms have any effect, and a term whisper already gets
  right wastes one of those slots. Measured, not folklore — see CLAUDE.md.
- `replacements.sed` — deterministic fixes for recurring mishears. Word-anchor every
  rule and add a case to `tests/replacements.tsv`, then `patter test`.
