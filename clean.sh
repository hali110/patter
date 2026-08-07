#!/bin/sh
# clean.sh — raw whisper output on stdin, cleaned transcript on stdout.
# Split out of transcribe.sh so `patter test` can exercise it without audio:
# this is where jargon regressions actually happen.
DIR="$(cd "$(dirname "$0")" && pwd)"
# whisper-server emits one line per segment and can split mid-word ("od ometry"),
# so segments are joined by deleting newlines — they carry their own leading spaces.
#
# The leading squeeze is DEFENSIVE, not a bug fix, and the distinction matters
# because it was briefly recorded as one. Every multi-word rule below matches a
# single space, so any double-spaced input silently skips it. On the daemon path
# that cannot currently happen: `tr -d '\n'` DELETES the newline and whisper's
# segments each carry their own leading space, so a join yields exactly one space —
# verified across all 623 stored takes, zero of which contain a double space after
# the real join. (The scare came from a test harness using `tr '\n' ' '`, which
# REPLACES the newline and so adds a space on top of the segment's own. That is a
# property of the harness, not of the pipeline.)
#
# Kept anyway because it costs one `sed` and removes a whole class of silent miss
# for any caller that is not the daemon — `patter refine` on pasted text, a future
# transcribe.sh that joins differently, or a model whose segments end in a space.
# The trailing squeeze stays too, since a rule can introduce its own doubling.
tr -d '\n' | sed -E 's/  +/ /g' | sed -E -f "$DIR/replacements.sed" | sed -E 's/  +/ /g; s/^ +| +$//g'
