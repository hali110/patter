#!/bin/sh
# transcribe.sh <audio.wav> — prints cleaned transcript to stdout.
# Uses whisper-server if running (model stays resident = fast); falls back to whisper-cli.
DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL="$DIR/models/ggml-large-v3-turbo.bin"
PROMPT="$(cat "$DIR/jargon.txt")"

if curl -s -o /dev/null --max-time 0.2 "http://127.0.0.1:8090/"; then
  raw=$(curl -s "http://127.0.0.1:8090/inference" \
    -F "file=@$1" -F "temperature=0.0" -F "response_format=text" \
    -F "prompt=$PROMPT")
else
  raw=$(whisper-cli -m "$MODEL" -f "$1" -l en --prompt "$PROMPT" -nt -np 2>/dev/null)
fi
printf '%s' "$raw" | tr -d '\n' | sed -E -f "$DIR/replacements.sed" | sed -E 's/  +/ /g; s/^ +| +$//g'
