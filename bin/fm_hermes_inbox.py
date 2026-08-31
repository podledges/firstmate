#!/usr/bin/env python3
"""Private strict protocol helper for fm-inbox.sh hermes-submit."""
import argparse
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
from datetime import UTC, datetime

MAX_DOCUMENT = 20_480
MAX_TEXT = 16_384
REQUEST_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


def result(status, accepted=False, duplicate=False, note_id=None, notified=False, code=None):
    value = {"version": 1, "status": status, "accepted": accepted,
             "duplicate": duplicate, "note_id": note_id, "notified": notified}
    if code:
        value["error"] = {"code": code}
    return value


def emit(value, exit_code=0):
    print(json.dumps(value, separators=(",", ":"), ensure_ascii=True))
    raise SystemExit(exit_code)


def private_dir(path, create=False):
    if create and not os.path.exists(path):
        os.mkdir(path, 0o700)
    st = os.lstat(path)
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode) or st.st_uid != os.geteuid() or stat.S_IMODE(st.st_mode) != 0o700:
        raise UnsafePath
    return st


def private_file(path):
    st = os.lstat(path)
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid() or st.st_nlink != 1 or stat.S_IMODE(st.st_mode) != 0o600:
        raise UnsafePath
    return st


def atomic_new(path, data):
    parent = os.path.dirname(path)
    parent_st = private_dir(parent)
    fd, temp = tempfile.mkstemp(prefix=".hermes-", dir=parent)
    try:
        os.fchmod(fd, 0o600)
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid() or st.st_nlink != 1 or stat.S_IMODE(st.st_mode) != 0o600 or st.st_dev != parent_st.st_dev:
            raise UnsafePath
        with os.fdopen(fd, "wb", closefd=False) as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.close(fd)
        try:
            os.link(temp, path, follow_symlinks=False)
        except FileExistsError:
            return False
        os.unlink(temp)
        directory_fd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        private_file(path)
        return True
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.unlink(temp)
        except FileNotFoundError:
            pass


def atomic_replace(path, data):
    private_file(path)
    parent = os.path.dirname(path)
    parent_st = private_dir(parent)
    fd, temp = tempfile.mkstemp(prefix=".hermes-", dir=parent)
    try:
        os.fchmod(fd, 0o600)
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid() or st.st_nlink != 1 or stat.S_IMODE(st.st_mode) != 0o600 or st.st_dev != parent_st.st_dev:
            raise UnsafePath
        with os.fdopen(fd, "wb", closefd=False) as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.close(fd)
        private_file(path)
        os.replace(temp, path)
        directory_fd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        private_file(path)
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.unlink(temp)
        except FileNotFoundError:
            pass


class UnsafePath(Exception):
    pass


def reject_request():
    emit(result("rejected", code="invalid_request"), 2)


class ObjectPairs(list):
    pass


def parse_request():
    raw = sys.stdin.buffer.read(MAX_DOCUMENT + 1)
    if len(raw) > MAX_DOCUMENT:
        reject_request()
    try:
        decoded = raw.decode("utf-8")
        pairs = json.loads(decoded, object_pairs_hook=ObjectPairs)
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError):
        reject_request()
    if not isinstance(pairs, ObjectPairs):
        reject_request()
    if any(not isinstance(pair, tuple) or len(pair) != 2 for pair in pairs):
        reject_request()
    keys = [key for key, _ in pairs]
    if len(set(keys)) != len(keys) or set(keys) != {"version", "request_id", "text"} or len(keys) != 3:
        reject_request()
    request = dict(pairs)
    if type(request["version"]) is not int or request["version"] != 1:
        reject_request()
    request_id = request["request_id"]
    text = request["text"]
    if not isinstance(request_id, str) or not REQUEST_ID.fullmatch(request_id):
        reject_request()
    if not isinstance(text, str) or "\x00" in text or not text.strip():
        reject_request()
    try:
        if len(text.encode("utf-8")) > MAX_TEXT:
            reject_request()
    except UnicodeEncodeError:
        reject_request()
    return request


def load_json(path, code):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, UnicodeError, json.JSONDecodeError):
        emit(result("unavailable", code=code), 4)


def validate_receipt(receipt, request_id, request_key, content_hash, note_id):
    expected = {"version", "request_id", "request_key", "content_hash", "note_id", "accepted_at", "phase"}
    if not isinstance(receipt, dict) or set(receipt) != expected or receipt.get("version") != 1 or receipt.get("request_id") != request_id or receipt.get("request_key") != request_key or receipt.get("note_id") != note_id or receipt.get("phase") not in ("reserved", "accepted") or not isinstance(receipt.get("accepted_at"), str):
        emit(result("unavailable", code="corrupt_receipt"), 4)
    if receipt.get("content_hash") != content_hash:
        emit(result("rejected", code="idempotency_conflict"), 2)


def note_bytes(note_id, accepted_at, request_id, request_key, content_hash, text):
    header = (f"id={note_id}\nat={accepted_at}\nsource=hermes\norigin=local-interactive\nauthority=intake-only\n"
              f"source_request_id={request_id}\nsource_request_sha256={request_key}\ncontent_sha256={content_hash}\n--\n")
    return header.encode("utf-8") + text.encode("utf-8") + b"\n"


def verify_note(path, expected):
    try:
        private_file(path)
        with open(path, "rb") as handle:
            actual = handle.read()
    except (OSError, UnsafePath):
        emit(result("unavailable", code="corrupt_note"), 4)
    if actual != expected:
        emit(result("unavailable", code="corrupt_note"), 4)


def ensure_paths(root, inbox):
    if os.getuid() != os.geteuid():
        emit(result("unavailable", code="home_unavailable"), 4)
    try:
        root_st = os.lstat(root)
        if stat.S_ISLNK(root_st.st_mode) or not stat.S_ISDIR(root_st.st_mode) or root_st.st_uid != os.geteuid() or stat.S_IMODE(root_st.st_mode) & 0o022:
            raise UnsafePath
        state = os.path.dirname(inbox)
        private_dir(state, create=True)
        private_dir(inbox, create=True)
        hermes = os.path.join(inbox, ".hermes")
        private_dir(hermes, create=True)
        receipts = os.path.join(hermes, "receipts")
        private_dir(receipts, create=True)
        if os.stat(inbox).st_dev != os.stat(receipts).st_dev:
            raise UnsafePath
    except (OSError, UnsafePath):
        emit(result("unavailable", code="unsafe_path"), 4)
    return receipts


def ensure_private_file(path):
    if os.path.lexists(path):
        private_file(path)
    elif not atomic_new(path, b""):
        private_file(path)


def ensure_notification(root, inbox):
    ensure_paths(root, inbox)
    try:
        state = os.path.dirname(inbox)
        ensure_private_file(os.path.join(state, ".wake-queue"))
        ensure_private_file(os.path.join(state, ".wake-queue.seq"))
    except (OSError, UnsafePath):
        emit(result("unavailable", code="unsafe_path"), 4)


def prepare(root, inbox):
    receipts = ensure_paths(root, inbox)
    request = parse_request()
    canonical = json.dumps({"version": 1, "request_id": request["request_id"], "text": request["text"]}, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    request_key = hashlib.sha256(request["request_id"].encode("utf-8")).hexdigest()
    content_hash = hashlib.sha256(canonical).hexdigest()
    note_id = f"hermes-{request_key}"
    receipt_path = os.path.join(receipts, f"{request_key}.json")
    first = False
    accepted_at = datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    receipt = {"version": 1, "request_id": request["request_id"], "request_key": request_key,
               "content_hash": content_hash, "note_id": note_id, "accepted_at": accepted_at, "phase": "reserved"}
    if os.path.lexists(receipt_path):
        try:
            private_file(receipt_path)
        except (OSError, UnsafePath):
            emit(result("unavailable", code="corrupt_receipt"), 4)
        receipt = load_json(receipt_path, "corrupt_receipt")
        validate_receipt(receipt, request["request_id"], request_key, content_hash, note_id)
        accepted_at = receipt["accepted_at"]
    else:
        try:
            first = atomic_new(receipt_path, json.dumps(receipt, separators=(",", ":"), sort_keys=True).encode("utf-8"))
        except (OSError, UnsafePath):
            emit(result("unavailable", code="unsafe_path"), 4)
        if not first:
            try:
                private_file(receipt_path)
            except (OSError, UnsafePath):
                emit(result("unavailable", code="corrupt_receipt"), 4)
            receipt = load_json(receipt_path, "corrupt_receipt")
            validate_receipt(receipt, request["request_id"], request_key, content_hash, note_id)
            accepted_at = receipt["accepted_at"]

    expected_note = note_bytes(note_id, accepted_at, request["request_id"], request_key, content_hash, request["text"])
    pending = os.path.join(inbox, f"{note_id}.note")
    handled_dir = os.path.join(inbox, "handled")
    try:
        private_dir(handled_dir, create=True)
    except (OSError, UnsafePath):
        emit(result("unavailable", code="unsafe_path"), 4)
    handled = os.path.join(handled_dir, f"{note_id}.note")
    if os.path.lexists(pending):
        verify_note(pending, expected_note)
    elif os.path.lexists(handled):
        verify_note(handled, expected_note)
    else:
        try:
            if not atomic_new(pending, expected_note):
                verify_note(pending, expected_note)
        except (OSError, UnsafePath):
            emit(result("unavailable", code="unsafe_path"), 4)
    if receipt["phase"] == "reserved":
        receipt["phase"] = "accepted"
        try:
            atomic_replace(receipt_path, json.dumps(receipt, separators=(",", ":"), sort_keys=True).encode("utf-8"))
        except (OSError, UnsafePath):
            emit(result("unavailable", code="corrupt_receipt"), 4)
    summary = request["text"].replace("\n", " ").replace("\r", " ").replace("\t", " ")[:100]
    print(json.dumps({"note_id": note_id, "first": first, "handled": os.path.exists(handled), "summary": summary}, separators=(",", ":")))


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("command", choices=("ensure", "notification", "prepare"))
    parser.add_argument("--root", required=True)
    parser.add_argument("--inbox", required=True)
    args = parser.parse_args()
    root = os.path.realpath(args.root)
    inbox = os.path.abspath(args.inbox)
    if args.command == "ensure":
        ensure_paths(root, inbox)
    elif args.command == "notification":
        ensure_notification(root, inbox)
    else:
        prepare(root, inbox)


if __name__ == "__main__":
    main()
