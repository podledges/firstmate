#!/usr/bin/env bash
# Bot Trust natural-language probability filter.
# Usage:
#   fm-bot-trust-filter.sh <request>
#
# Recognizes a bare numeric percentage or an explicit probability request that
# contains exactly one numeric percentage, then routes only that percentage to
# fm-bot-trust.sh. A non-match exits 1 without output or helper invocation.
# This filter may influence wording and idea surfacing, but authorizes no action.
set -eu

if [ "$#" -ne 1 ]; then
  printf 'usage: %s <request>\n' "${0##*/}" >&2
  exit 2
fi

request=$1
percentage=$(python3 - "$request" <<'PY'
import re
import sys

text = sys.argv[1].strip()
if not text:
    raise SystemExit(1)

percentage_pattern = r"(?<![\w.])([+-]?\d+(?:\.\d+)?)\s*(%|percent)(?![\w%])"
percentages = re.findall(percentage_pattern, text, re.IGNORECASE)

# A bare percentage is an unambiguous exact probability input.
if re.fullmatch(r"[+-]?\d+(?:\.\d+)?\s*(?:%|percent)", text, re.IGNORECASE):
    print(percentages[0][0] + "%")
    raise SystemExit(0)

# Natural language needs both one exact percentage and explicit probability or
# random-choice phrasing. Incidental percentages and ambiguous inputs do not
# reach the stateless helper.
if len(percentages) != 1:
    raise SystemExit(1)

probability_cue = re.search(
    r"\b(?:chance|probability|odds|likelihood)\b",
    text,
    re.IGNORECASE,
)
random_choice_cue = re.search(
    r"\b(?:flip(?:ping)?(?:\s+(?:a|the))?\s+coin|roll(?:ing)?|"
    r"choose|pick|decide)\b[^.!?]*\brandom(?:ly|ized)?\b|"
    r"\brandom(?:ly|ized)?\b[^.!?]*\b(?:choose|pick|decide)\b",
    text,
    re.IGNORECASE,
)
if probability_cue is None and random_choice_cue is None:
    raise SystemExit(1)

print(percentages[0][0] + "%")
PY
) || exit $?

exec "$(dirname "$0")/fm-bot-trust.sh" -- "$percentage"
