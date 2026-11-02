#!/usr/bin/env bash
# Guarded live Herdr regression for focused/pending steer and lifecycle splices.
# Every setup, inspection, and cleanup operation goes through the fleet's
# named non-default lab helper. The product commands under test use their
# normal metadata-routed Herdr adapter.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-/Users/podles/fleet/PodleMac/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: guarded Herdr lab helper not found at $HERDR_LAB_HELPER"; exit 0; }
command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

ORIGINAL_PATH=$PATH
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-send-pending-composer-splice) \
  || fail "could not allocate a guarded lab session name"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-send-herdr-safety.XXXXXX") || fail "could not create scratch directory"
FAKEBIN="$SCRATCH/fakebin"
mkdir -p "$FAKEBIN"
cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 || rc=1
  rm -rf "$SCRATCH"
  exit "$rc"
}
trap cleanup EXIT INT TERM

"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "could not provision isolated Herdr lab session"

# Route every adapter-owned Herdr call back through the guarded helper too.
# The adapter must still supply the exact trailing --session flag, which this
# shim validates and strips before helper-owned execution.
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$HERDR_LAB_SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $HERDR_LAB_SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"
export PATH="$FAKEBIN:$ORIGINAL_PATH"
lab() { env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
HERDR_STATUS=$(lab status --json) || fail "could not read isolated Herdr status"
HERDR_VERSION=$(printf '%s' "$HERDR_STATUS" | jq -r '.client.version // "unknown"')
HERDR_PROTOCOL=$(printf '%s' "$HERDR_STATUS" | jq -r '.client.protocol // "unknown"')

PROJ="$SCRATCH/project"
WT="$SCRATCH/worktree"
HOME_DIR="$SCRATCH/home"
mkdir -p "$PROJ" "$HOME_DIR/state" "$HOME_DIR/data/safety"
git -C "$PROJ" init -q
git -C "$PROJ" config user.name 'Firstmate Tests'
git -C "$PROJ" config user.email 'tests@example.invalid'
printf '# fixture\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" commit -qm initial
git -C "$PROJ" worktree add --quiet -b fm/safety "$WT"
printf '# Safety fixture\n' > "$HOME_DIR/data/safety/brief.md"

CREATED=$(lab workspace create --label fm-safety-e2e) \
  || fail "could not create the lab workspace"
WORKSPACE_ID=$(printf '%s' "$CREATED" | jq -r '.result.workspace.workspace_id // empty')
TAB_ID=$(printf '%s' "$CREATED" | jq -r '.result.root_pane.tab_id // empty')
PANE_ID=$(printf '%s' "$CREATED" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$WORKSPACE_ID" ] && [ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] \
  || fail "workspace create did not return workspace, tab, and pane ids"

{
  printf 'window=%s:%s\n' "$HERDR_LAB_SESSION" "$PANE_ID"
  printf 'endpoint_task_id=safety\n'
  printf 'worktree=%s\n' "$WT"
  printf 'project=%s\n' "$PROJ"
  printf 'harness=claude\nkind=ship\nmode=no-mistakes\nyolo=off\nmodel=default\neffort=default\n'
  printf 'backend=herdr\nherdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\n' \
    "$HERDR_LAB_SESSION" "$WORKSPACE_ID" "$TAB_ID" "$PANE_ID"
} > "$HOME_DIR/state/safety.meta"

lab pane report-agent "$PANE_ID" --source fm-send-safety-e2e \
  --agent claude --state idle >/dev/null \
  || fail "could not register the fixture agent"
FOCUS=$(lab pane list | jq -r --arg pane "$PANE_ID" '
  [.result.panes[]? | select(.pane_id == $pane)]
  | if length == 1 then .[0].focused else "ambiguous" end
') || fail "could not read the lab pane focus field"
[ "$FOCUS" = true ] || fail "Herdr did not expose focused=true for the active lab pane (got $FOCUS)"
pass "real Herdr: pane list exposes focused=true for the active pane"
sleep 1

read_pane() {
  lab pane read "$PANE_ID" --source recent --lines 200
}
run_send() {
  env FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-send.sh" "$@"
}
run_control() {
  env FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_CONTROL_POLL=0.1 FM_CONTROL_EXIT_WAIT=1 \
    "$ROOT/bin/fm-control.sh" "$@"
}

EMPTY_BEFORE=$(read_pane) || fail "could not capture the focused empty composer"
set +e
FOCUSED_OUT=$(run_send safety 'FOCUSED EMPTY STEER' 2>&1); FOCUSED_RC=$?
set -e
[ "$FOCUSED_RC" = 0 ] || fail "focused ordinary Herdr steer should remain durably sent, got $FOCUSED_RC: $FOCUSED_OUT"
[ -f "$HOME_DIR/state/safety.inbox/001.msg" ] || fail "focused ordinary steer was not written to its durable inbox"
case "$FOCUSED_OUT" in *'doorbell deferred without input'*|*'doorbell not typed because the agent'*) : ;; *) fail "focused ordinary steer did not report that its doorbell was untouched: $FOCUSED_OUT" ;; esac
[ "$(read_pane)" = "$EMPTY_BEFORE" ] || fail "fm-send changed a focused empty composer"
pass "real Herdr: focused ordinary steer stays durable while its doorbell defers without input"

# Back the registered agent with a real agent-named foreground process whose
# composer retains typed bytes. Lifecycle control now proves process liveness,
# so registration alone is intentionally insufficient for this live refusal.
CC_BIN=$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || true)
[ -n "$CC_BIN" ] || { echo "skip: no C compiler for the pending-composer agent stand-in"; exit 0; }
cat > "$SCRATCH/pending-agent.c" <<'EOF_AGENT'
#include <signal.h>
#include <stddef.h>
#include <termios.h>
#include <unistd.h>
static struct termios saved;
static void finish(int sig) { (void)sig; tcsetattr(0, TCSANOW, &saved); _exit(0); }
int main(void) {
  struct termios raw;
  char byte, text[512];
  size_t used = 0;
  if (tcgetattr(0, &saved) != 0) return 1;
  raw = saved;
  raw.c_lflag &= (tcflag_t)~(ICANON | ECHO);
  raw.c_cc[VMIN] = 1;
  raw.c_cc[VTIME] = 0;
  if (tcsetattr(0, TCSANOW, &raw) != 0) return 1;
  signal(SIGTERM, finish);
  write(1, "❯ ", sizeof("❯ ") - 1);
  while (read(0, &byte, 1) == 1) {
    if (used < sizeof(text)) text[used++] = byte;
    write(1, "\r\033[2K❯ ", sizeof("\r\033[2K❯ ") - 1);
    write(1, text, used);
  }
  finish(0);
  return 0;
}
EOF_AGENT
mkdir -p "$SCRATCH/agentbin"
"$CC_BIN" -o "$SCRATCH/agentbin/claude" "$SCRATCH/pending-agent.c" 2>/dev/null \
  || { echo "skip: could not build the pending-composer agent stand-in"; exit 0; }
lab pane run "$PANE_ID" "$SCRATCH/agentbin/claude" >/dev/null \
  || fail "could not start the pending-composer agent stand-in"
AGENT_LIVE=0
for _ in $(seq 1 50); do
  if lab pane process-info --pane "$PANE_ID" 2>/dev/null \
    | jq -e '.result.process_info.foreground_processes[]? | select((.name // "") == "claude" or ((.argv0 // "") | endswith("/claude")))' >/dev/null; then
    AGENT_LIVE=1
    break
  fi
  sleep 0.1
done
[ "$AGENT_LIVE" = 1 ] || fail "pending-composer stand-in never became a live agent process"
lab pane report-agent "$PANE_ID" --source fm-send-safety-e2e \
  --agent claude --state idle >/dev/null \
  || fail "could not re-register the live pending-composer agent"

lab pane send-text "$PANE_ID" 'captain relaunch draft ' >/dev/null \
  || fail "could not seed unsent captain text"
sleep 0.5

BEFORE=$(read_pane) || fail "could not capture the seeded composer"
case "$BEFORE" in *'captain relaunch draft'*) : ;; *) fail "seeded captain draft was not visible" ;; esac

set +e
SEND_OUT=$(run_send safety '/FIRSTMATE STEER' 2>&1); SEND_RC=$?
set -e
[ "$SEND_RC" = 4 ] || fail "focused Herdr steer should defer with status 4, got $SEND_RC: $SEND_OUT"
AFTER_SEND=$(read_pane) || fail "could not inspect the composer after fm-send"
[ "$AFTER_SEND" = "$BEFORE" ] || fail "fm-send changed focused pending captain text"
case "$AFTER_SEND" in *'/FIRSTMATE STEER'*) fail "fm-send spliced its text into the captain draft" ;; esac
find "$HOME_DIR/state/send-queue" -maxdepth 1 -type d -name '*.pending' 2>/dev/null | grep -q . \
  || fail "focused Herdr steer was not durably deferred"
pass "real Herdr: focused pending steer is deferred without changing captain text"

# Exercise the other half of the guard independently: an unfocused pane with a
# structurally identified agent composer that already holds a draft.
PENDING_CREATE=$(lab tab create --workspace "$WORKSPACE_ID" --label fm-safety-pending --no-focus) \
  || fail "could not create the unfocused pending-composer pane"
PENDING_TAB_ID=$(printf '%s' "$PENDING_CREATE" | jq -r '.result.tab.tab_id // empty')
PENDING_PANE_ID=$(printf '%s' "$PENDING_CREATE" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$PENDING_TAB_ID" ] && [ -n "$PENDING_PANE_ID" ] \
  || fail "pending-composer tab create did not return ids"
lab pane run "$PENDING_PANE_ID" "bash -c 'printf \\\"❯ \\\"; read -r _line; sleep 300'" >/dev/null \
  || fail "could not start the pending-composer fixture"
sleep 0.5
lab pane report-agent "$PENDING_PANE_ID" --source fm-send-safety-e2e \
  --agent claude --state idle >/dev/null \
  || fail "could not register the pending-composer fixture"
lab pane send-text "$PENDING_PANE_ID" 'captain pending draft' >/dev/null \
  || fail "could not seed the unfocused pending composer"
sleep 0.5
PENDING_FOCUS=$(lab pane list | jq -r --arg pane "$PENDING_PANE_ID" '
  [.result.panes[]? | select(.pane_id == $pane)]
  | if length == 1 then .[0].focused else "ambiguous" end
') || fail "could not read pending-pane focus"
[ "$PENDING_FOCUS" = false ] || fail "pending fixture should be unfocused, got $PENDING_FOCUS"
{
  printf 'window=%s:%s\n' "$HERDR_LAB_SESSION" "$PENDING_PANE_ID"
  printf 'endpoint_task_id=pending\nworktree=%s\nproject=%s\n' "$WT" "$PROJ"
  printf 'harness=claude\nkind=ship\nmode=no-mistakes\nyolo=off\nmodel=default\neffort=default\n'
  printf 'backend=herdr\nherdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\n' \
    "$HERDR_LAB_SESSION" "$WORKSPACE_ID" "$PENDING_TAB_ID" "$PENDING_PANE_ID"
} > "$HOME_DIR/state/pending.meta"
PENDING_BEFORE=$(lab pane read "$PENDING_PANE_ID" --source recent --lines 200) \
  || fail "could not capture the unfocused pending composer"
case "$PENDING_BEFORE" in *'captain pending draft'*) : ;; *) fail "pending draft was not visible" ;; esac
set +e
PENDING_OUT=$(run_send pending '/PENDING COMPOSER STEER' 2>&1); PENDING_RC=$?
set -e
[ "$PENDING_RC" = 4 ] || fail "unfocused pending steer should defer with status 4, got $PENDING_RC: $PENDING_OUT"
case "$PENDING_OUT" in *'safety=composer-pending'*) : ;; *) fail "pending steer did not name composer safety: $PENDING_OUT" ;; esac
[ "$(lab pane read "$PENDING_PANE_ID" --source recent --lines 200)" = "$PENDING_BEFORE" ] \
  || fail "fm-send changed an unfocused pending composer"
case "$PENDING_BEFORE" in *'/PENDING COMPOSER STEER'*) fail "pending steer was spliced into the captain draft" ;; esac
pass "real Herdr: unfocused pending composer defers without changing captain text"

META_BEFORE=$(cat "$HOME_DIR/state/safety.meta")
BRIEF_BEFORE=$(cat "$HOME_DIR/data/safety/brief.md")
set +e
INTERRUPT_OUT=$(run_control safety interrupt 2>&1); INTERRUPT_RC=$?
set -e
[ "$INTERRUPT_RC" = 4 ] || fail "focused Herdr interrupt should refuse with status 4, got $INTERRUPT_RC: $INTERRUPT_OUT"
[ "$(read_pane)" = "$BEFORE" ] || fail "fm-control interrupt changed focused pending captain text"
[ "$(cat "$HOME_DIR/state/safety.meta")" = "$META_BEFORE" ] || fail "refused interrupt changed task metadata"
pass "real Herdr: focused pending interrupt refuses without terminal or durable-state mutation"

set +e
EXIT_OUT=$(run_control safety exit 2>&1); EXIT_RC=$?
set -e
[ "$EXIT_RC" = 4 ] || fail "focused Herdr exit should refuse with status 4, got $EXIT_RC: $EXIT_OUT"
AFTER_EXIT=$(read_pane) || fail "could not inspect the composer after exit"
[ "$AFTER_EXIT" = "$BEFORE" ] || fail "fm-control exit changed focused pending captain text"
[ "$(cat "$HOME_DIR/state/safety.meta")" = "$META_BEFORE" ] || fail "refused exit changed task metadata"
case "$AFTER_EXIT" in *'/exit'*) fail "fm-control exit spliced its command into the captain draft" ;; esac
pass "real Herdr: focused pending exit refuses without terminal or durable-state mutation"

set +e
RELAUNCH_OUT=$(run_control safety relaunch --note 'safety retry' 2>&1); RELAUNCH_RC=$?
set -e
[ "$RELAUNCH_RC" = 4 ] || fail "focused Herdr relaunch should refuse with status 4, got $RELAUNCH_RC: $RELAUNCH_OUT"
AFTER_RELAUNCH=$(read_pane) || fail "could not inspect the composer after relaunch"
[ "$AFTER_RELAUNCH" = "$BEFORE" ] || fail "fm-control relaunch changed focused pending captain text"
[ "$(cat "$HOME_DIR/state/safety.meta")" = "$META_BEFORE" ] || fail "refused relaunch changed task metadata"
[ "$(cat "$HOME_DIR/data/safety/brief.md")" = "$BRIEF_BEFORE" ] || fail "refused relaunch changed task instructions"
[ ! -e "$HOME_DIR/state/safety.control-relaunch" ] || fail "refused relaunch published a lifecycle journal"
case "$AFTER_RELAUNCH" in *'/exit'*) fail "fm-control relaunch spliced its exit command into the captain draft" ;; esac
pass "real Herdr: focused pending relaunch refuses before note, journal, command, or agent mutation"

echo "all live Herdr input-safety checks passed"
echo "evidence: herdr=$HERDR_VERSION protocol=$HERDR_PROTOCOL default-session-tripwire=armed"
