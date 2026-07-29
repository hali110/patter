#!/bin/sh
# refine.sh — dictated transcript on stdin, restructured request on stdout.
#
# Second half of the AI path: transcribe.sh produces text, this reshapes it.
# Kept as a script for the same reason transcribe.sh is one — the daemon and the
# CLI (`dictate refine`) must go through identical code or the two paths drift.
#
# THIS SCRIPT NEVER FAILS CLOSED. Every error path prints the untouched input and
# exits 0, because a dropped utterance is this project's worst bug (CLAUDE.md).
# The reason always goes to stderr, which the daemon copies into daemon.log.
#
# jq is /usr/bin/jq, shipped with macOS — not a new dependency. It is here because
# hand-rolling JSON escaping around arbitrary dictated text is how you get a
# transcript containing a quote mark to silently truncate the request.
DIR="$(cd "$(dirname "$0")" && pwd)"
PORT=8091

raw="$(cat)"
[ -n "$raw" ] || exit 0

# Print the input unchanged and say why on stderr.
passthrough() { echo "refine: $1 — pasting raw transcript" >&2; printf '%s' "$raw"; exit 0; }

# THE GATE RUNS BEFORE THE MODEL, ON LENGTH — for the same reason the silence gate
# runs before whisper on amplitude (CLAUDE.md). An LLM fed a near-empty utterance
# does not decline; it invents. Measured: the input "um" came back as "Check the
# tests, actually no, first clone the repository, then check the tests." — a
# complete fabricated request, which this app would then type into the focused
# document. Instructing the model to pass short input through verbatim does NOT
# work; it ignores that rule precisely when the input is too thin to anchor it.
# Below the floor there is also nothing to gain: an utterance this short has no
# rambling to condense and is already the clearest form of itself.
MIN_WORDS=12
words=$(printf '%s' "$raw" | wc -w | tr -d ' ')
[ "$words" -ge "$MIN_WORDS" ] || passthrough "only $words words (floor $MIN_WORDS), nothing to restructure"

command -v jq >/dev/null || passthrough "jq not found"
[ -f "$DIR/refine.txt" ] || passthrough "refine.txt missing"

curl -s -o /dev/null --max-time 0.3 "http://127.0.0.1:$PORT/health" \
  || passthrough "llama-server not up on :$PORT (start it with: dictate start)"

body=$(jq -n --rawfile sys "$DIR/refine.txt" --arg usr "$raw" '{
  messages: [ {role:"system", content:$sys}, {role:"user", content:$usr} ],
  temperature: 0,
  top_p: 1,
  seed: 0,
  max_tokens: 512,
  cache_prompt: true
}') || passthrough "failed to build request"

resp=$(curl -s --max-time 30 "http://127.0.0.1:$PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' -d "$body") \
  || passthrough "llama-server request failed"

out=$(printf '%s' "$resp" | jq -r '.choices[0].message.content // empty') \
  || passthrough "unparseable response"
[ -n "$out" ] || passthrough "empty completion ($(printf '%s' "$resp" | jq -rc '.error.message // "no error field"'))"

# The prompt forbids fences and wrapping quotes; models do it anyway. Strip them
# rather than pasting ```markdown``` into whatever document is focused.
out=$(printf '%s' "$out" \
  | sed -E '/^[[:space:]]*```/d' \
  | tr '\n' ' ' \
  | sed -E 's/^[[:space:]]*"(.*)"[[:space:]]*$/\1/; s/  +/ /g; s/^ +| +$//g')

[ -n "$out" ] || passthrough "response was only formatting"

# Re-apply the jargon replacements: the model is told to keep technical nouns
# verbatim but is not guaranteed to, and invariant 3 says a jargon fix has to hold
# on every path. Costs ~10ms on a ~1500ms stage.
printf '%s' "$out" | sh "$DIR/clean.sh"
