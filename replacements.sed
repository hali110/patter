# Common mishears → canonical jargon. Grow this file as you catch new ones.
#
# Every rule is word-anchored with [[:<:]] / [[:>:]] (BSD sed supports these).
# Unanchored rules corrupt real words: a bare s/[Ww]ork ?tree/worktree/ turns
# "network tree" into "networktree". Add a case to tests/replacements.tsv for
# every rule, then run `dictate test`.
s/[[:<:]][Pp]ixie[[:>:]]/pixi/g
s/[[:<:]][Rr]oss ?bag[[:>:]]/rosbag/g
s/[[:<:]][Rr]os ?two[[:>:]]/ros2/g
s/[[:<:]][Tt]yler ?(oh|zero) ?(one|1)[[:>:]]/tyler01/g
s/[[:<:]][Tt]yler ?(oh|zero) ?(zero|0)[[:>:]]/tyler00/g
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
