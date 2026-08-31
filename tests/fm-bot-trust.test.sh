#!/usr/bin/env bash
# Behavioral tests for explicit probability decisions and weighted selectors.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOT_TRUST="$ROOT/bin/fm-bot-trust.sh"
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
test_weighted_and_tree_modes
