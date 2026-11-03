#!/usr/bin/env bash
# Narrated CLI transcript reusing the fm-send-defer test fixtures (fake tmux pane).
set -u
W=/Users/podles/.no-mistakes/worktrees/20a60ebd2894/01M6F96AD53FE5YW6YQQ87GD2F
cd "$W"
HELP=$(mktemp); sed -n "1,/^test_focused_send_defers_then_delivers_once$/p" tests/fm-send-defer.test.sh | sed "\$d" | sed "s|\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh|$W/tests/lib.sh|" > "$HELP"; . "$HELP"; rm -f "$HELP"
say() { printf '\n$ %s\n' "$*"; }
d=$(new_case transcript)
echo "== 1. Captain focuses the pane and is typing a draft =="
set_focus "$d" $'1\t1\t1'; printf 'pending' > "$d/fake/composer"
say "fm-send.sh t1 'first conversational message'"
run_send "$d" t1 'first conversational message'; echo "exit=$?"; cat "$d/send.err"
echo "inbox: $(ls "$d/home/state/t1.inbox" | tr '\n' ' ')   pane literal input: [$(cat "$d/fake/literal")]"
say "fm-send.sh t1 '/compact first parser-native'"
run_send "$d" t1 '/compact first parser-native'; echo "exit=$?"; cat "$d/send.err"
say "fm-send.sh t1 '/review second parser-native'"
run_send "$d" t1 '/review second parser-native'; echo "exit=$?"; cat "$d/send.err"
say "fm-send.sh t1 --key Escape   (special key)"
run_send "$d" t1 --key Escape; echo "exit=$?"; cat "$d/send.err"
echo "pane literal input so far: [$(cat "$d/fake/literal")]   keys: [$(cat "$d/fake/keys")]"
echo "queue: $(ls "$d/home/state/send-queue" | tr '\n' ' ')"
echo; echo "== 2. Watcher tick while still focused =="
run_tick "$d"; echo "pane literal input: [$(cat "$d/fake/literal")]"
echo; echo "== 3. Captain leaves, composer empties; watcher tick =="
set_focus "$d" $'0\t0\t0'; printf 'empty' > "$d/fake/composer"
run_tick "$d"; echo "pane literal input (FIFO, once each):"; cat "$d/fake/literal"
run_tick "$d"; echo "after another tick, literal lines: $(wc -l < "$d/fake/literal" | tr -d ' ')"
