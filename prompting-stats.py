#!/usr/bin/env python3
"""Measure how Haider's prompting changes over time.

    ./dictate prompting            # weekly trend
    ./dictate prompting --split    # + dictated vs typed

Reads every session transcript under ~/.claude/projects and, when dictate's
daemon.log is present, labels each prompt by input method. Output is markdown,
ready to paste under a new dated heading in PROMPTING_LOG.md.

Stdlib only. Reads nothing but session logs; writes nothing.

Two measurement traps, both learned the hard way and both handled below:

  * Session timestamps are UTC. Bucketing them raw shifts a whole evening of
    prompts into the next day, which silently smears any daily comparison.
  * Roughly half of all "user" messages are pasted logs, code, stack traces and
    compaction summaries. Left in, they inflate mean prompt length by ~10x and
    swamp the signal. Only hand-authored prose is counted.

The dictated/typed split works by matching daemon.log transcripts verbatim
against prompt text — every take lands at the cursor, so the match is exact and
needs no guessing. It only reaches back as far as daemon.log is retained, so
early weeks show as unlabelled rather than as typed.
"""

import json
import pathlib
import re
import statistics
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

try:
    from zoneinfo import ZoneInfo
    LOCAL = ZoneInfo("America/Chicago")          # DST-correct, unlike a fixed -5
except Exception:
    LOCAL = timezone(timedelta(hours=-5))

PROJECTS = pathlib.Path.home() / ".claude" / "projects"

# Derived from this file's own location, never hardcoded — same rule the daemon
# follows with Bundle.main.bundleURL. Moving the checkout must not break it.
ROOT = pathlib.Path(__file__).resolve().parent
DAEMON_LOGS = [ROOT / "daemon.log", ROOT / "daemon.log.1"]

# Injected or pasted content that is not something Haider wrote.
SYNTHETIC = re.compile(
    r"This session is being continued|Caveat: The messages below|"
    r"<system-reminder>|<command-|<local-command|<teammate-message|tool_use_id"
)

SIGNALS = {
    # Fencing the work before it starts. The clearest skill signal in the data.
    "constraint": re.compile(
        r"\b(don'?t|do not|only|instead of|make sure|without|except|avoid|never|keep it)\b", re.I),
    # Saying *why*. The thing an agent cannot reconstruct on its own.
    "reasoning": re.compile(r"\b(because|so that|since|the reason|that'?s why)\b", re.I),
    # Volunteering a theory rather than just a symptom.
    "hypothesis": re.compile(
        r"\b(i think|i feel like|it looks like|maybe|seems|might be|i'?m worried)\b", re.I),
    # Precision that costs nothing: @-referencing a file beats describing it.
    "@file/slash": re.compile(r"(^|\s)[@/][A-Za-z_][\w./-]*"),
    # Low-information turns.
    "bare-cont": re.compile(r"^\W*(continue|yes|ok|okay|go|go ahead|do it|sure|yep)\W*$", re.I),
    # Fast-typing slips. Near-zero when speaking, which is most of the point.
    "typos": re.compile(
        r"\b(teh|adn|hte|wnat|jsut|taht|seperate|recieve|alot|thier|wich|"
        r"cna|delte|ive|dont|doesnt|wont|cant|waht|wjat)\b", re.I),
}


def load_prompts():
    """Every human-authored prompt, as (local_datetime, text)."""
    out = []
    for f in PROJECTS.rglob("*.jsonl"):
        try:
            lines = f.read_text(errors="replace").splitlines()
        except OSError:
            continue
        for line in lines:
            if '"type":"user"' not in line and '"type": "user"' not in line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if rec.get("type") != "user" or rec.get("isMeta"):
                continue
            content = (rec.get("message") or {}).get("content")
            if isinstance(content, list):
                content = "\n".join(
                    b.get("text", "") for b in content
                    if isinstance(b, dict) and b.get("type") == "text")
            if not isinstance(content, str) or not content.strip():
                continue
            if SYNTHETIC.search(content):
                continue
            ts = rec.get("timestamp")
            if not ts:
                continue
            try:
                dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
            except ValueError:
                continue
            out.append((dt.astimezone(LOCAL), content.replace("\n", " ⏎ ")))
    out.sort()
    return out


def is_prose(t):
    """Hand-authored, not a pasted log/diff/traceback."""
    if "```" in t or t.count(" ⏎ ") > 3:
        return False
    return sum(c.isalpha() or c.isspace() for c in t) / max(1, len(t)) > 0.85


def spoken_lines():
    """Transcripts dictate actually pasted at the cursor, for the input-method split."""
    seen = set()
    for p in DAEMON_LOGS:
        if not p.exists():
            continue
        for line in p.read_text(errors="replace").splitlines():
            m = re.search(r"(?:raw|refine) audio=.*?· (.+)$", line)
            if m and len(m.group(1).strip()) > 25:
                seen.add(m.group(1).strip())
    return seen


def profile(texts):
    w = [len(t.split()) for t in texts]
    row = {
        "n": len(texts),
        "median": statistics.median(w) if w else 0,
        "<=5w": sum(1 for x in w if x <= 5) * 100 // max(1, len(w)),
        ">=30w": sum(1 for x in w if x >= 30) * 100 // max(1, len(w)),
    }
    for name, pat in SIGNALS.items():
        row[name] = sum(1 for t in texts if pat.search(t)) * 100 // max(1, len(texts))
    return row


COLS = ["n", "median", "<=5w", ">=30w", "constraint", "reasoning",
        "hypothesis", "@file/slash", "bare-cont", "typos"]


def table(rows, label):
    print(f"| {label} | " + " | ".join(COLS) + " |")
    print("|" + "---|" * (len(COLS) + 1))
    for name, r in rows:
        cells = []
        for c in COLS:
            v = r[c]
            cells.append(f"{v}" if c in ("n", "median") else f"{v}%")
        print(f"| {name} | " + " | ".join(cells) + " |")


def main():
    prompts = load_prompts()
    prose = [(d, t) for d, t in prompts if is_prose(t)]
    print(f"_{len(prompts)} prompts total, {len(prose)} hand-authored prose "
          f"({len(prose) * 100 // max(1, len(prompts))}%). "
          f"Range {prose[0][0].date()} → {prose[-1][0].date()}._\n")

    weeks = defaultdict(list)
    for d, t in prose:
        weeks[(d - timedelta(days=d.weekday())).date()].append(t)
    table([(f"week of {k}", profile(v)) for k, v in sorted(weeks.items()) if len(v) >= 10],
          "week")

    if "--split" in sys.argv:
        spoken = spoken_lines()
        if not spoken:
            print("\n_No daemon.log found — cannot split dictated vs typed._")
            return
        # Compare like with like: only from the first day a dictated prompt
        # appears. Earlier weeks predate daemon.log and would count as "typed".
        labelled = [(d, t, any(s in t for s in spoken)) for d, t in prose]
        spoken_days = [d.date() for d, _, hit in labelled if hit]
        if not spoken_days:
            print("\n_No dictated prompts matched — cannot split._")
            return
        start = min(spoken_days)
        window = [(t, hit) for d, t, hit in labelled if d.date() >= start]
        dic = [t for t, hit in window if hit]
        typ = [t for t, hit in window if not hit]
        print(f"\n_Input-method split over the {len(window)} prose prompts since "
              f"{start}, the first day dictation appears in daemon.log._\n")
        table([("DICTATED", profile(dic)), ("TYPED", profile(typ))], "input")


if __name__ == "__main__":
    main()
