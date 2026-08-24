#!/usr/bin/env bash
# fm-handy-custom-words.sh - add project words to Handy's custom_words list.
#
# Usage: fm-handy-custom-words.sh [--settings PATH] WORD [WORD...]
#
# The default is Handy's Windows settings file as seen from WSL. Set
# HANDY_SETTINGS_PATH or use --settings for another installation or a test
# fixture. The file is updated atomically and repeated words are ignored.
set -u

DEFAULT_SETTINGS='/mnt/c/Users/ayden/AppData/Roaming/com.pais.handy/settings_store.json'
SETTINGS_PATH=${HANDY_SETTINGS_PATH:-$DEFAULT_SETTINGS}
WORDS=()

usage() {
  cat <<'EOF'
Usage: fm-handy-custom-words.sh [--settings PATH] WORD [WORD...]

Add project-name variants to Handy's custom_words array.
--settings PATH  Handy settings JSON path (default: HANDY_SETTINGS_PATH or the WSL Windows path)
--help           Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case $1 in
    --settings)
      [ "$#" -ge 2 ] || { printf '%s\n' 'error: --settings requires a path' >&2; exit 2; }
      SETTINGS_PATH=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      WORDS+=("$@")
      break
      ;;
    -* )
      printf 'error: unknown option: %s\n' "$1" >&2
      exit 2
      ;;
    *)
      WORDS+=("$1")
      shift
      ;;
  esac
done

[ "${#WORDS[@]}" -gt 0 ] || { printf '%s\n' 'error: provide at least one word' >&2; exit 2; }
[ -f "$SETTINGS_PATH" ] || { printf 'error: Handy settings file not found: %s\n' "$SETTINGS_PATH" >&2; exit 1; }

python3 - "$SETTINGS_PATH" "${WORDS[@]}" <<'PY'
import json
import os
import re
import stat
import sys
import tempfile

path, *names = sys.argv[1:]
digits = {
    "0": "zero", "1": "one", "2": "two", "3": "three", "4": "four",
    "5": "five", "6": "six", "7": "seven", "8": "eight", "9": "nine",
}

def variants(name):
    values = [name]
    token = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", name)
    token = re.sub(r"([A-Za-z])([0-9])", r"\1 \2", token)
    token = re.sub(r"[-_.]+", " ", token)
    token = re.sub(r"\s+", " ", token).strip()
    if token and token != name:
        values.append(token)
    expanded = re.sub(
        r"\d+", lambda match: " ".join(digits[ch] for ch in match.group(0)), token
    )
    if any(ch.isdigit() for ch in token) and expanded != token:
        values.append(expanded)
    return values

try:
    with open(path, encoding="utf-8") as stream:
        document = json.load(stream)
except json.JSONDecodeError as exc:
    print(f"error: invalid Handy settings JSON in {path}: {exc}", file=sys.stderr)
    sys.exit(1)
except OSError as exc:
    print(f"error: cannot read Handy settings file {path}: {exc}", file=sys.stderr)
    sys.exit(1)

if not isinstance(document, dict):
    print(f"error: Handy settings must be a JSON object: {path}", file=sys.stderr)
    sys.exit(1)
words = document.get("custom_words")
if not isinstance(words, list) or any(not isinstance(word, str) for word in words):
    print(f"error: Handy settings custom_words must be an array of strings: {path}", file=sys.stderr)
    sys.exit(1)

existing = set(words)
added = []
for name in names:
    for value in variants(name):
        if value not in existing:
            words.append(value)
            existing.add(value)
            added.append(value)

if not added:
    print("Handy custom_words already contains the requested words")
    sys.exit(0)

mode = stat.S_IMODE(os.stat(path).st_mode)
directory = os.path.dirname(os.path.abspath(path)) or "."
fd, temporary = tempfile.mkstemp(prefix=".handy-custom-words.", dir=directory, text=True)
try:
    os.chmod(temporary, mode)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump(document, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
except OSError as exc:
    try:
        os.unlink(temporary)
    except OSError:
        pass
    print(f"error: cannot update Handy settings file {path}: {exc}", file=sys.stderr)
    sys.exit(1)

print(f"Added {len(added)} Handy custom word(s) to {path}")
PY
