# Common mishears → canonical jargon. Grow this file as you catch new ones.
#
# Every rule is word-anchored with [[:<:]] / [[:>:]] (BSD sed supports these).
# Unanchored rules corrupt real words: a bare s/[Ww]ork ?tree/worktree/ turns
# "network tree" into "networktree". Add a case to tests/replacements.tsv for
# every rule, then run `dictate test`.
s/[[:<:]][Pp]ixie[[:>:]]/pixi/g
s/[[:<:]][Rr]oss ?bag[[:>:]]/rosbag/g
s/[[:<:]][Rr]os ?two[[:>:]]/ros2/g
# Whisper spells the host three ways: "Tyler Zero-One", "Tyler 01", "Tyler01".
# The spoken forms may be capitalised and hyphenated, so match both.
s/[[:<:]][Tt]yler[ -]?([Oo]h|[Zz]ero)[ -]?([Oo]ne|1)[[:>:]]/tyler01/g
s/[[:<:]][Tt]yler[ -]?([Oo]h|[Zz]ero)[ -]?([Zz]ero|0)[[:>:]]/tyler00/g
s/[[:<:]][Tt]yler (0[01])[[:>:]]/tyler\1/g
s/[[:<:]]Tyler0/tyler0/g
s/[[:<:]]od ?ometry[[:>:]]/odometry/g
s/[[:<:]]([Tt]eensie|[Tt]insy|[Tt]eenzy)[[:>:]]/Teensy/g
s/[[:<:]][Rr]obo ?[Cc]law[[:>:]]/RoboClaw/g
s/[[:<:]][Pp]in ?[Pp]oint[[:>:]]/Pinpoint/g
s/[[:<:]]([Ww]hat ?son|[Ww]atson)[[:>:]]/Wattson/g
s/[[:<:]][Oo]dom(etry)? ?raw[[:>:]]/odom_raw/g
s/[[:<:]][Ee][Kk][Ff][[:>:]]/EKF/g
s/[[:<:]][Ll][Vv][Tt][[:>:]]/LVT/g
s/[[:<:]][Xx] ?fail[[:>:]]/xfail/g
s/[[:<:]][Ww]ork ?tree[[:>:]]/worktree/g
s/[[:<:]][Cc]laude ?[Mm][Dd][[:>:]]/CLAUDE.md/g
# Residual misses that glossary bias could not win even from the last slots.
# Safe to rewrite because the wrong form is not an English word.
s/[[:<:]][Zz] ?fail[[:>:]]/xfail/g
s/[[:<:]]([Oo]nks|[Aa]nx|[Oo]ncs)[[:>:]]/ONNX/g
s/[[:<:]][Rr]off[[:>:]]/ruff/g
# Caught in real dictation (daemon.log), not synthesised.
# "so whisperer Damien" was "so whisper daemon"; "Even Damion or whatever's log"
# was "even the daemon's log" — whisper picks a different name each time, so the
# vowel is matched as a class rather than adding one rule per spelling.
s/[[:<:]][Dd]ami[eo]n[[:>:]]/daemon/g
s/[[:<:]][Ll]l?ama[ -]?[Cc][Pp][Pp][[:>:]]/llama.cpp/g
s/[[:<:]][Ww]hisper[ -]?[Cc][Pp][Pp][[:>:]]/whisper.cpp/g
# "my user-claw conventions" was "my user CLAUDE conventions". Deliberately NOT a
# bare claw→Claude rule: "claw" is a real word and RoboClaw is in the glossary.
s/[[:<:]][Cc]law ?[Cc]ode[[:>:]]/Claude Code/g
s/[[:<:]][Uu]ser[ -][Cc]law[[:>:]]/user CLAUDE/g
# "git" is heard as "get", and whisper punctuates the pause after it as a comma
# ("Get pull." / "Git, pull." — two consecutive takes in daemon.log, neither
# usable). Only subcommands whose "get X" form is NOT a real English phrase are
# listed: "get status", "get log", "get diff" and "get branch" are all things a
# person says and are deliberately absent — the same reasoning that keeps a bare
# claw→Claude rule out of this file.
s/[[:<:]]([Gg]et|[Gg]it),? (pull|push|commit|checkout|clone|fetch|merge|rebase|stash)[[:>:]]/git \2/g
# "pull" also comes back as "poll", caught by the `say` probe rather than the log.
# Anchored to the git prefix on purpose: a bare poll→pull rule would break
# "poll the sensor", which is the normal meaning of the word in this codebase.
s/[[:<:]]([Gg]et|[Gg]it),? poll[[:>:]]/git pull/g
# Whisper splits the compound into two words. The glossary alone did not hold it:
# AprilTag sits in jargon.txt and "April tag" still reached the log, because bias
# is probabilistic and sed is not. Justified here rather than in the glossary
# because "April tag" is two real words that do not form a real phrase — unlike
# mypy→"might be", which is a phrase and therefore glossary-only.
s/[[:<:]][Aa]pril ?[Tt]ag(s?)[[:>:]]/AprilTag\1/g
