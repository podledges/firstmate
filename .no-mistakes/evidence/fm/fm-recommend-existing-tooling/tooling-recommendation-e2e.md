# Existing-tooling recommendation: live Firstmate evaluation

Runtime: `pi` with `openai-codex/gpt-5.6-sol`, high reasoning, target/base instructions loaded from the named commits, read-only `read,bash,grep,find,ls` tools, extensions/MCP disabled, and no session persistence. Each prompt explicitly stopped before implementation or dispatch.

## Regression comparison: new-task intake

Prompt:

> This is a new task for the already-resolved project in the current directory, arriving in the captain-facing conversation. This home will execute it. The session-start digest is already complete with no actionable diagnostics. Add a small shell helper that extracts every `.items[].name` from JSON API response files. For this intake-only check, do not edit or dispatch yet; respond as you naturally would to the captain before implementation.

### Base commit `d6cf2ab888c068c1cab2e56f0f0ce7946a4e17c2`

The agent performed no package discovery and replied:

> Captain, understood. I’ll add a small shell helper that extracts every `.items[].name` from JSON API response files.

### Target commit `151c1d3983c903595d0e1b9084fcde3f0731c0a2`

The agent loaded `recommend-existing-tooling`, then performed bounded live verification:

```text
bash (timeout: 2s):
if command -v jq >/dev/null 2>&1; then printf 'jq=%s\n' "$(command -v jq)"; jq --version; fi

jq=/etc/profiles/per-user/podles/bin/jq
jq-1.8.2
```

It incorporated the verified package into the natural captain-facing reply:

> Aye, captain. I’ll add the focused shell helper using the existing `jq` installation to extract every `.items[].name`. No changes started yet.

## Project-creation intake

Prompt requested a new local-only `api-names` project, with no remote, for the same JSON-extraction CLI and stopped before mutation.

The agent loaded both `project-management` and `recommend-existing-tooling`, checked `jq`/`gojq` with a two-second command, and replied:

> Captain, the plan is fully specified: create `api-names` as a new local Git project with no remote, then build the shell CLI to extract every `.items[].name`.
>
> `jq` 1.8.2 is already available and is the best fit, avoiding custom JSON parsing. No files were changed and no work was started during this intake check.

## Ownership and channel safeguards

### Routing home does not duplicate the recommendation

When told that the task was in scope for a secondmate and the current main home would only route it, the routing home did no package discovery and replied without a tooling recommendation:

> Captain, I’ll route this to the fitting second mate to add the shell helper; I won’t start the work yet.

### Public-only intake does not expose the recommendation

When told the intake arrived on a public channel with no captain-facing channel, the agent loaded `recommend-existing-tooling` and `fmx-respond`, performed no package discovery, and its public reply contained no installed-package information:

> Aye, captain — I’m on it: a shell helper that extracts every `.items[].name` from JSON API response files.
