#!/bin/sh
# transcribe.sh <audio.wav> — prints cleaned transcript to stdout.
# Single source of truth for the text pipeline: the daemon and the CLI both call this,
# so a jargon or replacement fix lands in both paths at once.
DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL="$DIR/models/ggml-large-v3-turbo.bin"
# Comments stripped so jargon.txt can carry its own ordering rules — the fact that
# bias is recency-weighted (most important term LAST) is too surprising to leave undocumented
# at the point of edit, and anything not stripped here would become part of the prompt.
PROMPT="$(grep -v '^#' "$DIR/jargon.txt")"

if [ ! -f "$1" ]; then
  echo "transcribe: no such audio file: $1" >&2
  exit 1
fi

if curl -s -o /dev/null --max-time 0.2 "http://127.0.0.1:8090/"; then
  raw=$(curl -s --max-time 30 "http://127.0.0.1:8090/inference" \
    -F "file=@$1" -F "temperature=0.0" -F "response_format=text" \
    -F "prompt=$PROMPT") || { echo "transcribe: whisper-server request failed" >&2; exit 1; }
else
  # ~10s per utterance because the model reloads every call. Said out loud rather than
  # letting the daemon look mysteriously slow; grep the log for "path=cli".
  echo "transcribe: whisper-server down, falling back to whisper-cli (path=cli, ~10s)" >&2
  [ -f "$MODEL" ] || { echo "transcribe: model missing at $MODEL — run: patter doctor" >&2; exit 1; }
  raw=$(whisper-cli -m "$MODEL" -f "$1" -l en --prompt "$PROMPT" -nt -np 2>/dev/null) \
    || { echo "transcribe: whisper-cli failed" >&2; exit 1; }
fi

# Retain the take for offline speech analysis, when switched on with `patter takes on`.
# Off unless takes/.enabled exists — this is the only thing in the project that persists
# microphone audio, and that is a decision to make deliberately, not a default.
#
# Here rather than in the daemon for two reasons. It is the single path both the daemon
# and the CLI go through (invariant 3), so one edit covers both. And a shell change needs
# no rebuild: rebuilding the daemon re-signs the binary, which orphans the Accessibility
# grant and costs the whole re-toggle dance every time (CLAUDE.md).
#
# The *pre-clean* transcript is stored on purpose. replacements.sed exists to make text
# land correctly at a cursor; for asking "what did whisper actually hear" it is damage.
if [ -f "$DIR/takes/.enabled" ]; then
  ts=$(date +%Y%m%d-%H%M%S)-$$
  if cp "$1" "$DIR/takes/$ts.wav" 2>/dev/null; then
    printf '%s' "$raw" > "$DIR/takes/$ts.txt"
  else
    echo "transcribe: could not retain take $ts" >&2
  fi
  # NOTHING IS PRUNED HERE, deliberately. An earlier version rotated at 5000 takes like
  # daemon.log does, which was wrong: a log line is regenerable and a recording is not.
  # Silently deleting a take the user believed was kept is the same failure class as
  # silently eating an utterance, which CLAUDE.md calls the worst bug this project has.
  # Growth is ~67MB/day at measured usage; `patter takes status` reports size, and
  # deleting is an explicit `patter takes purge`.
fi

printf '%s' "$raw" | sh "$DIR/clean.sh"
