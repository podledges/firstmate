#!/usr/bin/env bash
# Regression tests for per-home Treehouse pool allocation and slot screening.
#
# Treehouse keys a pool by repository, not by clone, and calls a slot free from
# the processes attached to it. Two faults followed, both measured live: a spawn
# from one Firstmate home was handed a worktree of ANOTHER home's clone, and
# slots that were simultaneously bound to another clone or still holding a held
# task's preserved, unlanded commits were reported available to every home.
#
# These cases drive the real bin/fm-spawn.sh and bin/fm-teardown.sh with a fake
# terminal and a fake treehouse whose pool status the fixture writes, and prove
# that allocation is scoped per home, that a slot nobody may reuse refuses the
# spawn by name while leaving every pool worktree exactly as it was, and that a
# worktree recorded under any earlier root is still returned to the pool its own
# path names.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-treehouse-pool-scope)

# --- fixture ----------------------------------------------------------------

# A fake treehouse that logs every call and answers `status --json` from the
# pool listing the case wrote, so a case controls exactly which slots the real
# screen is offered. `treehouse get` itself is typed into the pane, which the
# fake tmux answers with FM_FAKE_PANE_PATH, so it never reaches this binary.
make_pool_fakebin() {  # <dir> -> echoes fakebin
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_test_fake_tmux_spawn "$fakebin"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
{ printf 'treehouse'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } \
  >> "${FM_FAKE_TREEHOUSE_LOG:?}"
if [ "${1:-}" = status ]; then
  if [ -n "${FM_FAKE_POOL_STATUS:-}" ] && [ -f "$FM_FAKE_POOL_STATUS" ]; then
    cat "$FM_FAKE_POOL_STATUS"
  else
    printf '[]\n'
  fi
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" gh gh-axi no-mistakes
  printf '%s\n' "$fakebin"
}

# One origin, this home's clone, a second clone of the same origin standing in
# for another home's copy, and an empty pool directory in the managed
# <root>/.treehouse/<pool>/<slot>/<repo> layout.
make_pool_case() {  # <name> <task-id> -> echoes case dir
  local name=$1 id=$2 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir"
  fm_git_init_commit "$case_dir/seed"
  git clone --quiet --bare "$case_dir/seed" "$case_dir/origin.git"
  git clone --quiet "file://$case_dir/origin.git" "$case_dir/project"
  git clone --quiet "file://$case_dir/origin.git" "$case_dir/other-clone"
  mkdir -p "$case_dir/root/.treehouse/pool"
  printf '{"worktrees":[]}\n' > "$case_dir/root/.treehouse/pool/treehouse-state.json"
  fm_test_spawn_home "$case_dir/home" codex
  fm_test_spawn_brief "$case_dir/home" "$id"
  : > "$case_dir/treehouse.log"
  : > "$case_dir/pane.log"
  make_pool_fakebin "$case_dir/fake" > "$case_dir/fakebin-path"
  printf '%s\n' "$case_dir"
}

slot_path() {  # <case> <n> -> the repo checkout inside pool slot <n>
  printf '%s/root/.treehouse/pool/%s/project\n' "$1" "$2"
}

# A clean slot sitting on the default branch: reusing it destroys nothing.
add_landed_slot() {  # <case> <n>
  local case_dir=$1 n=$2 slot
  slot=$(slot_path "$case_dir" "$n")
  mkdir -p "$(dirname "$slot")"
  git -C "$case_dir/project" worktree add --quiet --detach "$slot" HEAD
}

# A clean slot holding a committed branch that is on no default branch: the
# preserved copy of a held task.
add_unlanded_slot() {  # <case> <n> <branch>
  local case_dir=$1 n=$2 branch=$3 slot
  slot=$(slot_path "$case_dir" "$n")
  mkdir -p "$(dirname "$slot")"
  git -C "$case_dir/project" worktree add --quiet -b "$branch" "$slot"
  printf 'work nobody has landed\n' > "$slot/held.txt"
  git -C "$slot" add held.txt
  git -C "$slot" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm "held work on $branch"
}

# A slot that is a worktree of a DIFFERENT clone of the same origin: what one
# home's spawn was handed out of another home's copy.
add_foreign_slot() {  # <case> <n>
  local case_dir=$1 n=$2 slot
  slot=$(slot_path "$case_dir" "$n")
  mkdir -p "$(dirname "$slot")"
  git -C "$case_dir/other-clone" worktree add --quiet --detach "$slot" HEAD
}

claim_slot() {  # <case> <n> <task-id> <home>
  local case_dir=$1 n=$2 id=$3 home=$4
  printf 'task=%s\nhome=%s\n' "$id" "$home" \
    > "$case_dir/root/.treehouse/pool/$n/.fm-slot-owner"
}

# What treehouse reports for the pool: "<n>:<status>[:<process>]" per slot.
write_pool_status() {  # <case> <entry>...
  local case_dir=$1 entry n status procs sep='' out='['
  shift
  for entry in "$@"; do
    n=${entry%%:*}
    status=${entry#*:}
    procs='[]'
    case "$status" in
      *:*) procs='[{"pid":4242,"name":"zsh"}]'; status=${status%%:*} ;;
    esac
    out="$out$sep{\"name\":\"$n\",\"path\":\"$(slot_path "$case_dir" "$n")\",\"status\":\"$status\",\"lease_id\":\"\",\"processes\":$procs}"
    sep=','
  done
  printf '%s]\n' "$out" > "$case_dir/pool-status.json"
}

run_pool_spawn() {  # <case> <id> <pane-path> [extra spawn args...]
  local case_dir=$1 id=$2 pane=$3
  shift 3
  FM_FAKE_TREEHOUSE_LOG="$case_dir/treehouse.log" \
  FM_FAKE_PANE_LOG="$case_dir/pane.log" \
  FM_FAKE_POOL_STATUS="$case_dir/pool-status.json" \
    fm_test_run_spawn "$case_dir/home" "$pane" "$(cat "$case_dir/fakebin-path")" \
      "$id" "$case_dir/project" --scout
}

# The pool root the spawn told the pane to allocate from.
sent_pool_root() {  # <case>
  sed -n 's/^treehouse get --root //p' "$1/pane.log" | tail -1
}

# A slot's exact state, so a refusal can be proved to have left it alone.
slot_fingerprint() {  # <case> <n>
  local slot
  slot=$(slot_path "$1" "$2")
  printf '%s|%s|%s\n' \
    "$(git -C "$slot" rev-parse HEAD)" \
    "$(git -C "$slot" rev-parse --abbrev-ref HEAD)" \
    "$(git -C "$slot" status --porcelain | tr '\n' ',')"
}

# --- allocation scope -------------------------------------------------------

test_each_home_allocates_from_its_own_pool_root() {
  local case_dir id=pool-scope-a first second again other_home
  case_dir=$(make_pool_case scope "$id")
  write_pool_status "$case_dir"
  add_landed_slot "$case_dir" 1

  run_pool_spawn "$case_dir" "$id" "$(slot_path "$case_dir" 1)" >/dev/null
  first=$(sent_pool_root "$case_dir")
  [ -n "$first" ] || fail "the spawn did not tell the pane which pool root to allocate from"

  # Same home, fresh task: a home's pool root is stable, so it keeps finding the
  # slots it already allocated.
  fm_test_spawn_brief "$case_dir/home" "$id-again"
  : > "$case_dir/pane.log"
  run_pool_spawn "$case_dir" "$id-again" "$(slot_path "$case_dir" 1)" >/dev/null
  again=$(sent_pool_root "$case_dir")
  assert_equals "$first" "$again" "one home allocated from two different pool roots"

  # A second home on the same machine and the same project must not be able to
  # reach the first home's pool at all.
  other_home="$case_dir/other-home"
  fm_test_spawn_home "$other_home" codex
  fm_test_spawn_brief "$other_home" "$id-other"
  : > "$case_dir/pane.log"
  FM_FAKE_TREEHOUSE_LOG="$case_dir/treehouse.log" \
  FM_FAKE_PANE_LOG="$case_dir/pane.log" \
  FM_FAKE_POOL_STATUS="$case_dir/pool-status.json" \
    fm_test_run_spawn "$other_home" "$(slot_path "$case_dir" 1)" \
      "$(cat "$case_dir/fakebin-path")" "$id-other" "$case_dir/project" --scout >/dev/null
  second=$(sent_pool_root "$case_dir")
  [ -n "$second" ] || fail "the second home's spawn did not name a pool root"
  assert_not_equals "$first" "$second" \
    "two Firstmate homes allocated worker worktrees from the same pool root"
  case "$second" in
    "$first"/*) fail "the second home's pool root sits inside the first home's: $second" ;;
  esac
  case "$first" in
    "$second"/*) fail "the first home's pool root sits inside the second home's: $first" ;;
  esac
  pass "each Firstmate home allocates worker worktrees from its own pool root"
}

# --- screening before allocation --------------------------------------------

assert_refused_leaving_pool_untouched() {  # <case> <id> <slot-n> <before> <out> <rc> <needle>
  local case_dir=$1 id=$2 n=$3 before=$4 out=$5 rc=$6 needle=$7
  [ "$rc" -ne 0 ] || fail "a spawn offered an unusable pool slot succeeded: $out"
  assert_contains "$out" "$(slot_path "$case_dir" "$n")" \
    "the refusal did not name the slot it found: $out"
  assert_contains "$out" "$needle" "the refusal did not say what it found: $out"
  assert_absent "$case_dir/home/state/$id.meta" "a refused spawn published a task record"
  assert_equals "$before" "$(slot_fingerprint "$case_dir" "$n")" \
    "a refused spawn changed the pool slot it refused over"
  assert_not_contains "$(cat "$case_dir/pane.log")" "treehouse get" \
    "a refused spawn still told the pane to allocate a slot"
}

test_a_slot_holding_unlanded_work_refuses_the_spawn() {
  local case_dir id=pool-held-b out rc=0 before
  case_dir=$(make_pool_case held "$id")
  add_landed_slot "$case_dir" 1
  add_unlanded_slot "$case_dir" 2 fm/held-task
  write_pool_status "$case_dir" 1:available 2:available
  before=$(slot_fingerprint "$case_dir" 2)

  out=$(run_pool_spawn "$case_dir" "$id" "$(slot_path "$case_dir" 1)") || rc=$?
  assert_refused_leaving_pool_untouched "$case_dir" "$id" 2 "$before" "$out" "$rc" \
    "fm/held-task"
  pass "a pool slot still holding unlanded commits refuses the spawn by name"
}

test_a_slot_of_another_clone_refuses_the_spawn() {
  local case_dir id=pool-foreign-c out rc=0 before
  case_dir=$(make_pool_case foreign "$id")
  add_landed_slot "$case_dir" 1
  add_foreign_slot "$case_dir" 2
  write_pool_status "$case_dir" 1:available 2:available
  before=$(slot_fingerprint "$case_dir" 2)

  out=$(run_pool_spawn "$case_dir" "$id" "$(slot_path "$case_dir" 1)") || rc=$?
  assert_refused_leaving_pool_untouched "$case_dir" "$id" 2 "$before" "$out" "$rc" \
    "$case_dir/other-clone"
  pass "a pool slot that is a worktree of another home's clone refuses the spawn by name"
}

test_a_slot_still_claimed_by_a_task_refuses_the_spawn() {
  local case_dir id=pool-claimed-d out rc=0 before
  case_dir=$(make_pool_case claimed "$id")
  add_landed_slot "$case_dir" 1
  add_landed_slot "$case_dir" 2
  claim_slot "$case_dir" 2 other-task "$case_dir/home"
  write_pool_status "$case_dir" 1:available 2:available
  before=$(slot_fingerprint "$case_dir" 2)

  out=$(run_pool_spawn "$case_dir" "$id" "$(slot_path "$case_dir" 1)") || rc=$?
  assert_refused_leaving_pool_untouched "$case_dir" "$id" 2 "$before" "$out" "$rc" \
    "other-task"
  pass "a pool slot still claimed by another task refuses the spawn by name"
}

test_a_clean_landed_slot_claimed_by_the_same_task_can_be_reused() {
  local case_dir id=pool-own-clean-e out rc=0
  case_dir=$(make_pool_case own-clean "$id")
  add_landed_slot "$case_dir" 1
  add_landed_slot "$case_dir" 2
  claim_slot "$case_dir" 2 "$id" "$case_dir/home"
  write_pool_status "$case_dir" 1:available 2:available

  out=$(run_pool_spawn "$case_dir" "$id" "$(slot_path "$case_dir" 1)") || rc=$?
  expect_code 0 "$rc" "a same-task reclaim refused its own clean landed slot: $out"
  assert_contains "$out" "spawned $id" "the same-task reclaim did not launch: $out"
  pass "a task can reclaim when its own available slot is clean and landed"
}

test_an_unlanded_slot_claimed_by_the_same_task_still_refuses_reuse() {
  local case_dir id=pool-own-held-f out rc=0 before
  case_dir=$(make_pool_case own-held "$id")
  add_landed_slot "$case_dir" 1
  add_unlanded_slot "$case_dir" 2 fm/own-held
  claim_slot "$case_dir" 2 "$id" "$case_dir/home"
  write_pool_status "$case_dir" 1:available 2:available
  before=$(slot_fingerprint "$case_dir" 2)

  out=$(run_pool_spawn "$case_dir" "$id" "$(slot_path "$case_dir" 1)") || rc=$?
  assert_refused_leaving_pool_untouched "$case_dir" "$id" 2 "$before" "$out" "$rc" \
    "fm/own-held"
  pass "a same-task claim does not make its unlanded slot reusable"
}

test_an_unreadable_pool_refuses_the_spawn() {
  local case_dir id=pool-unreadable-e out rc=0
  case_dir=$(make_pool_case unreadable "$id")
  add_landed_slot "$case_dir" 1
  printf 'not json at all\n' > "$case_dir/pool-status.json"

  out=$(run_pool_spawn "$case_dir" "$id" "$(slot_path "$case_dir" 1)") || rc=$?
  [ "$rc" -ne 0 ] || fail "a spawn allocated from a pool it could not read: $out"
  assert_absent "$case_dir/home/state/$id.meta" "a refused spawn published a task record"
  assert_not_contains "$(cat "$case_dir/pane.log")" "treehouse get" \
    "a spawn told the pane to allocate from a pool it could not read"
  pass "a pool whose slot list cannot be read refuses the spawn instead of being treated as empty"
}

test_a_clean_landed_pool_still_allocates() {
  local case_dir id=pool-clean-f out rc=0
  case_dir=$(make_pool_case clean "$id")
  add_landed_slot "$case_dir" 1
  add_landed_slot "$case_dir" 2
  write_pool_status "$case_dir" 1:available 2:available

  out=$(run_pool_spawn "$case_dir" "$id" "$(slot_path "$case_dir" 1)") || rc=$?
  expect_code 0 "$rc" "a pool whose free slots are all clean and landed refused a spawn: $out"
  assert_contains "$out" "spawned $id" "the screened spawn did not launch: $out"
  assert_contains "$(cat "$case_dir/pane.log")" "treehouse get --root " \
    "the screened spawn did not allocate from its home's pool root"
  pass "a pool whose free slots hold nothing worth keeping still allocates normally"
}

test_a_running_workers_slot_does_not_block_dispatch() {
  local case_dir id=pool-inuse-g out rc=0
  case_dir=$(make_pool_case inuse "$id")
  add_landed_slot "$case_dir" 1
  add_unlanded_slot "$case_dir" 2 fm/live-task
  # Slot 2 holds unlanded work AND is running: treehouse will not hand it out,
  # so screening it would refuse every spawn while a sibling task is alive.
  write_pool_status "$case_dir" 1:available 2:in-use:proc

  out=$(run_pool_spawn "$case_dir" "$id" "$(slot_path "$case_dir" 1)") || rc=$?
  expect_code 0 "$rc" "a live worker's own slot blocked an unrelated spawn: $out"
  assert_contains "$out" "spawned $id" "the spawn beside a live worker did not launch: $out"
  pass "a slot a live worker is running in never blocks another dispatch"
}

# --- the allocation itself --------------------------------------------------

test_a_slot_allocated_from_another_clone_refuses_the_launch() {
  local case_dir id=pool-crossed-h out rc=0 before
  case_dir=$(make_pool_case crossed "$id")
  add_foreign_slot "$case_dir" 2
  # The pool reports nothing, so the screen passes and the allocation itself is
  # what crosses homes - the measured fault, where a spawn's pane landed in a
  # worktree of another home's clone.
  write_pool_status "$case_dir"
  before=$(slot_fingerprint "$case_dir" 2)

  out=$(run_pool_spawn "$case_dir" "$id" "$(slot_path "$case_dir" 2)") || rc=$?
  [ "$rc" -ne 0 ] || fail "a worker launched in another home's clone: $out"
  assert_contains "$out" "$(slot_path "$case_dir" 2)" \
    "the refusal did not name the crossed slot: $out"
  assert_contains "$out" "$case_dir/other-clone" \
    "the refusal did not name the clone the slot belongs to: $out"
  assert_absent "$case_dir/home/state/$id.meta" \
    "a spawn recorded a worktree of another home's clone"
  assert_equals "$before" "$(slot_fingerprint "$case_dir" 2)" \
    "a refused spawn changed the other clone's worktree"
  pass "a slot allocated out of another home's clone refuses the launch instead of being recorded"
}

# --- returning a slot -------------------------------------------------------

make_return_case() {  # <name> <id> <pool|plain> -> echoes case dir
  local name=$1 id=$2 shape=$3 case_dir wt
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/home/state" "$case_dir/home/data/$id" "$case_dir/home/config"
  touch "$case_dir/home/state/.last-watcher-beat"
  printf 'findings\n' > "$case_dir/home/data/$id/report.md"
  : > "$case_dir/treehouse.log"
  make_pool_fakebin "$case_dir/fake" > "$case_dir/fakebin-path"
  cat > "$(cat "$case_dir/fakebin-path")/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  --version) printf '0.2.6\n'; exit 0 ;;
  hold) [ "${2:-}" = --help ] && { printf '%s\n' 'usage: tasks-axi hold <id> --reason <text> --kind captain'; exit 0; } ;;
  update) [ "${2:-}" = --help ] && { printf '%s\n' 'usage: tasks-axi update <id> --body-file <path> --archive-body'; exit 0; } ;;
  mv) [ "${2:-}" = --help ] && { printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'; exit 0; } ;;
esac
exit 0
SH
  chmod +x "$(cat "$case_dir/fakebin-path")/tasks-axi"
  if [ "$shape" = pool ]; then
    mkdir -p "$case_dir/root/.treehouse/pool/1"
    wt="$case_dir/root/.treehouse/pool/1/project"
    fm_git_worktree "$case_dir/project" "$wt" "fm/$id"
    printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$wt" \
      > "$case_dir/root/.treehouse/pool/treehouse-state.json"
  else
    wt="$case_dir/plain-worktree"
    fm_git_worktree "$case_dir/project" "$wt" "fm/$id"
  fi
  fm_write_meta "$case_dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$wt" "project=$case_dir/project" \
    "harness=codex" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "decisions_reviewed=1" "decision_keys="
  printf '%s\n' "$case_dir|$wt"
}

run_teardown() {  # <case> <id>
  local case_dir=$1 id=$2
  FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/home/state" FM_DATA_OVERRIDE="$case_dir/home/data" \
  FM_CONFIG_OVERRIDE="$case_dir/home/config" \
  FM_FAKE_TREEHOUSE_LOG="$case_dir/treehouse.log" \
  PATH="$(cat "$case_dir/fakebin-path"):$PATH" \
    "$TEARDOWN" "$id" 2>&1
}

test_cleanup_returns_a_slot_to_the_pool_root_its_path_names() {
  local rec case_dir wt id=pool-return-i out rc=0 log
  rec=$(make_return_case return-pool "$id" pool)
  case_dir=${rec%%|*}
  wt=${rec#*|}

  out=$(run_teardown "$case_dir" "$id") || rc=$?
  expect_code 0 "$rc" "cleanup of a pooled scout failed: $out"
  log=$(cat "$case_dir/treehouse.log")
  assert_contains "$log" "treehouse return --root $case_dir/root --force $wt" \
    "cleanup did not return the slot to the pool root its own path names: $log"
  pass "a pooled worktree is returned to the pool root its own path names, whatever root allocates today"
}

test_cleanup_of_a_non_pool_worktree_keeps_the_ambient_root() {
  local rec case_dir wt id=plain-return-j out rc=0 log
  rec=$(make_return_case return-plain "$id" plain)
  case_dir=${rec%%|*}
  wt=${rec#*|}

  out=$(run_teardown "$case_dir" "$id") || rc=$?
  expect_code 0 "$rc" "cleanup of a non-pooled scout failed: $out"
  log=$(cat "$case_dir/treehouse.log")
  assert_contains "$log" "treehouse return --force $wt" \
    "cleanup did not return a non-pooled worktree: $log"
  assert_not_contains "$log" "--root" \
    "cleanup invented a pool root for a worktree that is not a pool slot: $log"
  pass "a recorded worktree that is not a pool slot still returns against the ambient root"
}

test_each_home_allocates_from_its_own_pool_root
test_a_slot_holding_unlanded_work_refuses_the_spawn
test_a_slot_of_another_clone_refuses_the_spawn
test_a_slot_still_claimed_by_a_task_refuses_the_spawn
test_a_clean_landed_slot_claimed_by_the_same_task_can_be_reused
test_an_unlanded_slot_claimed_by_the_same_task_still_refuses_reuse
test_an_unreadable_pool_refuses_the_spawn
test_a_clean_landed_pool_still_allocates
test_a_running_workers_slot_does_not_block_dispatch
test_a_slot_allocated_from_another_clone_refuses_the_launch
test_cleanup_returns_a_slot_to_the_pool_root_its_path_names
test_cleanup_of_a_non_pool_worktree_keeps_the_ambient_root
