#!/bin/sh
# clean.sh — raw whisper output on stdin, cleaned transcript on stdout.
# Split out of transcribe.sh so `dictate test` can exercise it without audio:
# this is where jargon regressions actually happen.
DIR="$(cd "$(dirname "$0")" && pwd)"
# whisper-server emits one line per segment and can split mid-word ("od ometry"),
# so segments are joined by deleting newlines — they carry their own leading spaces.
#
# The squeeze MUST run before replacements.sed, and it used to run only after.
# Joining segments leaves a DOUBLE space wherever whisper broke a line, and every
# multi-word rule in that file matches a single space, so a phrase split across a
# segment boundary silently missed: "talking to  Cloud", "get  pull", "april  tags"
# all passed straight through while the identical single-spaced text was rewritten.
# Measured on the real corpus 2026-08-01 — two takes containing the same sentence,
# one fixed and one not, which is what exposed it. Invisible to `dictate test`
# because every case in replacements.tsv was hand-typed with single spaces: the
# suite and the bug shared an assumption. The trailing squeeze stays, since a rule
# can introduce its own doubling.
tr -d '\n' | sed -E 's/  +/ /g' | sed -E -f "$DIR/replacements.sed" | sed -E 's/  +/ /g; s/^ +| +$//g'
