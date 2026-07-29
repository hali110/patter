#!/bin/sh
# clean.sh — raw whisper output on stdin, cleaned transcript on stdout.
# Split out of transcribe.sh so `dictate test` can exercise it without audio:
# this is where jargon regressions actually happen.
DIR="$(cd "$(dirname "$0")" && pwd)"
# whisper-server emits one line per segment and can split mid-word ("od ometry"),
# so segments are joined by deleting newlines — they carry their own leading spaces.
tr -d '\n' | sed -E -f "$DIR/replacements.sed" | sed -E 's/  +/ /g; s/^ +| +$//g'
