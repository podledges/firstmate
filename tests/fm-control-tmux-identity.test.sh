#!/usr/bin/env bash
# Real tmux servers, real backend/control/spawn, no installed AI harness or model.
# Regression for missing-on-another-server being mistaken for destroyed.
set -euo pipefail
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
command -v tmux >/dev/null || { echo 'skip: tmux not found'; exit 0; }
LAB=$(fm_test_tmproot fm-tmux-identity)
REAL_TMUX=$(command -v tmux)
STANDIN=$(fm_agent_standin "$LAB/standin") || { echo 'skip: native stand-in unavailable'; exit 0; }
ID="identity-${BASHPID:-$$}"
TASK_TMP="/tmp/fm-$ID"
cleanup_identity() {
  "$REAL_TMUX" -S "$LAB/a.sock" kill-server 2>/dev/null || true
  "$REAL_TMUX" -S "$LAB/b.sock" kill-server 2>/dev/null || true
  if [ -d "$TASK_TMP" ]; then rm -rf -- "$TASK_TMP"; fi
  find "$LAB" -type d -exec chmod u+w {} + 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup_identity EXIT
mkdir -p "$LAB/fakebin" "$LAB/user" "$LAB/home/state" "$LAB/home/data/$ID"
cp "$STANDIN" "$LAB/fakebin/codex"
cat > "$LAB/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${PROBE_UNREADABLE_INVENTORY:-0}" = 1 ] && [ "${1:-}" = list-windows ] && [ "${2:-}" = -a ]; then exit 1; fi
if [ "${PROBE_RACE_CREATE:-0}" = 1 ] && [ "${1:-}" = if-shell ] && [[ "${3:-}" == *'#{S:'* ]]; then
  "$REAL_TMUX" -S "$PROBE_SOCKET" new-window -d -t lab: -n "$PROBE_RACE_WINDOW"
fi
exec "$REAL_TMUX" -S "$PROBE_SOCKET" "$@"
SH
chmod +x "$LAB/fakebin/tmux"
fm_fake_exit0 "$LAB/fakebin" no-mistakes gh-axi gh treehouse
export REAL_TMUX PROBE_SOCKET="$LAB/a.sock" PATH="$LAB/fakebin:$PATH"
export FM_HOME="$LAB/home" HOME="$LAB/user" FM_BACKEND=tmux FM_ROOT_OVERRIDE="$ROOT"
unset TMUX HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID
export FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.05 FM_CONTROL_LAUNCH_WAIT=10
. "$ROOT/bin/fm-wake-lib.sh"
. "$ROOT/bin/fm-backend.sh"
. "$ROOT/bin/fm-control-lib.sh"
fm_backend_source tmux
# Include spaces, a dollar and a quote to exercise tmux's command-string quoting.
WT="$LAB/task space ' dollar\$"
fm_git_worktree "$LAB/project" "$WT" "fm/$ID"
printf 'unfinished work\n' > "$WT/uncommitted.txt"
printf '# Task\n## Captain\x27s intent\nPreserve unfinished work.\n\n## Firstmate spec\nExercise identity-checked recovery.\n' > "$FM_HOME/data/$ID/brief.md"
META="$FM_HOME/state/$ID.meta"
TARGET="lab:fm-$ID"
cat > "$META" <<EOF
window=$TARGET
endpoint_task_id=$ID
worktree=$WT
project=$LAB/project
harness=codex
kind=ship
mode=no-mistakes
yolo=off
branch=fm/$ID
model=default
effort=default
EOF
for socket in a b; do
  "$REAL_TMUX" -f /dev/null -S "$LAB/$socket.sock" new-session -d -s lab -n keeper
  "$REAL_TMUX" -S "$LAB/$socket.sock" set-option -g default-shell "$(command -v bash)"
done
tmux new-window -d -t lab: -n "fm-$ID" -c "$WT"
fm_backend_tmux_bind_task "$TARGET" >> "$META"
fm_backend_tmux_binding_matches "$META" || fail 'fresh task binding did not match'
cp "$META" "$LAB/original.meta"
# The real classifier says missing on B while the original window still lives on A.
[ "$(PROBE_SOCKET="$LAB/b.sock" fm_backend_agent_state tmux "$TARGET")" = missing ] || fail 'wrong-server counterfactual did not reproduce'
tmux display-message -p -t "=$TARGET" '#{pane_dead}' | grep -qx 0 || fail 'original endpoint was not alive'
if PROBE_SOCKET="$LAB/b.sock" "$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'must refuse wrong server' > "$LAB/wrong.out" 2>&1; then
  fail 'wrong-server relaunch succeeded'
fi
assert_grep 'server identity' "$LAB/wrong.out" 'wrong server refusal lost its reason'
cmp "$META" "$LAB/original.meta" || fail 'wrong-server refusal changed the record'
pass 'tmux recovery refuses another live server while the original endpoint survives'

# Renaming a window does not destroy it, and a new window borrowing its old
# name must not receive even an exit command meant for the original window.
original_window=$(fm_meta_get "$META" tmux_window_id)
tmux rename-window -t "$original_window" renamed
if "$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'must refuse renamed' > "$LAB/renamed.out" 2>&1; then fail 'renamed window authorized recovery'; fi
assert_contains "$(cat "$LAB/renamed.out")" 'moved or renamed' 'renamed-window refusal lost its reason'
replacement=$(tmux new-window -dP -F '#{window_id}' -t lab: -n "fm-$ID")
if "$ROOT/bin/fm-control.sh" "$ID" exit > "$LAB/reused.out" 2>&1; then fail 'old name authorized lifecycle input to another window'; fi
assert_grep 'window identity' "$LAB/reused.out" 'name-reuse refusal lost its reason'
tmux kill-window -t "$replacement"
tmux rename-window -t "$original_window" "fm-$ID"
cmp "$META" "$LAB/original.meta" || fail 'renaming or name reuse changed metadata'
pass 'renamed windows and reused endpoint names do not authorize recovery or lifecycle input'

# Missing endpoint on the positively bound original server is recoverable.
tmux kill-window -t "=$TARGET"
[ "$(fm_control_endpoint_absence_verdict tmux "$TARGET" "$META")" = $'gone\t' ] || fail 'bound missing endpoint was not proven gone'
# A direct launch cannot authorize the missing-ship transaction.
if "$ROOT/bin/fm-spawn.sh" "$ID" --relaunch --harness codex > "$LAB/direct.out" 2>&1; then
  fail 'direct spawn recreated a missing terminal'
fi
assert_grep 'control plane' "$LAB/direct.out" 'direct recovery refusal lost its reason'
# Legacy and partial records never borrow a binding from the ambient server.
for shape in legacy partial duplicate changed-process missing-window-id duplicate-window-id; do
  case "$shape" in
    legacy) grep -v '^tmux_' "$LAB/original.meta" > "$META" ;;
    partial) grep -v '^tmux_server_token=' "$LAB/original.meta" > "$META" ;;
    duplicate) cp "$LAB/original.meta" "$META"; grep '^tmux_server_token=' "$LAB/original.meta" >> "$META" ;;
    changed-process) awk '/^tmux_server_identity=/ {$0="tmux_server_identity=different-process"} {print}' "$LAB/original.meta" > "$META" ;;
    missing-window-id) grep -v '^tmux_window_id=' "$LAB/original.meta" > "$META" ;;
    duplicate-window-id) cp "$LAB/original.meta" "$META"; grep '^tmux_window_id=' "$LAB/original.meta" >> "$META" ;;
  esac
  cp "$META" "$LAB/before.meta"
  if "$ROOT/bin/fm-control.sh" "$ID" relaunch --note "must refuse $shape" > "$LAB/$shape.out" 2>&1; then
    fail "$shape record authorized recovery"
  fi
  cmp "$META" "$LAB/before.meta" || fail "$shape refusal changed metadata"
  [ "$(fm_backend_agent_state tmux "$TARGET")" = missing ] || fail "$shape refusal created an endpoint"
done
cp "$LAB/original.meta" "$META"
if PROBE_UNREADABLE_INVENTORY=1 "$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'must refuse unreadable inventory' > "$LAB/unreadable.out" 2>&1; then fail 'unreadable inventory authorized recovery'; fi
cmp "$META" "$LAB/original.meta" || fail 'unreadable inventory changed metadata'
# A new endpoint appearing after the client proof must also refuse atomically.
if PROBE_RACE_CREATE=1 PROBE_RACE_WINDOW="fm-$ID" "$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'name race should refuse' > "$LAB/race.out" 2>&1; then fail 'name race created a replacement'; fi
[ "$(tmux list-windows -t lab -F '#{window_name}' | grep -cx "fm-$ID")" = 1 ] || fail 'recovery raced into duplicate windows'
assert_grep 'could not recreate' "$LAB/race.out" 'server-side name race was not refused'
tmux kill-window -t "=$TARGET"
pass 'unreadable inventories, changed process identities and concurrent name reuse refuse recovery'
# The same proof does not authorize a scout recreation.
awk '{sub(/^kind=ship$/, "kind=scout"); print}' "$LAB/original.meta" > "$META"
if "$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'must refuse scout' > "$LAB/scout.out" 2>&1; then fail 'scout recovered'; fi
assert_grep 'ordinary ship' "$LAB/scout.out" 'scout restriction lost'
cp "$LAB/original.meta" "$META"
head_before=$(git -C "$WT" rev-parse HEAD)
if ! "$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'recover on the bound server' > "$LAB/recovered.out" 2>&1; then
  fail "verified ship recovery failed: $(cat "$LAB/recovered.out")"
fi
[ "$(git -C "$WT" rev-parse HEAD)" = "$head_before" ] || fail 'recovery changed the task commit'
[ "$(cat "$WT/uncommitted.txt")" = 'unfinished work' ] || fail 'recovery discarded unfinished work'
[ "$(fm_meta_get "$META" worktree)" = "$WT" ] || fail 'recovery allocated a different copy'
fm_backend_tmux_binding_matches "$META" || fail 'replacement lost server binding'
[ "$(tmux list-windows -t lab -F '#{window_name}' | grep -cx "fm-$ID")" = 1 ] || fail 'recovery duplicated the task endpoint'
pass 'verified original-server ship recovery preserves the branch, unfinished work and one endpoint'

# A new server at the identical socket/session/window names is a different instance.
old_server_pid=$(tmux display-message -p '#{pid}')
"$REAL_TMUX" -S "$LAB/a.sock" kill-server
for _ in $(seq 1 100); do
  old_state=$(ps -p "$old_server_pid" -o stat= 2>/dev/null || true)
  case "$old_state" in ''|*Z*) break ;; esac
  sleep 0.02
done
case "$old_state" in ''|*Z*) ;; *) fail 'fixture server did not exit' ;; esac
"$REAL_TMUX" -f /dev/null -S "$LAB/a.sock" new-session -d -s lab -n keeper
fm_backend_tmux_bind_task lab:keeper > "$LAB/restarted.binding"
if fm_backend_tmux_binding_matches "$META"; then fail 'same socket path hid a server replacement'; fi
if "$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'must refuse new server' > "$LAB/restarted.out" 2>&1; then fail 'replacement instance authorized recovery'; fi
assert_grep 'server identity' "$LAB/restarted.out" 'new-instance refusal lost its reason'
pass 'a replaced server at the same socket and legacy/partial/duplicate bindings refuse recovery'
