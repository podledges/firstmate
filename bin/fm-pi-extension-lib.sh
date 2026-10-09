#!/usr/bin/env bash
# Shared validation for fm-spawn.sh's task-scoped Pi extension selection.
# The launch owner remains bin/fm-spawn.sh; fm-control.sh uses this helper only
# to reject an invalid relaunch before stopping the current worker.

fm_pi_executable_resolve() {  # <executable-name>
  local candidate dir
  candidate=$(type -P -- "$1" 2>/dev/null) || return 1
  [ -x "$candidate" ] || return 1
  case "$candidate" in
    /*) printf '%s\n' "$candidate" ;;
    *)
      dir=$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P) || return 1
      printf '%s/%s\n' "$dir" "$(basename "$candidate")"
      ;;
  esac
}

fm_pi_help_has_option() {  # <help-text> <long-option>
  local help=$1 option=$2
  printf '%s\n' "$help" | grep -Eq -- "(^|[[:space:]])${option}([^[:alnum:]_-]|$)"
}

fm_pi_extension_cli_validate() {  # <pi-family-executable> <identity> [already-read-help]
  local executable=$1 identity=$2 help
  if [ "$#" -ge 3 ]; then
    help=$3
  else
    help=$("$executable" --help 2>&1) || help=
  fi
  if ! fm_pi_help_has_option "$help" --no-extensions \
     || ! fm_pi_help_has_option "$help" --extension; then
    echo "error: $identity does not advertise --no-extensions and --extension; refusing --pi-extension rather than launching with uncontrolled discovery" >&2
    return 1
  fi
}

fm_pi_extension_validate_file() {  # <absolute-extension-file>
  local path=${1:-}
  [ -n "$path" ] || {
    echo "error: --pi-extension requires a non-empty value" >&2
    return 1
  }
  case "$path" in
    /*) ;;
    *)
      echo "error: --pi-extension requires an absolute path so the selected extension is identical across spawn and relaunch (got '$path')" >&2
      return 1
      ;;
  esac
  case "$path" in
    *$'\n'*|*$'\r'*)
      echo "error: --pi-extension path must not contain a newline or carriage return" >&2
      return 1
      ;;
  esac
  if [ ! -f "$path" ] || [ -L "$path" ] || [ ! -r "$path" ]; then
    echo "error: --pi-extension must name a readable regular non-symlink file (got '$path')" >&2
    return 1
  fi
}

fm_pi_extension_validate_harness() {  # <extension-file-or-empty> <harness>
  local path=${1:-} harness=${2:-}
  [ -z "$path" ] && return 0
  case "$harness" in
    pi|pi-signed) return 0 ;;
    *)
      echo "error: --pi-extension applies only to pi or pi-signed workers, not '$harness'" >&2
      return 1
      ;;
  esac
}
