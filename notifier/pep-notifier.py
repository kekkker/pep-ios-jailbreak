#!/var/jb/usr/bin/python3
"""App-independent IMAP IDLE notifier for the jailbroken pEp iOS client."""

import argparse
import ctypes
import email
import email.header
import email.parser
import email.policy
import email.utils
import hashlib
import imaplib
import json
import logging
import os
import plistlib
import select
import socket
import ssl
import tempfile
import threading
import time
import uuid


APP_BUNDLE_ID = "software.pEp.mail"
CACHE_ROOT = "/var/mobile/Library/Caches/software.pep.notifier"
QUEUE_DIRECTORY = os.path.join(CACHE_ROOT, "queue")
STATE_PATH = os.path.join(CACHE_ROOT, "state.json")
DARWIN_NOTIFICATION = b"software.pep.notifier.new-bulletin"
IDLE_RENEW_SECONDS = 24 * 60
POLL_FALLBACK_SECONDS = 15
MAX_BACKOFF_SECONDS = 5 * 60

LOG = logging.getLogger("pep-notifier")
STATE_LOCK = threading.Lock()


def decode_header_value(value):
    if not value:
        return ""
    pieces = []
    for chunk, charset in email.header.decode_header(str(value)):
        if isinstance(chunk, bytes):
            encodings = [charset, "utf-8", "latin-1"]
            decoded = None
            for encoding in encodings:
                if not encoding:
                    continue
                try:
                    decoded = chunk.decode(encoding, errors="replace")
                    break
                except (LookupError, UnicodeError):
                    continue
            pieces.append(decoded if decoded is not None else chunk.decode("utf-8", "replace"))
        else:
            pieces.append(chunk)
    return "".join(pieces).strip()


def sender_title(raw_from):
    decoded = decode_header_value(raw_from)
    display_name, address = email.utils.parseaddr(decoded)
    display_name = decode_header_value(display_name)
    if display_name:
        return display_name
    if address:
        return address
    return decoded or "New email"


def load_state():
    try:
        with open(STATE_PATH, "r", encoding="utf-8") as handle:
            state = json.load(handle)
        return state if isinstance(state, dict) else {}
    except (OSError, ValueError):
        return {}


def save_state(state):
    os.makedirs(CACHE_ROOT, mode=0o700, exist_ok=True)
    fd, temporary_path = tempfile.mkstemp(prefix=".state-", dir=CACHE_ROOT)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(state, handle, separators=(",", ":"), sort_keys=True)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, STATE_PATH)
    except BaseException:
        try:
            os.unlink(temporary_path)
        except OSError:
            pass
        raise


def account_key(account):
    material = "{}\0{}".format(account["host"].lower(), account["login"].lower())
    return hashlib.sha256(material.encode("utf-8")).hexdigest()


def notify_post():
    candidates = (
        None,
        "/usr/lib/system/libsystem_notify.dylib",
        "/usr/lib/libSystem.B.dylib",
    )
    last_error = None
    for candidate in candidates:
        try:
            library = ctypes.CDLL(candidate) if candidate else ctypes.CDLL(None)
            function = library.notify_post
            function.argtypes = [ctypes.c_char_p]
            function.restype = ctypes.c_uint32
            result = int(function(DARWIN_NOTIFICATION))
            if result != 0:
                raise RuntimeError("notify_post returned {}".format(result))
            return
        except (AttributeError, OSError, RuntimeError) as error:
            last_error = error
    raise RuntimeError("Darwin notification unavailable: {}".format(last_error))


def queue_bulletin(title, subject):
    title = " ".join((title or "New email").split())[:180]
    subject = " ".join((subject or "(No subject)").split())[:500]
    os.makedirs(QUEUE_DIRECTORY, mode=0o700, exist_ok=True)
    token = "{}-{}".format(time.time_ns(), uuid.uuid4().hex)
    temporary = os.path.join(QUEUE_DIRECTORY, "." + token + ".tmp")
    final = os.path.join(QUEUE_DIRECTORY, token + ".plist")
    payload = {
        "title": title,
        "message": subject,
        "bundle_id": APP_BUNDLE_ID,
    }
    with open(temporary, "wb") as handle:
        os.chmod(temporary, 0o600)
        plistlib.dump(payload, handle, fmt=plistlib.FMT_BINARY)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, final)
    notify_post()


def response_number(client, name):
    response = client.response(name)
    if not response or not response[1]:
        return None
    values = response[1]
    for value in values:
        if isinstance(value, bytes):
            value = value.decode("ascii", "ignore")
        try:
            return int(str(value).strip())
        except (TypeError, ValueError):
            continue
    return None


def current_highest_uid(client):
    result, data = client.uid("search", None, "ALL")
    if result != "OK" or not data or not data[0]:
        return 0
    try:
        return int(data[0].split()[-1])
    except (ValueError, IndexError):
        return 0


def fetch_headers(client, uid):
    result, data = client.uid(
        "fetch",
        str(uid),
        "(UID BODY.PEEK[HEADER.FIELDS (FROM SUBJECT)])",
    )
    if result != "OK":
        raise RuntimeError("UID FETCH {} returned {}".format(uid, result))
    raw = b"".join(
        part[1]
        for part in data
        if isinstance(part, tuple) and len(part) == 2 and isinstance(part[1], bytes)
    )
    if not raw:
        raise RuntimeError("UID FETCH {} returned no headers".format(uid))
    message = email.parser.BytesParser(policy=email.policy.default).parsebytes(raw)
    title = sender_title(message.get("From"))
    subject = decode_header_value(message.get("Subject")) or "(No subject)"
    return title, subject


def scan_new_messages(client, key, state):
    with STATE_LOCK:
        account_state = state.setdefault(key, {})
        last_uid = int(account_state.get("last_uid", 0))
    result, data = client.uid("search", None, "UID", "{}:*".format(last_uid + 1))
    if result != "OK":
        raise RuntimeError("UID SEARCH returned {}".format(result))
    uids = []
    if data and data[0]:
        for raw_uid in data[0].split():
            try:
                uid = int(raw_uid)
            except ValueError:
                continue
            if uid > last_uid:
                uids.append(uid)

    for uid in sorted(set(uids)):
        title, subject = fetch_headers(client, uid)
        queue_bulletin(title, subject)
        with STATE_LOCK:
            state[key]["last_uid"] = uid
            save_state(state)
        LOG.info("notification queued account=%s uid=%d", key[:8], uid)


def initialize_state(client, key, state):
    uidvalidity = response_number(client, "UIDVALIDITY")
    uidnext = response_number(client, "UIDNEXT")
    with STATE_LOCK:
        account_state = state.setdefault(key, {})
        saved_validity = account_state.get("uidvalidity")
        if saved_validity is None or int(saved_validity) != int(uidvalidity or 0):
            initial_uid = (uidnext - 1) if uidnext and uidnext > 0 else current_highest_uid(client)
            account_state["last_uid"] = max(0, initial_uid)
            account_state["uidvalidity"] = int(uidvalidity or 0)
            save_state(state)
            LOG.info(
                "baseline initialized account=%s uid=%d",
                key[:8],
                account_state["last_uid"],
            )


def idle_until_event(client):
    tag = client._new_tag()  # imaplib has no public IDLE API before Python 3.14.
    client.send(tag + b" IDLE\r\n")
    continuation = client.readline()
    if not continuation.startswith(b"+"):
        raise RuntimeError("server rejected IDLE")

    changed = False
    deadline = time.monotonic() + IDLE_RENEW_SECONDS
    while time.monotonic() < deadline:
        wait = min(60.0, max(0.0, deadline - time.monotonic()))
        readable, _, _ = select.select([client.sock], [], [], wait)
        if not readable:
            continue
        line = client.readline()
        if not line:
            raise OSError("IMAP connection closed during IDLE")
        upper = line.upper()
        if b" EXISTS" in upper or b" RECENT" in upper:
            changed = True
            break

    client.send(b"DONE\r\n")
    while True:
        line = client.readline()
        if not line:
            raise OSError("IMAP connection closed after IDLE")
        if line.startswith(tag + b" "):
            if b" OK" not in line.upper():
                raise RuntimeError("IDLE completion failed")
            break
    return changed


def run_account(account, state):
    key = account_key(account)
    auth_method = (account.get("auth_method") or "").upper()
    if auth_method == "XOAUTH2":
        raise RuntimeError("XOAUTH2 accounts are not supported by this notifier yet")
    if int(account.get("transport", 1)) != 1:
        raise RuntimeError("only TLS IMAP accounts are supported")

    context = ssl.create_default_context()
    client = imaplib.IMAP4_SSL(
        account["host"],
        int(account.get("port", 993)),
        ssl_context=context,
        timeout=45,
    )
    try:
        client.login(account["login"], account["password"])
        result, _ = client.select("INBOX", readonly=True)
        if result != "OK":
            raise RuntimeError("could not select INBOX")
        initialize_state(client, key, state)
        capabilities = {
            capability.decode("ascii", "ignore").upper()
            if isinstance(capability, bytes)
            else str(capability).upper()
            for capability in client.capabilities
        }
        LOG.info(
            "connected account=%s mode=%s",
            key[:8],
            "IDLE" if "IDLE" in capabilities else "poll",
        )
        while True:
            if "IDLE" in capabilities:
                idle_until_event(client)
            else:
                time.sleep(POLL_FALLBACK_SECONDS)
                client.noop()
            scan_new_messages(client, key, state)
    finally:
        try:
            client.logout()
        except (imaplib.IMAP4.error, OSError):
            pass


def account_worker(account, state):
    key = account_key(account)[:8]
    backoff = 5
    while True:
        try:
            run_account(account, state)
            backoff = 5
        except (imaplib.IMAP4.error, OSError, socket.error, ssl.SSLError, RuntimeError) as error:
            LOG.warning(
                "account=%s disconnected: %s; retrying in %ds",
                key,
                str(error).replace("\n", " ")[:240],
                backoff,
            )
            time.sleep(backoff)
            backoff = min(MAX_BACKOFF_SECONDS, backoff * 2)


def read_credentials(fd):
    with os.fdopen(fd, "rb", closefd=True) as handle:
        payload = json.load(handle)
    accounts = payload.get("accounts") if isinstance(payload, dict) else None
    if not isinstance(accounts, list) or not accounts:
        raise ValueError("credential payload has no accounts")
    required = ("host", "port", "login", "password")
    for account in accounts:
        if not isinstance(account, dict) or not all(account.get(key) for key in required):
            raise ValueError("credential payload contains an incomplete account")
    return accounts


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--credentials-fd", type=int)
    parser.add_argument("--test-notification", action="store_true")
    arguments = parser.parse_args()
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    if arguments.test_notification:
        queue_bulletin("pEp notifier test", "Sender and subject banners are working")
        LOG.info("test notification queued")
        return 0
    if arguments.credentials_fd is None:
        parser.error("--credentials-fd is required")

    accounts = read_credentials(arguments.credentials_fd)
    state = load_state()
    LOG.info("starting account_count=%d", len(accounts))
    threads = []
    for account in accounts:
        thread = threading.Thread(
            target=account_worker,
            args=(account, state),
            daemon=False,
            name="imap-" + account_key(account)[:8],
        )
        thread.start()
        threads.append(thread)
    for thread in threads:
        thread.join()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
