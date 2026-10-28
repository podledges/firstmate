# Runtime instruction evaluation

- Interface: `pi 1.4.0 --approve --no-session --tools read --mode json -p …`
- Model: `openai-codex/gpt-5.6-sol`
- Safety: read-only tool allowlist; no shell or write tools available to the evaluated agent.

## Skill bodies loaded by the agent

- `read`: `.agents/skills/task-briefing/SKILL.md`
- `read`: `.agents/skills/worker-dispatch/SKILL.md`
- `read`: `.agents/skills/backlog-operations/SKILL.md`

## Final user-visible response

- **Create/change ship instructions — `task-briefing`:** Preserve the generated scaffold as a safety contract, keep captain intent exact and scope narrow, and require isolated-copy execution.
- **Resolve dispatch and spawn/steer — `worker-dispatch`:** Apply dispatch precedence and backend validation, require isolation, and use only guarded spawn/steering paths. A matched profile array additionally requires `quota-array-dispatch`.
- **Hold/update/reconcile/hand off backlog work — `backlog-operations`:** Treat the configured backlog as authoritative, record captain waits through the hold wrapper, inspect notes before replacement, and use guarded cross-home handoff.

Additional rules, captain:

1. **First fleet action at session start:** Run `bin/fm-session-start.sh` exactly once before any other fleet action.
2. **Notification turn ordering:** First drain the durable notification queue; then handle all notifications, reconcile `OPEN DECISIONS`, and read/handle `UNREAD STATUS`; only afterward run the exact generation-bound acknowledgement command.
3. **No-op reply:** `Captain, shipshape.` is permitted only for a genuine no-op with no captain-relevant outcome and no outstanding decision. It is forbidden when completion was requested or review, approval, merge, design, recovery, or escalation remains.
