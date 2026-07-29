# dictate

Local jargon-aware dictation for macOS. whisper.cpp (large-v3-turbo, Metal) + a
menu-bar hold-to-talk daemon. No cloud, no telemetry.

## Use

- `dictate start` — daemon: hold right ⌥ anywhere, speak, release → text pastes at cursor. Mic icon in menu bar (mic = idle, filled = recording, … = transcribing).
- `dictate` — terminal loop: Enter records, Enter stops, transcript → stdout + clipboard.
- `dictate stop` — kill daemon + free the resident model (~2GB RAM).

## Setup (once)

1. `brew install whisper-cpp ffmpeg` and download `models/ggml-large-v3-turbo.bin` from ggerganov/whisper.cpp on Hugging Face.
2. Build: `cd daemon && swiftc -O main.swift -o ../bin/dictate-daemon && codesign -s - -f ../bin/dictate-daemon`
3. System Settings → Privacy & Security → Accessibility → "+" → add `bin/dictate-daemon` (needed for the paste keystroke). Re-toggle after every rebuild — the grant tracks the binary.
4. Symlink onto PATH: `ln -s "$PWD/dictate" /opt/homebrew/bin/dictate`

## Tuning

- `jargon.txt` — vocabulary bias fed to whisper as a decode prompt (~224-token budget).
- `replacements.sed` — deterministic fixes for recurring mishears; grow it over time.
