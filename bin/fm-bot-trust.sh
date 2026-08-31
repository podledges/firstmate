#!/usr/bin/env bash
# Bot Trust: OS-backed secure randomness for explicit probability decisions.
# Usage:
#   fm-bot-trust.sh <probability>
#   fm-bot-trust.sh select [FILE|-]
#   fm-bot-trust.sh tree [FILE|-]
#
# Probability accepts a number from 0 to 100 followed by an optional percent
# sign, or a small English number such as "seventy five percent".
# Select input is one `weight | outcome` entry per line; tree input uses the
# same entry format with `>` prefixes to indicate child depth.
# Output is one stable machine-readable value: 0 or 1 for probability mode,
# and the selected outcome for select/tree mode. Use --explain for details.
# Randomness comes from Python's OS-backed secrets source, not a hardware TRNG.
set -eu

# Preserve the caller's stdin for select/tree while Python reads its program
# from the heredoc below.
exec 3<&0
exec python3 - "$@" <<'PY'
import argparse
import os
import re
import secrets
import sys
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP

NUMBERS = {
    "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
    "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
    "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
    "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30,
    "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
    "eighty": 80, "ninety": 90, "hundred": 100,
}


def fail(message):
    print(f"fm-bot-trust: {message}", file=sys.stderr)
    raise SystemExit(2)


def number_words(text):
    words = re.split(r"[ -]+", text.strip().lower())
    if not words or any(word not in NUMBERS for word in words):
        return None
    if len(words) == 1:
        return NUMBERS[words[0]]
    if "hundred" in words:
        if words.count("hundred") != 1 or words[0] == "hundred":
            return None
        prefix = NUMBERS[words[0]]
        if prefix > 9:
            return None
        rest = words[2:]
        if not rest:
            return prefix * 100
        if len(rest) == 1 and NUMBERS[rest[0]] < 10:
            return prefix * 100 + NUMBERS[rest[0]]
        return None
    if len(words) == 2 and NUMBERS[words[0]] >= 20 and NUMBERS[words[0]] % 10 == 0 and NUMBERS[words[1]] < 10:
        return NUMBERS[words[0]] + NUMBERS[words[1]]
    return None


def probability(text):
    value = text.strip().lower()
    value = re.sub(r"\s*%\s*$", "", value)
    if not value:
        fail("probability is required")
    try:
        number = Decimal(value)
    except InvalidOperation:
        parsed = number_words(value.removesuffix(" percent").strip())
        if parsed is None:
            fail("expected a number from 0 to 100, such as 70% or seventy five percent")
        number = Decimal(parsed)
    if not number.is_finite() or number < 0 or number > 100:
        fail("probability must be between 0 and 100")
    return number


def random_below(limit):
    injected = os.environ.get("FM_BOT_TRUST_RANDOM_HEX")
    if injected is not None:
        try:
            raw = bytes.fromhex(injected)
        except ValueError:
            fail("FM_BOT_TRUST_RANDOM_HEX must be hexadecimal")
        if not raw:
            fail("FM_BOT_TRUST_RANDOM_HEX must not be empty")
        return int.from_bytes(raw, "big") % limit
    bits = (limit - 1).bit_length()
    while True:
        candidate = secrets.randbits(bits)
        if candidate < limit:
            return candidate


def weighted_index(entries):
    if not entries:
        fail("no outcomes were provided")
    weights = []
    for weight, _ in entries:
        try:
            amount = Decimal(weight)
        except InvalidOperation:
            fail(f"invalid weight: {weight}")
        if not amount.is_finite() or amount <= 0:
            fail("weights must be finite and greater than zero")
        weights.append(max(1, int(amount * 1000000)))
    choice = random_below(sum(weights))
    for index, amount in enumerate(weights):
        if choice < amount:
            return index
        choice -= amount
    raise AssertionError("weighted selection fell through")


def weighted(entries):
    return entries[weighted_index(entries)][1]


def parse_entries(lines, tree=False):
    entries = []
    for lineno, raw in enumerate(lines, 1):
        line = raw.strip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        depth = 0
        if tree:
            match = re.match(r"^(\s*)(>*)\s*(.*)$", line)
            depth, line = len(match.group(2)), match.group(3)
        parts = [part.strip() for part in line.split("|", 1)]
        if len(parts) != 2:
            fail(f"line {lineno}: expected `weight | outcome`")
        weight, outcome = parts
        if not outcome:
            fail(f"line {lineno}: outcome is empty")
        entries.append((depth, weight, outcome) if tree else (weight, outcome))
    return entries


def choose_tree(entries):
    if not entries or entries[0][0] != 0:
        fail("tree must start with a depth-zero node")
    roots = []
    stack = []
    for depth, weight, outcome in entries:
        if depth > len(stack):
            fail("tree depth must increase by at most one")
        stack = stack[:depth]
        node = {"weight": weight, "outcome": outcome, "children": []}
        if depth == 0:
            roots.append(node)
        else:
            stack[-1]["children"].append(node)
        stack.append(node)

    def validate(nodes):
        for node in nodes:
            try:
                amount = Decimal(node["weight"])
            except InvalidOperation:
                fail(f"invalid weight: {node['weight']}")
            if not amount.is_finite() or amount <= 0:
                fail("weights must be finite and greater than zero")
            validate(node["children"])

    def descend(nodes):
        selected = nodes[weighted_index([(node["weight"], node["outcome"]) for node in nodes])]
        return descend(selected["children"]) if selected["children"] else selected["outcome"]

    validate(roots)
    return descend(roots)


def read_input(path):
    if path in (None, "-"):
        with os.fdopen(3, encoding="utf-8", closefd=False) as stream:
            return stream.readlines()
    try:
        with open(path, encoding="utf-8") as stream:
            return stream.readlines()
    except OSError as exc:
        fail(f"cannot read {path}: {exc}")


def main():
    parser = argparse.ArgumentParser(
        prog="bin/fm-bot-trust.sh",
        description="OS-backed secure randomness for explicit probability decisions.",
        epilog="Examples: bin/fm-bot-trust.sh '70 %'; bin/fm-bot-trust.sh select outcomes.md; printf '1 | yes\\n3 | no\\n' | bin/fm-bot-trust.sh select -",
    )
    parser.add_argument("--explain", action="store_true", help="print a human-readable explanation after the stable result")
    parser.add_argument("--random-hex", dest="random_hex", help=argparse.SUPPRESS)
    parser.add_argument("mode", nargs="?", help="probability (default), select, or tree")
    parser.add_argument("input", nargs="?")
    args = parser.parse_args()
    if args.random_hex is not None:
        os.environ["FM_BOT_TRUST_RANDOM_HEX"] = args.random_hex
    mode = args.mode or ""
    if mode in ("select", "tree"):
        entries = parse_entries(read_input(args.input), tree=mode == "tree")
        result = choose_tree(entries) if mode == "tree" else weighted(entries)
        print(result)
        if args.explain:
            print(f"selected outcome using OS-backed secure randomness ({mode})")
        return
    if args.input is not None:
        fail("probability mode accepts exactly one probability expression")
    chance = probability(mode)
    scaled = (chance * 100).quantize(Decimal("1"), rounding=ROUND_HALF_UP)
    threshold = int(scaled) or (1 if chance > 0 else 0)
    result = 1 if random_below(10000) < threshold else 0
    print(result)
    if args.explain:
        print(f"probability={chance}% source=OS-backed secure randomness")


if __name__ == "__main__":
    main()
PY
