#!/usr/bin/env bash
# Behavioral tests for explicit probability decisions and weighted selectors.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOT_TRUST="$ROOT/bin/fm-bot-trust.sh"
BOT_TRUST_FILTER="$ROOT/bin/fm-bot-trust-filter.sh"
TMP_ROOT=$(fm_test_tmproot fm-bot-trust)

expect_failure() {
  local expected=$1
  shift
  local output rc
  set +e
  output=$({ "$@"; } 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "expected command failure: $*"
  assert_contains "$output" "$expected" "failure did not explain the invalid input"
}

test_binary_probability() {
  [ "$(FM_BOT_TRUST_RANDOM_HEX=00 "$BOT_TRUST" '70 %')" = 1 ] || fail "70% hit was not selected"
  [ "$(FM_BOT_TRUST_RANDOM_HEX=ffff "$BOT_TRUST" '70%')" = 1 ] || fail "70% upper hit was not selected"
  [ "$(FM_BOT_TRUST_RANDOM_HEX=00 "$BOT_TRUST" '0%')" = 0 ] || fail "0% selected a hit"
  [ "$(FM_BOT_TRUST_RANDOM_HEX=ffff "$BOT_TRUST" '0%')" = 0 ] || fail "0% upper bound selected a hit"
  [ "$(FM_BOT_TRUST_RANDOM_HEX=00 "$BOT_TRUST" 'seventy five %')" = 1 ] || fail "written percentage was not parsed"
  expect_failure 'probability must be between 0 and 100' "$BOT_TRUST" 101%
  expect_failure 'expected a number' "$BOT_TRUST" 'maybe percent'
  [ "$(FM_BOT_TRUST_RANDOM_HEX=00 "$BOT_TRUST" --explain 50%)" = $'1\nprobability=50% source=OS-backed secure randomness' ] \
    || fail "explain output was not opt-in and stable"
  pass "binary probabilities parse, validate, and return stable outcomes"
}

test_probability_filter() {
  [ "$(FM_BOT_TRUST_RANDOM_HEX=00 "$BOT_TRUST_FILTER" 'flip a coin with a 70% chance')" = 1 ] \
    || fail "natural-language percentage was not routed to Bot Trust"
  [ "$(FM_BOT_TRUST_RANDOM_HEX=270f "$BOT_TRUST_FILTER" 'choose randomly with a 70 percent probability')" = 0 ] \
    || fail "spelled percent suffix was not routed to Bot Trust"
  [ "$(FM_BOT_TRUST_RANDOM_HEX=00 "$BOT_TRUST_FILTER" '70 percent')" = 1 ] \
    || fail "bare exact percentage was not routed to Bot Trust"

  local output rc
  set +e
  output=$(FM_BOT_TRUST_RANDOM_HEX=not-hex "$BOT_TRUST_FILTER" 'the project is 70% complete' 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "incidental percentage was treated as a probability request"
  [ -z "$output" ] || fail "non-matching input produced output"

  set +e
  output=$(FM_BOT_TRUST_RANDOM_HEX=not-hex "$BOT_TRUST_FILTER" 'the chance of rain is 70%' 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "factual probability statement was treated as a decision request"
  [ -z "$output" ] || fail "factual probability statement produced output"

  set +e
  output=$(FM_BOT_TRUST_RANDOM_HEX=not-hex "$BOT_TRUST_FILTER" 'choose with a 30% or 70% chance' 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "multiple percentages were treated as an exact probability"
  [ -z "$output" ] || fail "ambiguous input produced output"

  expect_failure 'probability must be between 0 and 100' "$BOT_TRUST_FILTER" 'flip with a 101% chance'
  expect_failure 'probability must be between 0 and 100' "$BOT_TRUST_FILTER" 'choose randomly with a -1% probability'
  pass "natural-language probability filtering routes only exact explicit percentages"
}

test_weighted_and_tree_modes() {
  local choices tree
  choices="$TMP_ROOT/choices.md"
  printf '%s\n' '1 | red' '3 | blue' > "$choices"
  [ "$(FM_BOT_TRUST_RANDOM_HEX=00 "$BOT_TRUST" select "$choices")" = red ] || fail "weighted selector did not choose first outcome"
  [ "$(FM_BOT_TRUST_RANDOM_HEX=2dc6c0 "$BOT_TRUST" select "$choices")" = blue ] || fail "weighted selector did not choose weighted outcome"
  [ "$(printf '1 | stdin\n' | FM_BOT_TRUST_RANDOM_HEX=00 "$BOT_TRUST" select -)" = stdin ] || fail "weighted selector did not read stdin"
  expect_failure 'weights must be finite' "$BOT_TRUST" select <(printf '0 | nowhere\n')

  tree="$TMP_ROOT/tree.md"
  printf '%s\n' '# Root choices' '1 | root-a' '3 | root-b' '> 1 | leaf-a' '> 3 | leaf-b' > "$tree"
  [ "$(FM_BOT_TRUST_RANDOM_HEX=2dc6c0 "$BOT_TRUST" tree "$tree")" = leaf-b ] || fail "tree selector did not follow depth-marked child"
  printf '%s\n' '1 | root' '> 1 | branch' '>> 1 | deep-leaf' > "$tree"
  [ "$(FM_BOT_TRUST_RANDOM_HEX=00 "$BOT_TRUST" tree "$tree")" = deep-leaf ] || fail "tree selector did not follow nested depth markers"
  pass "weighted selectors and depth-marked trees return selected outcomes"
}

test_binary_probability
test_probability_filter
test_weighted_and_tree_modes
