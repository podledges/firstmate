#!/usr/bin/env bash
# fm-send focused/pending composer deferral, durable replay, and exactly-once typing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-send-queue-lib.sh
. "$ROOT/bin/fm-send-queue-lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-defer)
mkdir -p "$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT

make_tmux_stub() {  # <dir>
  local dir=$1 fb
  fb="$dir/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$payload" >> "$D/literal"
      printf 'pending' > "$D/composer"
    else
      printf '%s\n' "$payload" >> "$D/keys"
      [ "$payload" != Enter ] || printf 'empty' > "$D/composer"
    fi
    ;;
  display-message)
    for arg in "$@"; do
      case "$arg" in
        *session_attached*)
          [ ! -x "$D/on-guard" ] || "$D/on-guard"
          cat "$D/focus"; printf '\n'; exit 0 ;;
        *session_name*pane_id*) printf 'sess\t@1\t%%1\n'; exit 0 ;;
        *cursor_y*) printf '1\n'; exit 0 ;;
      esac
    done
    printf '%%1\n'
    ;;
  list-clients)
    [ "$(cat "$D/focus")" = "$(printf '1\t1\t1')" ] && printf 'sess\t@1\t%%1\n'
    ;;
  capture-pane)
    case "$(cat "$D/composer")" in
      empty) printf '╭──────────────╮\n│              │\n╰──────────────╯\n' ;;
      pending) printf '╭──────────────╮\n│ captain draft │\n╰──────────────╯\n' ;;
      *) printf 'plain shell output\n' ;;
    esac
    ;;
  list-windows) printf 'sess:fm-t1\n' ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

new_case() {  # <name>
  local dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf '0\t0\t0' > "$dir/fake/focus"
  printf 'empty' > "$dir/fake/composer"
  make_tmux_stub "$dir"
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude"
  printf '%s\n' "$dir"
}

run_send() {  # <case-dir> <args...>
  local dir=$1; shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_DIR="$dir/fake" FM_SEND_SETTLE=0 "$SEND" "$@" 2>"$dir/send.err"
}

run_tick() {  # <case-dir>
  local dir=$1
  PATH="$dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_FAKE_DIR="$dir/fake" \
    FM_SEND_SETTLE=0 fm_send_queue_tick "$dir/home" "$dir/home/state" "$ROOT/bin/fm-send.sh"
}

queue_count() {  # <case-dir> <suffix>
  find "$1/home/state/send-queue" -maxdepth 1 -type d -name "*.$2" 2>/dev/null | wc -l | tr -d ' '
}

literal_count() { wc -l < "$1/fake/literal" | tr -d ' '; }

set_focus() { printf '%s' "$2" > "$1/fake/focus"; }
set_composer() { printf '%s' "$2" > "$1/fake/composer"; }

test_focused_send_defers_then_delivers_once() {
  local dir out rc
  dir=$(new_case focused)
  set_focus "$dir" $'1\t1\t1'
  out=$(run_send "$dir" t1 '/FIRSTMATE STEER'); rc=$?
  expect_code 4 "$rc" "focused send should return the distinct deferred status"
  assert_contains "$(cat "$dir/send.err")" "safety=focused" "focused deferral should name its cause"
  [ "$(literal_count "$dir")" = 0 ] || fail "focused send typed into the pane"
  [ "$(queue_count "$dir" pending)" = 1 ] || fail "focused send was not durably queued once"

  run_tick "$dir" >/dev/null
  [ "$(literal_count "$dir")" = 0 ] || fail "queue tick typed while the pane remained focused"
  [ "$(queue_count "$dir" pending)" = 1 ] || fail "focused queue record did not remain pending"

  set_focus "$dir" $'0\t0\t0'
  run_tick "$dir" >/dev/null
  [ "$(literal_count "$dir")" = 1 ] || fail "safe queue tick did not type exactly once"
  [ "$(cat "$dir/fake/literal")" = '/FIRSTMATE STEER' ] || fail "deferred message bytes changed"
  [ "$(queue_count "$dir" pending)" = 0 ] || fail "delivered queue record was not retired"

  run_tick "$dir" >/dev/null
  [ "$(literal_count "$dir")" = 1 ] || fail "retired deferred message was typed twice"
  pass "fm-send defer: a focused pane is untouched, then receives the durable message exactly once when safe"
}

test_per_target_fifo_is_preserved() {
  local dir rc
  dir=$(new_case fifo)
  set_focus "$dir" $'1\t1\t1'
  run_send "$dir" t1 '/first deferred message' >/dev/null; rc=$?
  expect_code 4 "$rc" "first focused message should defer"
  run_send "$dir" t1 '/second deferred message' >/dev/null; rc=$?
  expect_code 4 "$rc" "second focused message should join the queue"
  [ "$(queue_count "$dir" pending)" = 2 ] || fail "same-target deferred messages were not both retained"

  set_focus "$dir" $'0\t0\t0'
  run_tick "$dir" >/dev/null
  [ "$(literal_count "$dir")" = 2 ] || fail "safe queue tick did not deliver both FIFO messages"
  [ "$(cat "$dir/fake/literal")" = $'/first deferred message\n/second deferred message' ] \
    || fail "same-target deferred messages overtook each other"
  pass "fm-send defer: same-target messages retain FIFO order through replay"
}

test_pending_and_unknown_composers_defer_without_touching_draft() {
  local dir rc
  for verdict in pending unknown; do
    dir=$(new_case "composer-$verdict")
    set_composer "$dir" "$verdict"
    run_send "$dir" t1 "/message-$verdict" >/dev/null; rc=$?
    expect_code 4 "$rc" "$verdict composer should defer"
    assert_contains "$(cat "$dir/send.err")" "composer-$verdict" "$verdict composer deferral should name its verdict"
    [ "$(literal_count "$dir")" = 0 ] || fail "$verdict composer was modified"
    [ "$(cat "$dir/fake/composer")" = "$verdict" ] || fail "$verdict composer state changed"
    set_composer "$dir" empty
    run_tick "$dir" >/dev/null
    [ "$(literal_count "$dir")" = 1 ] || fail "$verdict composer record did not deliver after empty"
  done
  pass "fm-send defer: pending and unknown composers remain untouched until affirmatively empty"
}

test_deferred_resolve_key_closes_only_after_delivery() {
  local dir rc status
  dir=$(new_case resolve)
  status="$dir/home/state/t1.status"
  printf 'needs-decision [key=choice]: pick one\n' > "$status"
  set_focus "$dir" $'1\t1\t1'
  run_send "$dir" t1 --resolve-key choice '/choose-a' >/dev/null; rc=$?
  expect_code 4 "$rc" "focused decision answer should defer"
  assert_not_contains "$(cat "$status")" "resolved [key=choice]:" "deferred answer closed its decision before delivery"
  set_focus "$dir" $'0\t0\t0'
  run_tick "$dir" >/dev/null
  assert_contains "$(cat "$status")" "resolved [key=choice]" "delivered deferred answer did not close its key"
  assert_contains "$(cat "$status")" "answered: /choose-a" "delivered deferred answer lost its answer text"
  [ "$(literal_count "$dir")" = 1 ] || fail "deferred decision answer was not typed exactly once"
  pass "fm-send defer: --resolve-key stays open while queued and closes at actual delivery"
}

test_deferred_secondmate_keeps_one_correlation() {
  local dir rc rec corr queued_corr delivered
  dir=$(new_case secondmate)
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-t1" "kind=secondmate" "harness=claude"
  set_focus "$dir" $'1\t1\t1'
  run_send "$dir" t1 '/report-home' >/dev/null; rc=$?
  expect_code 4 "$rc" "focused secondmate request should defer"
  rec=$(find "$dir/home/state/pending-replies" -maxdepth 1 -type f ! -name '.*' | head -1)
  [ -n "$rec" ] || fail "deferred secondmate request lost its pending-reply record"
  corr=$(sed -n 's/^corr_id=//p' "$rec")
  queued_corr=$(cat "$dir/home/state/send-queue"/*.pending/corr)
  [ "$queued_corr" = "$corr" ] || fail "deferred queue lost the pending-reply correlation"
  [ ! -e "$dir/home/state/pending-replies/.delivery-confirmed-$corr" ] \
    || fail "deferred request was marked attempted before any terminal input"

  set_focus "$dir" $'0\t0\t0'
  run_tick "$dir" >/dev/null
  delivered=$(sed -n 's/^delivered_epoch=//p' "$rec")
  [ -n "$delivered" ] || fail "actual deferred delivery did not mark the pending reply delivered"
  [ "$(literal_count "$dir")" = 1 ] || fail "marked deferred request was typed more than once"
  case "$(cat "$dir/fake/literal")" in
    *"corr=$corr /report-home") ;;
    *) fail "delivered secondmate request did not retain its original correlation" ;;
  esac
  pass "fm-send defer: a marked secondmate request keeps one correlation through actual delivery"
}

test_replay_quarantines_changed_endpoint_without_typing() {
  local dir rc
  dir=$(new_case endpoint-change)
  set_focus "$dir" $'1\t1\t1'
  run_send "$dir" t1 '/bound to original endpoint' >/dev/null; rc=$?
  expect_code 4 "$rc" "focused message should queue before endpoint-change test"
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-other" "kind=ship" "harness=claude"
  set_focus "$dir" $'0\t0\t0'
  run_tick "$dir" >/dev/null
  [ "$(literal_count "$dir")" = 0 ] || fail "deferred message followed changed metadata into another endpoint"
  [ "$(queue_count "$dir" failed)" = 1 ] || fail "changed-endpoint record was not quarantined"
  pass "fm-send defer: replay refuses a changed resolved endpoint instead of typing into a replacement context"
}

test_special_keys_refuse_and_never_queue() {
  local dir rc
  dir=$(new_case key)
  set_focus "$dir" $'1\t1\t1'
  run_send "$dir" t1 --key Escape >/dev/null; rc=$?
  expect_code 4 "$rc" "focused special key should return the distinct refusal status"
  [ ! -s "$dir/fake/keys" ] || fail "focused special key reached the pane"
  [ "$(queue_count "$dir" pending)" = 0 ] || fail "time-sensitive special key was queued"
  pass "fm-send defer: special keys refuse focused panes and are never replayed later"
}

test_interrupted_delivery_is_quarantined_without_retyping() {
  local dir rc pending sending first second third
  dir=$(new_case interrupted)
  set_focus "$dir" $'1\t1\t1'
  run_send "$dir" t1 '/possibly typed before crash' >/dev/null; rc=$?
  expect_code 4 "$rc" "focused message should queue before interrupted-delivery test"
  pending=$(find "$dir/home/state/send-queue" -maxdepth 1 -type d -name '*.pending' -print -quit)
  sending=${pending%.pending}.sending
  mv "$pending" "$sending"

  first=$(run_tick "$dir")
  [ "$(queue_count "$dir" failed)" = 1 ] || fail "orphaned delivery claim was not quarantined"
  [ "$(literal_count "$dir")" = 0 ] || fail "orphaned delivery claim was automatically retyped"
  assert_contains "$first" "delivery process ended before the durable result was recorded" \
    "orphaned claim did not report its delivery ambiguity"
  second=$(run_tick "$dir")
  assert_contains "$second" "prior delivery attempt failed" \
    "unacknowledged deferred-send failure did not remain reportable"
  fm_send_queue_ack_failed_reports "$dir/home/state" || fail "could not acknowledge durable deferred-send report"
  third=$(run_tick "$dir")
  [ -z "$third" ] || fail "acknowledged deferred-send failure reported again: $third"
  [ "$(literal_count "$dir")" = 0 ] || fail "acknowledgement retyped an ambiguous message"
  pass "fm-send defer: a crash claim quarantines without retyping and reports until durably acknowledged"
}

test_lease_refusal_returns_claim_to_pending_without_typing() {
  local dir rc stub
  dir=$(new_case lease-refusal)
  set_focus "$dir" $'1\t1\t1'
  run_send "$dir" t1 '/waits out a lease' >/dev/null; rc=$?
  expect_code 4 "$rc" "focused message should queue before lease-refusal test"
  set_focus "$dir" $'0\t0\t0'
  stub="$dir/lease-refusing-send"
  printf '#!/usr/bin/env bash\necho "error: steer (fm-send) refused - task is leased" >&2\nexit 6\n' > "$stub"
  chmod +x "$stub"
  out=$(PATH="$dir/fakebin:$PATH" fm_send_queue_tick "$dir/home" "$dir/home/state" "$stub")
  [ -z "$out" ] || fail "lease refusal was reported as a failed delivery: $out"
  [ "$(queue_count "$dir" pending)" = 1 ] || fail "lease-refused claim did not return to pending"
  [ "$(queue_count "$dir" failed)" = 0 ] || fail "lease-refused claim was quarantined"
  run_tick "$dir" >/dev/null
  [ "$(literal_count "$dir")" = 1 ] || fail "message did not deliver exactly once after the lease cleared"
  [ "$(queue_count "$dir" pending)" = 0 ] || fail "delivered record stayed pending"
  pass "fm-send defer: a no-input lease refusal keeps the record pending and delivers once after release"
}

test_quarantined_record_blocks_until_operator_retires_it() {
  local dir rc id out
  dir=$(new_case retire)
  set_focus "$dir" $'1\t1\t1'
  run_send "$dir" t1 '/bound to original endpoint' >/dev/null; rc=$?
  expect_code 4 "$rc" "focused message should queue before retire test"
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-other" "kind=ship" "harness=claude"
  set_focus "$dir" $'0\t0\t0'
  out=$(run_tick "$dir")
  id=$(find "$dir/home/state/send-queue" -maxdepth 1 -type d -name '*.failed' -print -quit)
  id=${id##*/}; id=${id%.failed}
  [ -n "$id" ] || fail "changed-endpoint record was not quarantined"
  assert_contains "$out" "bin/fm-send-queue.sh retire $id" "quarantine report did not name the retire path"
  fm_send_queue_ack_failed_reports "$dir/home/state" || fail "could not acknowledge quarantine report"

  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude"
  run_send "$dir" t1 '/later message' >/dev/null; rc=$?
  expect_code 4 "$rc" "send behind a quarantined record should defer"
  assert_contains "$(cat "$dir/send.err")" "held behind quarantined deferred send $id" \
    "send behind a quarantined record promised eventual delivery"
  run_tick "$dir" >/dev/null
  [ "$(literal_count "$dir")" = 0 ] || fail "later send overtook the quarantined record"

  out=$(FM_HOME="$dir/home" "$ROOT/bin/fm-send-queue.sh" list)
  assert_contains "$out" "$id" "list did not show the quarantined record"
  out=$(FM_HOME="$dir/home" "$ROOT/bin/fm-send-queue.sh" show "$id")
  assert_contains "$out" "/bound to original endpoint" "show did not print the quarantined message"
  FM_HOME="$dir/home" "$ROOT/bin/fm-send-queue.sh" retire nope >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "retiring an unknown record should fail"
  FM_HOME="$dir/home" "$ROOT/bin/fm-send-queue.sh" retire "$id" >/dev/null || fail "retire failed"
  [ "$(queue_count "$dir" failed)" = 0 ] || fail "retired record is still quarantined"
  [ "$(literal_count "$dir")" = 0 ] || fail "retire typed something"

  run_tick "$dir" >/dev/null
  [ "$(cat "$dir/fake/literal")" = "/later message" ] \
    || fail "after retirement only the later message should deliver: $(cat "$dir/fake/literal")"
  pass "fm-send defer: a quarantined record blocks later sends until an operator retires exactly it, and is never retyped"
}

test_unconfirmed_replay_is_quarantined_and_reported_once() {
  local dir rc stub calls out id
  dir=$(new_case unconfirmed)
  set_focus "$dir" $'1\t1\t1'
  run_send "$dir" t1 '/maybe unsubmitted' >/dev/null; rc=$?
  expect_code 4 "$rc" "focused message should queue before unconfirmed-replay test"
  run_send "$dir" t1 '/queued behind it' >/dev/null; rc=$?
  expect_code 4 "$rc" "second message should queue behind the first"
  set_focus "$dir" $'0\t0\t0'
  calls="$dir/stub-calls"
  stub="$dir/unconfirmed-send"
  printf '#!/usr/bin/env bash\necho x >> "%s"\necho "warning: submit to %%1 unconfirmed; check the pane" >&2\nexit 3\n' "$calls" > "$stub"
  chmod +x "$stub"
  out=$(PATH="$dir/fakebin:$PATH" fm_send_queue_tick "$dir/home" "$dir/home/state" "$stub")
  [ "$(wc -l < "$calls" | tr -d ' ')" = 1 ] || fail "unconfirmed replay was not attempted exactly once"
  [ "$(queue_count "$dir" failed)" = 1 ] || fail "unconfirmed replay was retired instead of quarantined"
  [ "$(queue_count "$dir" pending)" = 1 ] || fail "later record did not stay pending behind the ambiguous one"
  assert_contains "$out" "submit was not confirmed" "unconfirmed replay was not reported as delivery-ambiguous"
  assert_contains "$out" "submit to %1 unconfirmed" "unconfirmed replay report dropped fm-send diagnostics"
  id=$(find "$dir/home/state/send-queue" -maxdepth 1 -type d -name '*.failed' -print -quit)
  id=${id##*/}; id=${id%.failed}
  assert_contains "$(FM_HOME="$dir/home" "$ROOT/bin/fm-send-queue.sh" show "$id")" "submit to %1 unconfirmed" \
    "quarantined unconfirmed replay did not retain its diagnostics"
  fm_send_queue_ack_failed_reports "$dir/home/state" || fail "could not acknowledge unconfirmed-replay report"
  out=$(PATH="$dir/fakebin:$PATH" fm_send_queue_tick "$dir/home" "$dir/home/state" "$stub")
  [ -z "$out" ] || fail "acknowledged unconfirmed replay reported again: $out"
  [ "$(wc -l < "$calls" | tr -d ' ')" = 1 ] || fail "ambiguous replay was retried or overtaken"
  pass "fm-send defer: an unconfirmed replay is quarantined, reported once with diagnostics, and never retried"
}

test_malformed_failed_record_keeps_blocking_its_target() {
  local dir rc first
  dir=$(new_case malformed-failed)
  set_focus "$dir" $'1\t1\t1'
  run_send "$dir" t1 '/first' >/dev/null; rc=$?
  expect_code 4 "$rc" "first message should queue"
  run_send "$dir" t1 '/second' >/dev/null; rc=$?
  expect_code 4 "$rc" "second message should queue"
  first=$(find "$dir/home/state/send-queue" -maxdepth 1 -type d -name '*.pending' | sort | head -1)
  rm -f "$first/corr"
  set_focus "$dir" $'0\t0\t0'
  run_tick "$dir" >/dev/null
  [ "$(queue_count "$dir" failed)" = 1 ] || fail "malformed record was not quarantined"
  fm_send_queue_ack_failed_reports "$dir/home/state" || fail "could not acknowledge malformed-record report"
  run_tick "$dir" >/dev/null
  run_tick "$dir" >/dev/null
  [ "$(literal_count "$dir")" = 0 ] || fail "later record overtook a malformed quarantined record"
  [ "$(queue_count "$dir" pending)" = 1 ] || fail "later record left pending state while blocked"
  pass "fm-send defer: a malformed quarantined record keeps blocking its endpoint on every tick"
}

test_deferral_resets_attempt_aged_by_reconciliation() {
  local dir rc rec corr
  dir=$(new_case aged-attempt)
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-t1" "kind=secondmate" "harness=claude"
  set_focus "$dir" $'1\t1\t1'
  # shellcheck disable=SC2016 # the single-quoted script expands in the generated hook
  printf '#!/usr/bin/env bash\nfor r in "%s"/*; do [ -f "$r" ] && sed -i.bak "s/^phase=.*/phase=delivery_unknown/" "$r" && rm -f "$r.bak"; done\n' \
    "$dir/home/state/pending-replies" > "$dir/fake/on-guard"
  chmod +x "$dir/fake/on-guard"
  run_send "$dir" t1 '/report-home' >/dev/null; rc=$?
  expect_code 4 "$rc" "focused secondmate request should defer"
  rm -f "$dir/fake/on-guard"
  rec=$(find "$dir/home/state/pending-replies" -maxdepth 1 -type f ! -name '.*' | head -1)
  corr=$(sed -n 's/^corr_id=//p' "$rec")
  [ "$(sed -n 's/^phase=//p' "$rec")" = awaiting_report ] \
    || fail "deferral left a reconciliation-aged phase instead of resetting it: $(sed -n 's/^phase=//p' "$rec")"
  [ ! -e "$dir/home/state/pending-replies/.delivery-confirmed-$corr" ] \
    || fail "deferral left the attempted-delivery marker behind"
  set_focus "$dir" $'0\t0\t0'
  run_tick "$dir" >/dev/null
  [ -n "$(sed -n 's/^delivered_epoch=//p' "$rec")" ] || fail "replay after the reset did not confirm delivery"
  [ "$(literal_count "$dir")" = 1 ] || fail "reset deferred request was not typed exactly once"
  pass "fm-send defer: a no-input deferral resets an attempt that reconciliation aged to delivery_unknown"
}

test_focused_send_defers_then_delivers_once
test_per_target_fifo_is_preserved
test_pending_and_unknown_composers_defer_without_touching_draft
test_deferred_resolve_key_closes_only_after_delivery
test_deferred_secondmate_keeps_one_correlation
test_replay_quarantines_changed_endpoint_without_typing
test_special_keys_refuse_and_never_queue
test_interrupted_delivery_is_quarantined_without_retyping
test_lease_refusal_returns_claim_to_pending_without_typing
test_quarantined_record_blocks_until_operator_retires_it
test_unconfirmed_replay_is_quarantined_and_reported_once
test_malformed_failed_record_keeps_blocking_its_target
test_deferral_resets_attempt_aged_by_reconciliation

echo "all fm-send defer tests passed"
