---
name: bot-trust
description: Use Bot Trust for explicit probability requests and randomized choices.
user-invocable: false
metadata:
  internal: true
---

# Bot Trust

Invoke `bin/fm-bot-trust.sh` when the captain explicitly types a probability request such as `70 %` or asks for a randomized decision.

Do not invoke it merely because probability is mentioned casually, or when implementing probability logic for an application unless implementation guidance is requested.

Use the helper's stable result as the decision: binary mode returns `0` or `1`, while `select` and `tree` return the selected outcome.

Bot Trust never replaces safety checks, merge authority, destructive-action approval, security-sensitive choices, purchases, credentials, or other captain-owned decisions.

For future tool chaining or personality behavior, use the result only for the current requested decision and do not invent lasting behavior without an explicitly accepted tracked instruction change.

The helper uses operating-system-backed secure randomness and is not hardware quantum randomness.
