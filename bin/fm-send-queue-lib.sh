#!/usr/bin/env bash
# fm-send-queue-lib.sh - durable deferred fm-send typed-plane queue.
#
# Queue records live under state/send-queue/ as mode-0700 directories named
# <creation-epoch>-<pid>-<random>.pending. Each field is a separate regular
# mode-0600 file, so message bytes can contain tabs and newlines without a
# second parser or an executable record format. Publication is atomic: enqueue
# writes a sibling .tmp directory completely and renames it to .pending.
#
# The existing singleton watcher drives fm_send_queue_tick once per ordinary
# poll. A record is atomically renamed .pending -> .sending before fm-send is
# invoked. Exit 4 means the pane still fails its focus/composer guard, and the
# supervision-lease refusal exit 6 means the other actor holds the task lease;
# both are raised before any terminal input and move the record back to
# .pending; exit 0 retires it; every other result, including the
# delivered-but-unconfirmed exit 3 whose text may still sit unsubmitted in the
# composer, moves it to .failed with fm-send's stderr retained and renders one
# report until the watcher durably queues its notification and acknowledges the
# record, so supervision can reconcile without retyping. A .sending record left
# by process death is delivery-ambiguous and is likewise quarantined as .failed
# rather than automatically retried. Pending, claimed,
# and failed records gate later messages for the same endpoint, preserving FIFO
# and preventing unresolved delivery from being overtaken. Nothing retries or
# clears a .failed record automatically: an operator inspects one with
# `bin/fm-send-queue.sh show <id>` and, after deciding whether it landed,
# deliberately retires exactly that record with `bin/fm-send-queue.sh retire
# <id>`, which unblocks the endpoint's later queued records. This bias preserves
# the exactly-once typing boundary when a process dies after terminal input but
# before queue retirement.
#
# fm-send itself remains the delivery owner. The queue replays the original
# selector, plain message, resolve keys, and pending-reply correlation through
# that executable, so deferred typed delivery has the same marking, decision
# closure, plane classification, and submit-verification semantics as an
# immediate send. Ordinary task text already rides the durable steering inbox
# and never enters this queue; only parser-native or explicit-target text whose
# payload must reach the terminal is queued here.

FM_SEND_DEFERRED_EXIT=${FM_SEND_DEFERRED_EXIT:-4}
FM_SEND_LEASE_REFUSE_EXIT=${FM_LEASE_REFUSE_EXIT:-6}

fm_send_queue_root() {  # <state-dir>
  printf '%s/send-queue' "$1"
}

fm_send_queue_safe_atom() {  # <value>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

fm_send_queue_read_var() {  # <file> <output-var>
  local file=$1 out=$2 value
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  value=$(cat "$file"; printf x) || return 1
  value=${value%x}
  printf -v "$out" '%s' "$value"
}

fm_send_queue_write_field() {  # <record-dir> <name> <value>
  local dir=$1 name=$2 value=$3
  fm_send_queue_safe_atom "$name" || return 1
  printf '%s' "$value" > "$dir/$name" || return 1
  chmod 0600 "$dir/$name" 2>/dev/null || true
}

fm_send_queue_record_valid() {  # <record-dir>
  local rec=$1 name
  [ -d "$rec" ] && [ ! -L "$rec" ] || return 1
  for name in schema raw-target resolved-target message resolve-keys corr created-epoch; do
    [ -f "$rec/$name" ] && [ ! -L "$rec/$name" ] || return 1
  done
  [ "$(cat "$rec/schema" 2>/dev/null)" = fm-send-queue.v1 ] || return 1
  return 0
}

fm_send_queue_record_remove() {  # <record-dir>
  fm_send_queue_record_valid "$1" || return 1
  fm_send_queue_record_retire "$1"
}

fm_send_queue_record_retire() {  # <record-dir>
  local rec=$1 retired file
  [ -d "$rec" ] && [ ! -L "$rec" ] || return 1
  retired=${rec%.*}.retired
  [ ! -e "$retired" ] && [ ! -L "$retired" ] || return 1
  for file in "$rec"/*; do
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
  done
  # Retirement itself is the atomic rename. Cleanup after that point is best
  # effort: a crash or filesystem error may leave inert .retired evidence, but
  # no future queue scan can mistake the delivered record for pending work.
  mv -- "$rec" "$retired" || return 1
  rm -f -- "$retired"/* 2>/dev/null || return 0
  rmdir -- "$retired" 2>/dev/null || true
  return 0
}

fm_send_queue_new_id() {
  local random stamp
  random=$(dd if=/dev/urandom bs=8 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n') || return 1
  [ "${#random}" -eq 16 ] || return 1
  stamp=$(perl -MTime::HiRes=time -e '$t=time; printf "%020d-%06d", int($t), int(($t-int($t))*1000000)' 2>/dev/null) \
    || return 1
  printf '%s-%010d-%s' "$stamp" "${BASHPID:-$$}" "$random"
}

fm_send_queue_target_list_has() {  # <newline-list> <target>
  local list=$1 target=$2 item
  while IFS= read -r item || [ -n "$item" ]; do
    [ "$item" = "$target" ] && return 0
  done <<EOF_TARGETS
$list
EOF_TARGETS
  return 1
}

fm_send_queue_enqueue() {  # <state> <raw-target> <resolved-target> <message> <space-separated-resolve-keys> <corr>
  local state=$1 raw=$2 resolved=$3 message=$4 keys=$5 corr=$6 root id tmp pending key
  root=$(fm_send_queue_root "$state")
  if [ -e "$root" ] || [ -L "$root" ]; then
    [ -d "$root" ] && [ ! -L "$root" ] || return 1
  else
    mkdir -m 0700 "$root" || return 1
  fi
  chmod 0700 "$root" 2>/dev/null || true
  id=$(fm_send_queue_new_id) || return 1
  tmp="$root/$id.tmp"
  pending="$root/$id.pending"
  mkdir -m 0700 "$tmp" || return 1
  if ! fm_send_queue_write_field "$tmp" schema fm-send-queue.v1 \
    || ! fm_send_queue_write_field "$tmp" raw-target "$raw" \
    || ! fm_send_queue_write_field "$tmp" resolved-target "$resolved" \
    || ! fm_send_queue_write_field "$tmp" message "$message" \
    || ! fm_send_queue_write_field "$tmp" corr "$corr" \
    || ! fm_send_queue_write_field "$tmp" created-epoch "$(date +%s)"; then
    rm -f -- "$tmp"/* 2>/dev/null || true
    rmdir -- "$tmp" 2>/dev/null || true
    return 1
  fi
  : > "$tmp/resolve-keys" || return 1
  chmod 0600 "$tmp/resolve-keys" 2>/dev/null || true
  for key in $keys; do
    fm_send_queue_safe_atom "$key" || return 1
    printf '%s\n' "$key" >> "$tmp/resolve-keys" || return 1
  done
  mv -- "$tmp" "$pending" || return 1
  printf '%s' "$id"
}

fm_send_queue_has_target() {  # <state> <resolved-target>
  local state=$1 target=$2 root rec queued
  root=$(fm_send_queue_root "$state")
  [ -d "$root" ] && [ ! -L "$root" ] || return 1
  for rec in "$root"/*.pending "$root"/*.sending "$root"/*.failed; do
    [ -d "$rec" ] && [ ! -L "$rec" ] || continue
    fm_send_queue_read_var "$rec/resolved-target" queued || continue
    [ "$queued" = "$target" ] && return 0
  done
  return 1
}

fm_send_queue_failed_for_target() {  # <state> <resolved-target>
  local state=$1 target=$2 root rec queued id
  root=$(fm_send_queue_root "$state")
  [ -d "$root" ] && [ ! -L "$root" ] || return 1
  for rec in "$root"/*.failed; do
    [ -d "$rec" ] && [ ! -L "$rec" ] || continue
    fm_send_queue_read_var "$rec/resolved-target" queued || continue
    [ "$queued" = "$target" ] || continue
    id=${rec##*/}
    printf '%s' "${id%.failed}"
    return 0
  done
  return 1
}

fm_send_queue_failed_record() {  # <state> <id>
  local rec
  fm_send_queue_safe_atom "$2" || return 1
  rec="$(fm_send_queue_root "$1")/$2.failed"
  [ -d "$rec" ] && [ ! -L "$rec" ] || return 1
  printf '%s' "$rec"
}

fm_send_queue_mark_reported() {  # <failed-record>
  local rec=$1
  [ -d "$rec" ] && [ ! -L "$rec" ] || return 1
  [ ! -e "$rec/reported" ] && [ ! -L "$rec/reported" ] || return 1
  : > "$rec/reported" || return 1
  chmod 0600 "$rec/reported" 2>/dev/null || true
}

fm_send_queue_report_failed_once() {  # <failed-record> <reason>
  local rec=$1 reason=$2 id
  [ ! -e "$rec/reported" ] && [ ! -L "$rec/reported" ] || return 0
  id=${rec##*/}
  id=${id%.failed}
  printf 'deferred send %s requires reconciliation: %s; later typed sends to its endpoint stay blocked until an operator inspects it with bin/fm-send-queue.sh show %s and deliberately retires it with bin/fm-send-queue.sh retire %s\n' \
    "$id" "$reason" "$id" "$id"
}

# A report is acknowledged only after its wake is durable. Until then each tick
# renders it again, preferring a duplicate notification over a silently lost
# ambiguous delivery.
fm_send_queue_ack_failed_reports() {  # <state>
  local root rec status=0
  root=$(fm_send_queue_root "$1")
  [ -d "$root" ] && [ ! -L "$root" ] || return 0
  for rec in "$root"/*.failed; do
    [ -d "$rec" ] && [ ! -L "$rec" ] || continue
    [ -e "$rec/reported" ] || [ -L "$rec/reported" ] || fm_send_queue_mark_reported "$rec" || status=1
  done
  return "$status"
}

fm_send_queue_tick() {  # <home> <state> <fm-send-executable>
  local home=$1 state=$2 send=$3 root rec pending failed raw target message keys corr key rc err
  local blocked_targets='' reported_records=''
  local -a args
  root=$(fm_send_queue_root "$state")
  [ -d "$root" ] && [ ! -L "$root" ] || return 0

  # A previous process may have died after typing but before retiring its claim.
  # Never retry that ambiguity automatically.
  for rec in "$root"/*.sending; do
    [ -d "$rec" ] && [ ! -L "$rec" ] || continue
    failed=${rec%.sending}.failed
    if mv -- "$rec" "$failed"; then
      fm_send_queue_report_failed_once "$failed" "delivery process ended before the durable result was recorded; the message was not retyped"
      reported_records="${reported_records}${failed}"$'\n'
    fi
  done

  for rec in "$root"/*.failed; do
    [ -d "$rec" ] && [ ! -L "$rec" ] || continue
    fm_send_queue_target_list_has "$reported_records" "$rec" \
      || fm_send_queue_report_failed_once "$rec" "a prior delivery attempt failed and was not retyped"
    if fm_send_queue_read_var "$rec/resolved-target" target; then
      blocked_targets="${blocked_targets}${target}"$'\n'
    fi
  done

  for pending in "$root"/*.pending; do
    [ -d "$pending" ] && [ ! -L "$pending" ] || continue
    fm_send_queue_record_valid "$pending" || {
      if fm_send_queue_read_var "$pending/resolved-target" target; then
        blocked_targets="${blocked_targets}${target}"$'\n'
      fi
      failed=${pending%.pending}.failed
      mv -- "$pending" "$failed" 2>/dev/null || true
      fm_send_queue_report_failed_once "$failed" "the durable queue record is malformed"
      continue
    }
    if ! fm_send_queue_read_var "$pending/resolved-target" target; then
      failed=${pending%.pending}.failed
      mv -- "$pending" "$failed" 2>/dev/null || true
      fm_send_queue_report_failed_once "$failed" "the durable queue target became unreadable"
      continue
    fi
    fm_send_queue_target_list_has "$blocked_targets" "$target" && continue
    rec=${pending%.pending}.sending
    mv -- "$pending" "$rec" || continue
    if ! fm_send_queue_read_var "$rec/raw-target" raw \
      || ! fm_send_queue_read_var "$rec/resolved-target" target \
      || ! fm_send_queue_read_var "$rec/message" message \
      || ! fm_send_queue_read_var "$rec/resolve-keys" keys \
      || ! fm_send_queue_read_var "$rec/corr" corr; then
      failed=${rec%.sending}.failed
      mv -- "$rec" "$failed" 2>/dev/null || true
      fm_send_queue_report_failed_once "$failed" "the claimed queue record became unreadable"
      continue
    fi
    args=("$raw")
    while IFS= read -r key || [ -n "$key" ]; do
      [ -n "$key" ] || continue
      args+=(--resolve-key "$key")
    done <<EOF_KEYS
$keys
EOF_KEYS
    args+=("$message")
    err="$rec/stderr"
    : > "$err"
    chmod 0600 "$err" 2>/dev/null || true
    rc=0
    FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_SEND_DEFERRED_RECORD="$rec" \
      FM_PENDING_REPLY_EXISTING_CORR="$corr" FM_SEND_DEFERRED_TARGET="$target" \
      "$send" "${args[@]}" >/dev/null 2>"$err" || rc=$?
    case "$rc" in
      0)
        fm_send_queue_record_remove "$rec" || {
          failed=${rec%.sending}.failed
          mv -- "$rec" "$failed" 2>/dev/null || true
          fm_send_queue_report_failed_once "$failed" "delivery completed but queue retirement failed; do not resend"
          blocked_targets="${blocked_targets}${target}"$'\n'
        }
        ;;
      "$FM_SEND_DEFERRED_EXIT"|"$FM_SEND_LEASE_REFUSE_EXIT")
        rm -f -- "$err"
        if ! mv -- "$rec" "$pending"; then
          failed=${rec%.sending}.failed
          mv -- "$rec" "$failed" 2>/dev/null || true
          fm_send_queue_report_failed_once "$failed" "delivery was refused before input and the queue claim could not be restored"
        fi
        blocked_targets="${blocked_targets}${target}"$'\n'
        ;;
      3)
        failed=${rec%.sending}.failed
        mv -- "$rec" "$failed" 2>/dev/null || true
        fm_send_queue_report_failed_once "$failed" "delivery is ambiguous because the text was typed and submitted but the submit was not confirmed, so it may still sit unsubmitted in the composer; verify the pane and do not resend: $(tr '\n\r\t' '   ' < "$failed/stderr" 2>/dev/null | head -c 300)"
        blocked_targets="${blocked_targets}${target}"$'\n'
        ;;
      *)
        failed=${rec%.sending}.failed
        mv -- "$rec" "$failed" 2>/dev/null || true
        fm_send_queue_report_failed_once "$failed" "fm-send exited $rc: $(tr '\n\r\t' '   ' < "$failed/stderr" 2>/dev/null | head -c 300)"
        blocked_targets="${blocked_targets}${target}"$'\n'
        ;;
    esac
  done
}
