# dictate

Local jargon-aware dictation for macOS. Hold right ⌥ anywhere, speak, release —
text lands at the cursor. whisper.cpp (large-v3-turbo, Metal), ~400ms per
utterance. No cloud, no telemetry.

On this branch (`ai-cleanup`), **right ⌘** does the same thing but runs the
transcript through a local 7B (llama.cpp, Qwen2.5-7B-Instruct on Metal) that turns
thinking-out-loud into a written request — ~700ms–1.8s end to end. Right ⌥ is
unchanged and never touches the model. Both texts go to `daemon.log`.

Project rules and the latency budget live in [CLAUDE.md](CLAUDE.md).

## Use

| | |
|---|---|
| `dictate start` | run the daemon — hold right ⌥ anywhere to dictate |
| `dictate stop` | kill the daemon and free the resident model (~2GB) |
| `dictate doctor` | check every dependency, process, and permission |
| `dictate build` | rebuild + re-sign the daemon after a source change |
| `dictate test` | run the jargon/replacement suite |
| `dictate refine-test` | run the refine property suite (needs llama-server) |
| `dictate refine "text"` | restructure text through the local LLM, no mic |
| `dictate pull-model` | download the ~4.7GB refine model |
| `dictate bench` | print the latency table |
| `dictate log` | follow `daemon.log` |
| `dictate` | terminal fallback: Enter records, Enter stops, transcript → stdout + clipboard |

Menu bar icon: mic = idle, filled = recording, ellipsis = transcribing.

## Setup (once)

1. `brew install whisper-cpp ffmpeg`
2. Download `ggml-large-v3-turbo.bin` into `models/` from
   [ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp) on Hugging Face.
3. `ln -s "$PWD/dictate" /opt/homebrew/bin/dictate`
4. `dictate build && dictate start`
5. Grant the two permissions it asks for, then `dictate doctor` until it prints
   `all good`.

### Permissions

`DictateDaemon.app` needs **both**, in System Settings → Privacy & Security:

- **Input Monitoring** — to see the right-⌥ hold.
- **Accessibility** — to post the ⌘V that pastes at your cursor.

Both grants track the code signature, so **both reset on every `dictate build`** —
re-toggle the checkboxes. `dictate doctor` tells you which one is missing.

The daemon must be launched by `dictate start`, which uses `open -g`
(LaunchServices) so the process is its own TCC responsible process. Started as a
terminal child it is attributed to the terminal and the grants are ignored.

## Tuning

- `jargon.txt` — vocabulary bias fed to whisper as a decode prompt. Bias is
  recency-weighted: **put the most important terms last, and keep the list short.**
  Only about the last 15 terms have any effect, and a term whisper already gets
  right wastes one of those slots. Measured, not folklore — see CLAUDE.md.
- `replacements.sed` — deterministic fixes for recurring mishears. Word-anchor every
  rule and add a case to `tests/replacements.tsv`, then `dictate test`.
