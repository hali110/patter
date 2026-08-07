#!/bin/sh
# refine.sh — dictated transcript on stdin, restructured request on stdout.
#
# Second half of the AI path: transcribe.sh produces text, this reshapes it.
# Kept as a script for the same reason transcribe.sh is one — the daemon and the
# CLI (`patter refine`) must go through identical code or the two paths drift.
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
  || passthrough "llama-server not up on :$PORT (start it with: patter start)"

# 512 was set when takes were ~20s and was ~1.5x from firing on a real 398-word take
# (335 used). Raised to 1500 on 2026-08-01 as a deliberate decision, AFTER the
# finish_reason check below existed and never as a substitute for it: raising a cap
# without the check just moves an invisible cliff. With the check, the number only
# decides where ⌘ stops refining and starts passing through — roughly 1200 words now,
# against ~400 before, which is what keeps long thinking-out-loud (⌘'s best case) on
# the refine path. Cost is real and is budgeted separately in CLAUDE.md: generation is
# autoregressive, so a two-minute take is a ~6s stage and the ≤2000ms row does not
# apply to it.
MAX_TOKENS=1500
body=$(jq -n --rawfile sys "$DIR/refine.txt" --arg usr "$raw" --argjson max "$MAX_TOKENS" '{
  messages: [ {role:"system", content:$sys}, {role:"user", content:$usr} ],
  temperature: 0,
  top_p: 1,
  seed: 0,
  max_tokens: $max,
  cache_prompt: true
}') || passthrough "failed to build request"

resp=$(curl -s --max-time 30 "http://127.0.0.1:$PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' -d "$body") \
  || passthrough "llama-server request failed"

# A capped generation is the ONE failure this script cannot see by looking at its
# output: the server returns HTTP 200 and a complete-LOOKING string, so every check
# below passes and the daemon pastes a sentence cut mid-word, with nothing in the log.
# That is the "silently ate a sentence" bug CLAUDE.md calls the worst one here, and
# it arrived by exactly the route that bug always takes — the cap was set when takes
# were ~20s, then a 123.7s / 398-word take on 2026-07-31 used 335 of 512 and nobody
# had looked at the field that says so. Reproduced by forcing the cap down on that
# take's real input: finish_reason=length, output ending "...don't care about the
# results. They".
#
# Deliberately passthrough rather than raise MAX_TOKENS. Raising it moves the cliff
# without removing it, and generation is autoregressive so a bigger cap is also a
# longer worst case; the check is what makes the cliff impossible. Raising it as well
# is a latency decision, and it belongs with the long-take budget question, not here.
fin=$(printf '%s' "$resp" | jq -r '.choices[0].finish_reason // "absent"')
[ "$fin" != "length" ] \
  || passthrough "model hit the ${MAX_TOKENS}-token cap (finish_reason=length) — refusing to paste a truncated refinement"

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
# Persist the raw -> refined pair when retention is on. This is the eval corpus for
# every future refine decision (a model swap is unmeasurable without it), and until
# now it existed ONLY as a `raw:` line in daemon.log — a file the daemon rotates at
# 1MB keeping two generations, silently destroying the third. That line was built for
# forensics ("did the model drop a requirement"), then quietly relied on as storage;
# only the forensic durability was ever designed for.
#
# Captured here because refine.sh is the one place that sees both halves, and because
# a shell change costs no rebuild and therefore no Accessibility grant. One
# self-contained file per pair, so nothing has to be joined by timestamp later.
#
# Only reached when the model actually ran: every passthrough() exits before this, and
# a passthrough has no pair to record.
#
# PATTER_REFINE_TEST excludes the test suite, which calls this script directly and
# would otherwise write one pair per case into the corpus under the same filename
# shape as a field take. That is not hypothetical: 7 of the 12 pairs on disk at
# 2026-07-31 were `tests/refine.tsv` cases from a single 3-second run on 07-30, and
# they were mistaken for field takes for two days — the corpus read as 12 examples
# when it held 5. A synthetic pair is worse than no pair here, because the whole point
# of the corpus is to measure the model against speech nobody wrote for it.
if [ -f "$DIR/takes/.enabled" ] && [ -z "$PATTER_REFINE_TEST" ]; then
  { printf '=== raw ===\n%s\n=== refined ===\n%s\n' "$raw" "$out"; } \
    > "$DIR/takes/$(date +%Y%m%d-%H%M%S)-$$.pair.txt" \
    || echo "refine: could not retain pair" >&2
fi

printf '%s' "$out" | sh "$DIR/clean.sh"
