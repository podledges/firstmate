#!/usr/bin/env bash
# Behavior tests for process-local Codex/Grok homes, Grok hook authentication,
# teardown cleanup, and Grok session-lock holder detection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-grok-harness)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  send-keys)
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l)
          shift
          [ -z "${FM_FAKE_LAUNCH_LOG:-}" ] || printf '%s\n' "${1:-}" >> "$FM_FAKE_LAUNCH_LOG"
          exit 0
          ;;
        *) shift ;;
      esac
    done
    exit 0
    ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin personal_grok_home id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  personal_grok_home="$case_dir/personal-grok"
  id="grok-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$personal_grok_home"
  printf 'personal state\n' > "$personal_grok_home/personal-marker"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$personal_grok_home|$id"
}

run_harness_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 personal_grok_home=$5 id=$6 harness=$7
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" TMUX="fake,1,0" \
    CODEX_HOME="${personal_grok_home%/}/../personal-codex" \
    GROK_HOME="$personal_grok_home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" "$harness" --mode no-mistakes --yolo off 2>&1
}

path_mode() {
  if stat --version >/dev/null 2>&1; then
    stat -c %a "$1"
  else
    stat -f %Lp "$1"
  fi
}

test_grok_hook_requires_registered_token() {
  local rec case_dir home proj wt fakebin personal_grok_home id out status hook token target evil evil_target
  rec=$(make_spawn_case hook-auth)
  IFS='|' read -r case_dir home proj wt fakebin personal_grok_home id <<EOF
$rec
EOF
  out=$(run_harness_spawn "$home" "$proj" "$wt" "$fakebin" "$personal_grok_home" "$id" grok)
  status=$?
  expect_code 0 "$status" "grok spawn should succeed"
  assert_contains "$out" "spawned $id harness=grok" "grok spawn did not report success"

  hook="$home/data/agent-homes/grok/hooks/fm-turn-end.sh"
  assert_present "$hook" "grok hook script was not installed"
  assert_grep 'token=' "$wt/.fm-grok-turnend" "grok pointer did not contain a token"
  target="$home/state/$id.turn-ended"
  assert_no_grep "$target" "$wt/.fm-grok-turnend" "grok pointer exposed the turn-end path"
  token=$(sed -n 's/^token=//p' "$wt/.fm-grok-turnend")
  assert_present "$home/data/agent-homes/grok/hooks/fm-turn-end.d/$token" \
    "grok auth registry entry was not written"
  assert_absent "$personal_grok_home/hooks" "grok spawn wrote a hook into the ambient personal home"
  [ "$(cat "$personal_grok_home/personal-marker")" = 'personal state' ] \
    || fail "grok spawn modified the ambient personal home"
  assert_grep "GROK_HOME='$home/data/agent-homes/grok'" "$home/launch.log" \
    "grok launch did not carry its fixed Firstmate-private home"
  assert_no_grep 'export GROK_HOME=' "$home/launch.log" \
    "grok isolation leaked into the pane shell as a global export"
  [ "$(path_mode "$home/data/agent-homes")" = 700 ] || fail "agent-homes root is not private"
  [ "$(path_mode "$home/data/agent-homes/codex")" = 700 ] || fail "codex home is not private"
  [ "$(path_mode "$home/data/agent-homes/grok")" = 700 ] || fail "grok home is not private"

  evil="$case_dir/evil"
  evil_target="$case_dir/evil-target.turn-ended"
  mkdir -p "$evil"
  printf '%s\n' "$evil_target" > "$evil/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$evil" bash "$hook"
  assert_absent "$evil_target" "old-style grok pointer touched an arbitrary target"

  {
    printf '%s\n' 'ignored'
    printf 'token=%s\n' "$token"
  } > "$wt/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$wt" bash "$hook"
  assert_absent "$target" "grok pointer accepted token outside the first line"

  printf 'token=%s\n' "$token" > "$wt/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$wt" bash "$hook"
  assert_present "$target" "registered grok pointer did not touch the task turn-end file"
  pass "grok private hook requires a firstmate registry token"
}

test_grok_teardown_removes_pointer_and_token() {
  local rec case_dir home proj wt fakebin personal_grok_home id out status token
  rec=$(make_spawn_case teardown)
  IFS='|' read -r case_dir home proj wt fakebin personal_grok_home id <<EOF
$rec
EOF
  out=$(run_harness_spawn "$home" "$proj" "$wt" "$fakebin" "$personal_grok_home" "$id" grok)
  status=$?
  expect_code 0 "$status" "grok spawn should succeed before teardown"
  token=$(sed -n 's/^token=//p' "$wt/.fm-grok-turnend")

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    GROK_HOME="$personal_grok_home" PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" --force >/dev/null 2>&1 \
    || fail "grok teardown failed"

  assert_absent "$wt/.fm-grok-turnend" "grok pointer survived teardown"
  assert_absent "$home/data/agent-homes/grok/hooks/fm-turn-end.d/$token" \
    "grok auth token survived teardown"
  assert_absent "$home/state/$id.grok-turnend-token" "grok state token survived teardown"
  pass "grok teardown removes pointer and private token state"
}

test_codex_launch_uses_private_home_without_global_export() {
  local rec case_dir home proj wt fakebin personal_grok_home id out status personal_codex_home
  rec=$(make_spawn_case codex-home)
  IFS='|' read -r case_dir home proj wt fakebin personal_grok_home id <<EOF
$rec
EOF
  personal_codex_home="$case_dir/personal-codex"
  mkdir -p "$personal_codex_home"
  printf 'personal state\n' > "$personal_codex_home/personal-marker"

  out=$(run_harness_spawn "$home" "$proj" "$wt" "$fakebin" "$personal_grok_home" "$id" codex)
  status=$?
  expect_code 0 "$status" "codex spawn should succeed"
  assert_contains "$out" "spawned $id harness=codex" "codex spawn did not report success"
  assert_grep "CODEX_HOME='$home/data/agent-homes/codex'" "$home/launch.log" \
    "codex launch did not carry its fixed Firstmate-private home"
  assert_no_grep 'export CODEX_HOME=' "$home/launch.log" \
    "codex isolation leaked into the pane shell as a global export"
  [ "$(cat "$personal_codex_home/personal-marker")" = 'personal state' ] \
    || fail "codex spawn modified the ambient personal home"
  pass "codex launch uses a process-local Firstmate-private home"
}

test_fm_lock_recognizes_grok_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/usr/local/bin/grok'; exit 0 ;;
  *"args="*) printf '%s\n' 'grok'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize grok as a live holder"
  pass "fm-lock recognizes grok harness processes"
}

test_grok_hook_requires_registered_token
test_grok_teardown_removes_pointer_and_token
test_codex_launch_uses_private_home_without_global_export
test_fm_lock_recognizes_grok_holder
