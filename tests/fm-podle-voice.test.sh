#!/usr/bin/env bash
# Focused executable tests for Pi's persistent local /podle-voice mode.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-podle-voice)
EXT="$ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}

command -v node >/dev/null 2>&1 || { echo "skip: node not found for Pi voice tests"; exit 0; }
[ -f "$PI_PACKAGE_DIR/package.json" ] || { echo "skip: installed Pi package not found"; exit 0; }

mkdir -p "$TMP_ROOT/node_modules/@earendil-works"
ln -s "$PI_PACKAGE_DIR" "$TMP_ROOT/node_modules/@earendil-works/pi-coding-agent"
printf '%s\n' '{"type":"module"}' >"$TMP_ROOT/package.json"
mkdir -p "$TMP_ROOT/lib"
cp "$EXT" "$TMP_ROOT/fm-primary-turnend-guard.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$TMP_ROOT/lib/fm-operational-input.ts"

FM_STATE_OVERRIDE="$TMP_ROOT/state" \
FM_OPERATIONAL_INPUT_SCRIPT="$ROOT/bin/fm-operational-input.sh" \
EXT="$TMP_ROOT/fm-primary-turnend-guard.ts" \
  node --input-type=module <<'JS'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const commands = new Map();
const notifications = [];
const executions = [];
let entries = [];
let executionCode = 0;
const pi = {
  on(name, handler) { handlers.set(name, handler); },
  registerCommand(name, command) { commands.set(name, command); },
  exec(command, args) {
    executions.push({ command, args });
    return Promise.resolve({ code: executionCode });
  },
  sendMessage() {},
  sendUserMessage() {},
};
const extension = await import(`${pathToFileURL(process.env.EXT).href}?test=${Date.now()}`);
extension.default(pi);
const ctx = {
  ui: { notify(message, level) { notifications.push({ message, level }); } },
  sessionManager: { getBranch() { return entries; } },
};
const command = commands.get("podle-voice");
if (!command) throw new Error("/podle-voice was not registered");
await command.handler("status", ctx);
if (!notifications.at(-1).message.endsWith("off.")) throw new Error("voice mode did not default off");
await command.handler("on", ctx);
if (readFileSync(`${process.env.FM_STATE_OVERRIDE}/.podle-voice`, "utf8") !== "on\n") throw new Error("on did not persist privately");
await command.handler("on", ctx);
await command.handler("", ctx);
if (readFileSync(`${process.env.FM_STATE_OVERRIDE}/.podle-voice`, "utf8") !== "off\n") throw new Error("bare command did not toggle");
await command.handler("", ctx);
await handlers.get("agent_start")({ type: "agent_start" }, ctx);
entries = [
  { type: "message", id: "u1", message: { role: "user", content: "captain request" } },
  { type: "message", id: "a1", message: { role: "assistant", content: [{ type: "text", text: "Reply aloud" }] } },
];
await handlers.get("agent_settled")({ type: "agent_settled" }, ctx);
if (executions.length !== 1 || executions[0].command !== "firstmate-tts" || executions[0].args[0] !== "Reply aloud") throw new Error("captain reply was not spoken");
await handlers.get("agent_start")({ type: "agent_start" }, ctx);
entries = [
  ...entries,
  { type: "message", id: "u2", message: { role: "user", content: "\u2063FIRSTMATE_OP: v1 watcher: internal" } },
  { type: "message", id: "a2", message: { role: "assistant", content: "Internal response" } },
];
await handlers.get("agent_settled")({ type: "agent_settled" }, ctx);
if (executions.length !== 1) throw new Error("internal response was spoken");
executionCode = 1;
await handlers.get("agent_start")({ type: "agent_start" }, ctx);
entries = [
  { type: "message", id: "u3", message: { role: "user", content: "another captain request" } },
  { type: "message", id: "a3", message: { role: "assistant", content: "Failure stays textual" } },
];
await handlers.get("agent_settled")({ type: "agent_settled" }, ctx);
if (!notifications.some((item) => item.level === "error" && item.message.includes("firstmate-tts"))) throw new Error("TTS failure lacked actionable setup error");
if (!existsSync(`${process.env.FM_STATE_OVERRIDE}/.podle-voice`)) throw new Error("private preference disappeared");
const reloadedHandlers = new Map();
const reloaded = await import(`${pathToFileURL(process.env.EXT).href}?reload=${Date.now()}`);
reloaded.default({ ...pi, on(name, handler) { reloadedHandlers.set(name, handler); } });
await reloadedHandlers.get("agent_start")({ type: "agent_start" }, ctx);
await reloadedHandlers.get("agent_settled")({ type: "agent_settled" }, ctx);
if (executions.length !== 2) throw new Error("reload replayed a reply from an aborted turn");
const secondmateHome = `${process.env.FM_STATE_OVERRIDE}/../secondmate`;
mkdirSync(secondmateHome, { recursive: true });
writeFileSync(`${secondmateHome}/.fm-secondmate-home`, "voice-test\n");
process.env.FM_HOME = secondmateHome;
process.env.FM_STATE_OVERRIDE = `${secondmateHome}/state`;
const secondmateCommands = new Map();
const secondmateHandlers = new Map();
const secondmate = await import(`${pathToFileURL(process.env.EXT).href}?secondmate=${Date.now()}`);
secondmate.default({
  ...pi,
  on(name, handler) { secondmateHandlers.set(name, handler); },
  registerCommand(name, command) { secondmateCommands.set(name, command); },
});
if (secondmateCommands.has("podle-voice")) throw new Error("voice command was enabled for a secondmate");
await secondmateHandlers.get("agent_start")({ type: "agent_start" }, ctx);
await secondmateHandlers.get("agent_settled")({ type: "agent_settled" }, ctx);
if (executions.length !== 2) throw new Error("secondmate output was spoken");
console.log("ok - Pi voice commands, captain-only reply filtering, and failure fallback");
JS
