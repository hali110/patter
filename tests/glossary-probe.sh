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
# Padding that pushes the real terms out of the live window without changing them.
pad="Glossary: alpha, bravo, charlie, delta, echo, foxtrot, golf, hotel, india, juliet, kilo, lima, mike, november, oscar, papa, quebec, romeo, sierra, tango, uniform, victor, whiskey, xray, yankee, zulu, anchor, ballast, capstan, davit, fathom, gunwale, halyard, jib, keel, mast."
fails=0

echo "glossary position probe"
check "A no prompt"          ""                        "Watson"  "baseline changed; whisper-cpp may have been upgraded"
check "B current jargon.txt" "$full"                   "Wattson" "the glossary has grown or been reordered — move key terms LAST"
check "C buried at front"    "Wattson, $pad"           "Watson"  "recency effect gone — jargon.txt may now grow; update CLAUDE.md"
[ "$fails" = 0 ] && echo "  all 3 as expected" || { echo "  $fails unexpected"; exit 1; }
