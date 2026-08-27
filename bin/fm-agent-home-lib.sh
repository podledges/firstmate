#!/usr/bin/env bash
# Firstmate-private Codex and Grok home mechanics.
#
# Every home is fixed beneath <firstmate-home>/data/agent-homes. Callers never
# consult ambient CODEX_HOME or GROK_HOME when resolving these paths, so a
# personal login-shell setting cannot redirect Firstmate state into the
# captain's normal agent homes. docs/configuration.md owns the operator-facing
# contract; this file owns path construction and private-directory preparation.

fm_agent_home_path() {  # <firstmate-home> <codex|grok>
  local home=${1-} harness=${2-}
  [ -n "$home" ] || return 1
  case "$home" in /*) ;; *) return 1 ;; esac
  case "$harness" in
    codex|grok) printf '%s/data/agent-homes/%s\n' "${home%/}" "$harness" ;;
    *) return 1 ;;
  esac
}

fm_agent_homes_prepare() {  # <firstmate-home>
  local home=${1-} root codex_home grok_home old_umask path
  root=$(fm_agent_home_path "$home" codex) || {
    echo "error: cannot resolve private agent homes beneath firstmate home '${home:-unset}'" >&2
    return 1
  }
  root=${root%/codex}
  codex_home="$root/codex"
  grok_home="$root/grok"

  for path in "$root" "$codex_home" "$grok_home"; do
    if [ -L "$path" ]; then
      echo "error: private agent home path must not be a symlink: $path" >&2
      return 1
    fi
    if [ -e "$path" ] && [ ! -d "$path" ]; then
      echo "error: private agent home path is not a directory: $path" >&2
      return 1
    fi
  done

  old_umask=$(umask)
  umask 077
  if ! mkdir -p "$codex_home" "$grok_home"; then
    umask "$old_umask"
    echo "error: could not create private agent homes beneath $root" >&2
    return 1
  fi
  umask "$old_umask"
  chmod 0700 "$root" "$codex_home" "$grok_home" || {
    echo "error: could not secure private agent homes beneath $root" >&2
    return 1
  }
}
