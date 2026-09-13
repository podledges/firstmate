#!/usr/bin/env bash
# Prove that one task is intentionally blocked in a healthy foreground Lavish
# review poll.
#
# Usage:
#   fm-lavish-review-wait.sh check <task-id>
#
# `check` exits 0 and prints one `healthy:` line only when every independent
# binding agrees: the task is a live scout held for the captain, its status log
# has an open decision, one exact `lavish-axi poll <artifact>` command is in the
# recorded pane's agent process tree, the artifact is a regular HTML file under
# data/<task-id>/, Lavish reports that exact session open with no queued prompt,
# and its loopback session URL answers successfully.
#
# Any missing, malformed, ambiguous, unsupported, or unavailable evidence exits
# 1 without output. This command is a read-only stale-classification predicate;
# it never starts, stops, reopens, polls, or edits a review.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

quiet_fail() { exit 1; }

meta_value() {  # <file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

captain_hold_is_open() {  # <task-id>
  local show
  command -v tasks-axi >/dev/null 2>&1 || return 1
  show=$(cd "$FM_HOME" && tasks-axi show "$1" 2>/dev/null) || return 1
  printf '%s\n' "$show" | grep -Fx '  held: yes' >/dev/null || return 1
  printf '%s\n' "$show" | grep -Fx '  hold_kind: captain' >/dev/null || return 1
  printf '%s\n' "$show" | grep -Fx '  blocked: no' >/dev/null || return 1
  printf '%s\n' "$show" | grep -Eq '^  state: (in_flight|queued)$' || return 1
}

pane_root_pids() {  # <backend> <target>
  local backend=$1 target=$2 session pane info
  fm_backend_source "$backend" >/dev/null 2>&1 || return 1
  case "$backend" in
    herdr)
      case "$target" in *:*) session=${target%%:*}; pane=${target#*:} ;; *) return 1 ;; esac
      info=$(fm_backend_herdr_cli "$session" pane process-info --pane "$pane" 2>/dev/null) || return 1
      printf '%s' "$info" | jq -er --arg pane "$pane" '
        select(.result.type == "pane_process_info")
        | .result.process_info
        | select(.pane_id == $pane)
        | .foreground_processes
        | select(type == "array" and length > 0)
        | .[].pid
        | select(type == "number" and . > 1)
        | floor
      ' 2>/dev/null
      ;;
    tmux)
      pane=$(tmux display-message -p -t "$target" '#{pane_pid}' 2>/dev/null) || return 1
      case "$pane" in ''|*[!0-9]*) return 1 ;; esac
      [ "$pane" -gt 1 ] || return 1
      printf '%s\n' "$pane"
      ;;
    *) return 1 ;;
  esac
}

poll_artifact_in_tree() {  # <newline root pids>
  local roots=$1 ps_bin=${FM_LAVISH_PS_BIN:-ps}
  command -v "$ps_bin" >/dev/null 2>&1 || return 1
  "$ps_bin" -axo pid=,ppid=,args= 2>/dev/null | perl -e '
    use strict; use warnings;
    my $roots = shift @ARGV // "";
    my %root = map { $_ => 1 } grep { /^[0-9]+$/ && $_ > 1 } split /\n/, $roots;
    exit 1 unless keys %root;
    my (%parent, %args);
    while (<STDIN>) {
      next unless /^\s*([0-9]+)\s+([0-9]+)\s+(.*)$/;
      ($parent{$1}, $args{$1}) = ($2, $3);
    }
    my %inside = %root;
    my $changed = 1;
    while ($changed) {
      $changed = 0;
      for my $pid (keys %parent) {
        next if $inside{$pid};
        if ($inside{$parent{$pid}}) { $inside{$pid} = 1; $changed = 1; }
      }
    }
    my %artifact;
    for my $pid (keys %inside) {
      my $cmd = $args{$pid} // "";
      $artifact{$1} = 1 if $cmd =~ m{(?:^|/)lavish-axi poll ([^[:space:]]+)\s*$};
    }
    exit 1 unless keys(%artifact) == 1;
    print((keys %artifact)[0], "\n");
  ' "$roots"
}

session_url() {  # <canonical artifact>
  local artifact=$1 listing urls
  command -v lavish-axi >/dev/null 2>&1 || return 1
  listing=$(lavish-axi 2>/dev/null) || return 1
  urls=$(printf '%s\n' "$listing" | awk -F, -v artifact="  $artifact" '
    $1 == artifact && $2 == "open" && $4 == "0" {
      url=$3; sub(/^"/, "", url); sub(/"$/, "", url); print url
    }
  ')
  [ "$(printf '%s\n' "$urls" | grep -c .)" -eq 1 ] || return 1
  printf '%s\n' "$urls"
}

cmd_check() {
  local task=${1-} meta kind backend target roots artifact task_dir real url
  fm_task_id_path_safe "$task" || quiet_fail
  meta="$STATE/$task.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || quiet_fail
  kind=$(meta_value "$meta" kind)
  [ "$kind" = scout ] || quiet_fail
  backend=$(meta_value "$meta" backend)
  [ -n "$backend" ] || backend=tmux
  target=$(fm_backend_target_of_meta "$meta" 2>/dev/null) || quiet_fail
  [ -n "$target" ] || quiet_fail
  captain_hold_is_open "$task" || quiet_fail
  [ -n "$(status_open_decisions "$STATE/$task.status")" ] || quiet_fail
  roots=$(pane_root_pids "$backend" "$target") || quiet_fail
  [ -n "$roots" ] || quiet_fail
  artifact=$(poll_artifact_in_tree "$roots") || quiet_fail
  case "$artifact" in *[[:space:]]*) quiet_fail ;; esac
  [ -f "$artifact" ] && [ ! -L "$artifact" ] || quiet_fail
  case "$artifact" in *.html) ;; *) quiet_fail ;; esac
  real=$(perl -MCwd=realpath -e '$p=realpath($ARGV[0]); defined($p) or exit 1; print $p' "$artifact" 2>/dev/null) || quiet_fail
  task_dir=$(perl -MCwd=realpath -e '$p=realpath($ARGV[0]); defined($p) or exit 1; print $p' "$DATA/$task" 2>/dev/null) || quiet_fail
  case "$real" in "$task_dir"/*.html) ;; *) quiet_fail ;; esac
  url=$(session_url "$real") || quiet_fail
  case "$url" in http://127.0.0.1:[0-9]*/session/*|http://localhost:[0-9]*/session/*) ;; *) quiet_fail ;; esac
  command -v curl >/dev/null 2>&1 || quiet_fail
  curl --fail --silent --show-error --max-time 3 --output /dev/null "$url" 2>/dev/null || quiet_fail
  printf 'healthy: %s\n' "$real"
}

case "${1-}" in
  check) shift; [ "$#" -eq 1 ] || quiet_fail; cmd_check "$@" ;;
  *) quiet_fail ;;
esac
