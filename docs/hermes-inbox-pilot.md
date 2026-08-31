# Hermes inbox pilot

`bin/fm-inbox.sh hermes-submit` is a local, same-user, stdio-only intake boundary.
It accepts one UTF-8 JSON object from standard input and writes one compact JSON result to standard output.

```sh
printf '%s' '{"version":1,"request_id":"request-123","text":"Investigate the flaky sign-in test."}' | /home/podles/fleet/firstmate/bin/fm-inbox.sh hermes-submit
```

The fixed home is derived from the command's canonical location.
`FM_HOME`, state overrides, the current directory, and request fields cannot select a different home.
The exact request properties are `version`, `request_id`, and `text`.
Version is integer `1`, IDs match `[A-Za-z0-9][A-Za-z0-9._-]{0,127}`, and text is non-empty and at most 16,384 UTF-8 bytes.
Unknown or duplicate properties are rejected.

A request ID maps to one deterministic note and private receipt.
Retried matching content returns `duplicate`; changed content returns `idempotency_conflict` without changing the original record.
Results distinguish accepted, duplicate, rejected, unavailable, and persisted-but-not-notified outcomes.
Retry `persisted_not_notified` with the same request ID after correcting the local notification problem.

This pilot only creates an ordinary inbox note with `authority=intake-only` and a durable notification.
It has no listener, network transport, credentials, project access, automatic dispatch, Pi/MCP/RPC integration, or merge authority.
Do not expose the command through a gateway or remote channel.
Before a live pilot, explicitly verify that the local interactive Hermes surface requires approval for this mutating command.
