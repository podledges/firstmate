# Fleet View

Schema: fm-fleet-snapshot.v1
Home: /tmp/fm-fleet-snapshot.fcpbJQ/fixture

## Under Way
| ID | Current | Kind | Repo/Project | Backend | Endpoint | Artifact | Path | Watch / return channel |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| cmux-task | unknown / none | ship | alpha | cmux | absent | - | /tmp/fm-fleet-snapshot.fcpbJQ/fixture/projects/missing-cmux (absent) | bin/fm-peek.sh fm-cmux-task |
| scout-task | unknown / pane | scout | alpha | tmux | present | /tmp/fm-fleet-snapshot.fcpbJQ/fixture/data/scout-task/report.md | /tmp/fm-fleet-snapshot.fcpbJQ/fixture/projects/scout-worktree | bin/fm-peek.sh fm-scout-task |
| secondmate-task | working / status-log | secondmate | /tmp/fm-fleet-snapshot.fcpbJQ/fixture/secondmate-home | tmux | present / alive | - | /tmp/fm-fleet-snapshot.fcpbJQ/fixture/secondmate-home | bin/fm-send.sh fm-secondmate-task '<request>' - read status/doc return channel; do not routinely fm-peek a secondmate for answers |
| ship-task | working / pane | ship | alpha | tmux | present | https://github.com/kunchenguid/firstmate/pull/9 | /tmp/fm-fleet-snapshot.fcpbJQ/fixture/projects/alpha-worktree | bin/fm-peek.sh fm-ship-task |

## Queued
| ID | Title | Repo | Kind | Blocked By | Artifact |
| --- | --- | --- | --- | --- | --- |
| queued-task | Queued Task | alpha | ship | ship-task | - |
| - | handoff note without canonical syntax | - | - | - | - |

## Done
| ID | Title | Repo | Kind | Blocked By | Artifact |
| --- | --- | --- | --- | --- | --- |
| done-task | Done Task | alpha | ship | - | https://github.com/kunchenguid/firstmate/pull/7 |

## Secondmates
For kind=secondmate, bearings selects validated structured state from that registered home; parent events and bounded terminal evidence are fallback-only supplements and never current-state authority.
