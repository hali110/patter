#!/bin/sh
# glossary-probe.sh — guards the "glossary bias is recency-weighted" rule in
# CLAUDE.md. Run after editing jargon.txt's length or ordering, and after any
# whisper-cpp upgrade.
#
# Two different things are checked, and it matters which is which:
#
#   A  no prompt            -> "Watson"   the unaided mishear, the baseline
#   B  current jargon.txt   -> "Wattson"  REGRESSION GUARD. Fails if the glossary
#                                         has grown or been reordered until its
#                                         real terms fell out of the live window.
#   C  Wattson buried at    -> "Watson"   THE FINDING, still demonstrable: same
#      the front of a long                term, same audio, only position differs,
#      padded glossary                    and it stops working.
#
# B and C must disagree. If C ever prints "Wattson", the recency effect is gone
# and jargon.txt is allowed to grow again — until then, most important terms LAST.
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PORT=8090
TMP="$DIR/.probe-tmp"; mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

curl -s -o /dev/null --max-time 0.3 "http://127.0.0.1:$PORT/" \
  || { echo "whisper-server not up on :$PORT — run: dictate start" >&2; exit 1; }

say -o "$TMP/probe.aiff" "Ask Wattson to align the tyler zero one feeder"
afconvert -f WAVE -d LEI16@16000 -c 1 "$TMP/probe.aiff" "$TMP/probe.wav"

ask() {
  curl -s --max-time 30 "http://127.0.0.1:$PORT/inference" \
    -F "file=@$TMP/probe.wav" -F "temperature=0.0" -F "response_format=text" \
    -F "prompt=$1" | tr -d '\n'
}
check() {  # label | prompt | expected word | explanation when it fails
  got=$(ask "$2")
  case "$got" in
    *"$3"*) printf '  ok    %-26s %s\n' "$1" "$got" ;;
    *)      printf '  FAIL  %-26s %s\n        expected %s — %s\n' "$1" "$got" "$3" "$4"; fails=$((fails+1)) ;;
  esac
}

full="$(grep -v '^#' "$DIR/jargon.txt")"
# A disfluent tail, kept here because the SPEECH work wants to append one and the
# obvious objection is that it would steal the recency slots the glossary needs.
# Measured 2026-08-01: it does not — check F must stay ok in every ordering.
disf="Um, so, like, I mean, uh, you know, I was thinking maybe, uh, we should, um, you know, kind of, uh, I guess, er, hmm, so yeah, uh."
# Padding that pushes the real terms out of the live window without changing them.
pad="Glossary: alpha, bravo, charlie, delta, echo, foxtrot, golf, hotel, india, juliet, kilo, lima, mike, november, oscar, papa, quebec, romeo, sierra, tango, uniform, victor, whiskey, xray, yankee, zulu, anchor, ballast, capstan, davit, fathom, gunwale, halyard, jib, keel, mast."
fails=0

echo "glossary position probe"
check "A no prompt"          ""                        "Watson"  "baseline changed; whisper-cpp may have been upgraded"
check "B current jargon.txt" "$full"                   "Wattson" "the glossary has grown or been reordered — move key terms LAST"
check "C buried at front"    "Wattson, $pad"           "Watson"  "recency effect gone — jargon.txt may now grow; update CLAUDE.md"
check "F disfluent tail"     "$full $disf"             "Wattson" "a disfluent tail now costs the jargon bias — SPEECH item 3b assumed it does not"

# The 2026-07-31 edit added Claude/ChatGPT to the live window and paid for the slots
# by moving AprilTag and ONNX to the dead front, which also pushed Pinpoint and
# odom_raw out. Checks A-C only ever exercised Wattson, so none of that was covered.
# These two probe the terms that actually moved. Note what each proves:
#   D  is a real glossary test — "chat GPT" is what whisper returns unaided.
#   E  runs through clean.sh on purpose, because the evicted terms are all sed-backed
#      and the claim being defended is "still correct end to end", not "still biased".
say -o "$TMP/moved.aiff" "The AprilTag detector loads an ONNX model and publishes odom raw from Pinpoint"
afconvert -f WAVE -d LEI16@16000 -c 1 "$TMP/moved.aiff" "$TMP/moved.wav"
say -o "$TMP/added.aiff" "I asked Claude and ChatGPT about the pixi environment"
afconvert -f WAVE -d LEI16@16000 -c 1 "$TMP/added.aiff" "$TMP/added.wav"
ask2() {
  curl -s --max-time 30 "http://127.0.0.1:$PORT/inference" \
    -F "file=@$1" -F "temperature=0.0" -F "response_format=text" -F "prompt=$2" | tr -d '\n'
}
for probe in "D added:added.wav:ChatGPT" "E evicted:moved.wav:odom_raw"; do
  label=${probe%%:*}; rest=${probe#*:}; wav=${rest%%:*}; want=${rest#*:}
  got=$(ask2 "$TMP/$wav" "$full" | sh "$DIR/clean.sh")
  case "$got" in
    *"$want"*) printf '  ok    %-26s %s\n' "$label" "$got" ;;
    *) printf '  FAIL  %-26s %s\n        expected %s — the jargon.txt reorder evicted a live term\n' "$label" "$got" "$want"; fails=$((fails+1)) ;;
  esac
done

# NOT checked here, deliberately: Claude. `say` enunciates it clearly enough that
# whisper gets it with NO prompt at all, so this harness cannot show the slot is
# earned. The evidence for it is real audio only — 10 of 10 "cloud" occurrences in
# the 612-take corpus were Claude, and re-transcribing them with the new glossary
# fixed 1 in 3. The other 2 are covered by anchored rules in replacements.sed.
[ "$fails" = 0 ] && echo "  all 6 as expected" || { echo "  $fails unexpected"; exit 1; }
