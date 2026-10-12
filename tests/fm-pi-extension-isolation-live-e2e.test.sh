#!/usr/bin/env bash
# Opt-in real Pi-family guard for task-scoped extension discovery isolation.
# Uses only fixture-owned Pi state and RPC startup, makes no model request, and
# proves the duplicate-tool failure, the ordinary one-provider path, and the
# repaired explicit-provider path for every installed Pi-family identity.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ "${FM_PI_EXTENSION_ISOLATION_LIVE:-0}" = 1 ] || {
  echo "skip: set FM_PI_EXTENSION_ISOLATION_LIVE=1 to run the real Pi extension-isolation guard"
  exit 0
}

TMP_ROOT=$(fm_test_tmproot fm-pi-extension-isolation-live)
mkdir -p "$TMP_ROOT/agent/extensions" "$TMP_ROOT/collision/.pi/extensions" "$TMP_ROOT/ordinary"
LOAD_LOG="$TMP_ROOT/load.log"
SHOW_REG_EXTENSION=${FM_SHOW_REG_EXTENSION:-$HOME/.pi/agent/git/github.com/podledges/show-reg/extensions/show-reg/index.ts}
[ -f "$SHOW_REG_EXTENSION" ] || fail "show-reg extension not found at $SHOW_REG_EXTENSION"

cat > "$TMP_ROOT/agent/extensions/global.ts" <<'TS'
import { Type } from "@earendil-works/pi-ai";
import { appendFileSync } from "node:fs";
export default function (pi: any) {
  appendFileSync(process.env.FM_PI_LOAD_LOG!, "fixture-global\n");
  for (const name of ["show_register", "show_register_setup"]) {
    pi.registerTool({
      name,
      description: name,
      parameters: Type.Object({}),
      execute: async () => ({ content: [{ type: "text", text: "fixture-global" }], details: undefined }),
    });
  }
}
TS

cat > "$TMP_ROOT/collision/.pi/extensions/project.ts" <<'TS'
import { Type } from "@earendil-works/pi-ai";
import { appendFileSync } from "node:fs";
export default function (pi: any) {
  appendFileSync(process.env.FM_PI_LOAD_LOG!, "fixture-project\n");
  for (const name of ["show_register", "show_register_setup"]) {
    pi.registerTool({
      name,
      description: name,
      parameters: Type.Object({}),
      execute: async () => ({ content: [{ type: "text", text: "fixture-project" }], details: undefined }),
    });
  }
}
TS

cat > "$TMP_ROOT/lifecycle-observer.ts" <<'TS'
import { appendFileSync } from "node:fs";
export default function (pi: any) {
  appendFileSync(process.env.FM_PI_LOAD_LOG!, "firstmate-lifecycle-factory\n");
  pi.on("session_start", () => {
    appendFileSync(process.env.FM_PI_LOAD_LOG!, "firstmate-session-start\n");
    const names = pi.getAllTools()
      .map((tool: any) => tool.name)
      .filter((name: string) => name === "show_register" || name === "show_register_setup")
      .sort();
    appendFileSync(process.env.FM_PI_LOAD_LOG!, `registered=${names.join(",")} count=${names.length}\n`);
    if (names.length !== 2 || names[0] !== "show_register" || names[1] !== "show_register_setup") {
      throw new Error(`unexpected show-reg tool registration: ${names.join(",")}`);
    }
  });
}
TS

run_rpc() {  # <harness> <cwd> <stdout> <stderr> [args...]
  local harness=$1 cwd=$2 stdout=$3 stderr=$4
  shift 4
  (
    cd "$cwd" || exit 1
    PI_CODING_AGENT_DIR="$TMP_ROOT/agent" FM_PI_LOAD_LOG="$LOAD_LOG" \
      "$harness" --approve --offline --mode rpc --no-session "$@" \
      </dev/null >"$stdout" 2>"$stderr"
  )
}

checked=0
for harness in pi pi-signed; do
  if ! command -v "$harness" >/dev/null 2>&1; then
    echo "# harness absent, not verified here: $harness"
    continue
  fi
  version=$("$harness" --version 2>&1 | head -1)
  checked=$((checked + 1))

  : > "$LOAD_LOG"
  rc=0
  run_rpc "$harness" "$TMP_ROOT/collision" "$TMP_ROOT/$harness-collision.out" "$TMP_ROOT/$harness-collision.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "$harness $version accepted duplicate show-reg tool registrations"
  assert_grep 'Tool "show_register" conflicts with' "$TMP_ROOT/$harness-collision.err" \
    "$harness collision did not name show_register"
  assert_grep 'Tool "show_register_setup" conflicts with' "$TMP_ROOT/$harness-collision.err" \
    "$harness collision did not name show_register_setup"
  assert_grep 'fixture-project' "$LOAD_LOG" "$harness did not load the project provider in the collision case"
  assert_grep 'fixture-global' "$LOAD_LOG" "$harness did not load the global provider in the collision case"

  : > "$LOAD_LOG"
  run_rpc "$harness" "$TMP_ROOT/ordinary" "$TMP_ROOT/$harness-ordinary.out" "$TMP_ROOT/$harness-ordinary.err" \
    -e "$TMP_ROOT/lifecycle-observer.ts"
  assert_grep 'firstmate-session-start' "$LOAD_LOG" "$harness ordinary path lost the lifecycle event"
  assert_grep 'registered=show_register,show_register_setup count=2' "$LOAD_LOG" \
    "$harness ordinary path did not register one provider for both tools"

  : > "$LOAD_LOG"
  run_rpc "$harness" "$TMP_ROOT/collision" "$TMP_ROOT/$harness-repaired.out" "$TMP_ROOT/$harness-repaired.err" \
    --no-extensions \
    -e builtin:mcp -e builtin:llama.cpp -e builtin:codemode -e builtin:tool-search \
    -e "$TMP_ROOT/lifecycle-observer.ts" -e "$SHOW_REG_EXTENSION"
  assert_grep 'firstmate-lifecycle-factory' "$LOAD_LOG" "$harness repaired path did not load the lifecycle extension"
  assert_grep 'firstmate-session-start' "$LOAD_LOG" "$harness repaired path lost the lifecycle event"
  assert_grep 'registered=show_register,show_register_setup count=2' "$LOAD_LOG" \
    "$harness repaired path did not register exactly one real show-reg provider"
  assert_no_grep 'fixture-project' "$LOAD_LOG" "$harness repaired path still discovered the project provider"
  assert_no_grep 'fixture-global' "$LOAD_LOG" "$harness repaired path still discovered the fixture global provider"
  [ ! -s "$TMP_ROOT/$harness-repaired.err" ] \
    || fail "$harness repaired startup wrote diagnostics: $(cat "$TMP_ROOT/$harness-repaired.err")"
  pass "$harness $version: real startup isolates one show-reg provider and retains lifecycle events"
done

[ "$checked" -gt 0 ] || fail "no installed Pi-family harness was exercised"
echo "# checked $checked installed Pi-family harness(es)"
