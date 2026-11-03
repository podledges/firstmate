#!/usr/bin/env bash
# fm-send-queue.sh - inspect and deliberately retire quarantined deferred sends.
#
# The queue contract is owned by bin/fm-send-queue-lib.sh. A .failed record is
# a deferred typed send whose delivery failed or became ambiguous; it is never
# retried and it blocks every later queued send to the same endpoint. This is
# the operator surface for reconciling one such record:
#
#   fm-send-queue.sh list
#       Print "<id>\t<resolved-target>\t<created-epoch>" for each quarantined
#       record.
#   fm-send-queue.sh show <id>
#       Print one quarantined record's target, correlation, resolve keys,
#       recorded fm-send stderr, and exact message so the operator can decide
#       whether it reached the pane.
#   fm-send-queue.sh retire <id>
#       Remove exactly that quarantined record without typing anything. Later
#       queued sends to its endpoint become eligible on the watcher's next tick.
#       If the message did not land and is still wanted, send it again by hand.
#
# Pending and in-flight records are never listed or touched. Exit codes: 0 ok,
# 1 no such quarantined record or retirement failed, 2 usage.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-send-queue-lib.sh
. "$SCRIPT_DIR/fm-send-queue-lib.sh"

usage() {
  echo "usage: fm-send-queue.sh list | show <id> | retire <id>" >&2
  exit 2
}

field() {  # <record-dir> <name>
  local field_value=''
  fm_send_queue_read_var "$1/$2" field_value || field_value='(unreadable)'
  printf '%s' "$field_value"
}

record_or_fail() {  # <id>
  fm_send_queue_failed_record "$STATE" "$1" && return 0
  echo "error: no quarantined deferred send '$1' under $(fm_send_queue_root "$STATE")" >&2
  exit 1
}

CMD=${1:-}
case "$CMD" in
  list)
    [ $# -eq 1 ] || usage
    root=$(fm_send_queue_root "$STATE")
    [ -d "$root" ] && [ ! -L "$root" ] || exit 0
    for rec in "$root"/*.failed; do
      [ -d "$rec" ] && [ ! -L "$rec" ] || continue
      id=${rec##*/}
      printf '%s\t%s\t%s\n' "${id%.failed}" "$(field "$rec" resolved-target)" "$(field "$rec" created-epoch)"
    done
    ;;
  show)
    [ $# -eq 2 ] || usage
    rec=$(record_or_fail "$2")
    printf 'id: %s\n' "$2"
    printf 'target: %s\n' "$(field "$rec" raw-target)"
    printf 'resolved-target: %s\n' "$(field "$rec" resolved-target)"
    printf 'created-epoch: %s\n' "$(field "$rec" created-epoch)"
    printf 'pending-reply-corr: %s\n' "$(field "$rec" corr)"
    printf 'resolve-keys: %s\n' "$(field "$rec" resolve-keys | tr '\n' ' ')"
    if [ -e "$rec/stderr" ]; then
      printf 'fm-send-stderr:\n%s\n' "$(field "$rec" stderr)"
    fi
    printf 'message:\n%s\n' "$(field "$rec" message)"
    ;;
  retire)
    [ $# -eq 2 ] || usage
    rec=$(record_or_fail "$2")
    if ! fm_send_queue_record_retire "$rec"; then
      echo "error: could not retire quarantined deferred send '$2'; it still blocks its endpoint" >&2
      exit 1
    fi
    echo "retired quarantined deferred send $2 without typing; later queued sends to its endpoint are eligible on the next watcher tick"
    ;;
  *) usage ;;
esac
