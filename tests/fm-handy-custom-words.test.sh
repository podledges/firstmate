#!/usr/bin/env bash
# tests/fm-handy-custom-words.test.sh - Handy custom_words update behavior.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-handy-custom-words)
SETTINGS="$TMP_ROOT/settings_store.json"
cat > "$SETTINGS" <<'JSON'
{
  "custom_words": ["existing", "2271 Labs"],
  "other_setting": {"enabled": true}
}
JSON

output=$("$ROOT/bin/fm-handy-custom-words.sh" --settings "$SETTINGS" PodleSubscriptions 2271-Labs FirstmateAlpha2)
python3 - "$SETTINGS" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
words = data["custom_words"]
expected = [
    "existing",
    "2271 Labs",
    "PodleSubscriptions",
    "Podle Subscriptions",
    "2271-Labs",
    "two two seven one Labs",
    "FirstmateAlpha2",
    "Firstmate Alpha 2",
    "Firstmate Alpha two",
]
assert words == expected, words
assert data["other_setting"] == {"enabled": True}
PY
case "$output" in
  *"Added 7 Handy custom word(s)"*) ;;
  *) fail "unexpected helper output: $output" ;;
esac

# A second invocation must not rewrite the list or add duplicates.
second=$("$ROOT/bin/fm-handy-custom-words.sh" --settings "$SETTINGS" PodleSubscriptions 2271-Labs FirstmateAlpha2)
case "$second" in
  *"already contains"*) ;;
  *) fail "helper was not idempotent: $second" ;;
esac
python3 - "$SETTINGS" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    words = json.load(stream)["custom_words"]
assert len(words) == len(set(words))
PY

if "$ROOT/bin/fm-handy-custom-words.sh" --settings "$TMP_ROOT/missing.json" Example >/dev/null 2>&1; then
  fail "missing settings file was accepted"
fi
printf '{"custom_words": "not-an-array"}\n' > "$TMP_ROOT/invalid-shape.json"
if "$ROOT/bin/fm-handy-custom-words.sh" --settings "$TMP_ROOT/invalid-shape.json" Example >/dev/null 2>&1; then
  fail "invalid custom_words shape was accepted"
fi
printf '%s\n' '{not-json' > "$TMP_ROOT/bad.json"
if "$ROOT/bin/fm-handy-custom-words.sh" --settings "$TMP_ROOT/bad.json" Example >/dev/null 2>&1; then
  fail "invalid JSON was accepted"
fi

pass "Handy custom words are safely updated, variant-expanded, and idempotent"
