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
# "so whisperer Damien" was "so whisper daemon".
s/[[:<:]][Dd]amien[[:>:]]/daemon/g
s/[[:<:]][Ll]l?ama[ -]?[Cc][Pp][Pp][[:>:]]/llama.cpp/g
s/[[:<:]][Ww]hisper[ -]?[Cc][Pp][Pp][[:>:]]/whisper.cpp/g
# "my user-claw conventions" was "my user CLAUDE conventions". Deliberately NOT a
# bare claw→Claude rule: "claw" is a real word and RoboClaw is in the glossary.
s/[[:<:]][Cc]law ?[Cc]ode[[:>:]]/Claude Code/g
s/[[:<:]][Uu]ser[ -][Cc]law[[:>:]]/user CLAUDE/g
