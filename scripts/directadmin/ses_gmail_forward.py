#!/usr/bin/env python3
"""
DirectAdmin pipe forwarder → Gmail via SES (Roundcube via Exim).

Aliases must be pipe-only:

  localpart: "|/usr/local/bin/ses-gmail-forward.py"

Architecture (DirectAdmin / Exim):
  - Email Account exists → Exim virtual_mailbox (LMTP) delivers Roundcube copy
  - Forwarder pipe → this script → SES SendRawEmail → Gmail

This script must NOT call dovecot-lda. The pipe runs as user `mail`, and DA
Maildirs are mode 0700 owned by the DA user, so lda returns EX_TEMPFAIL (75)
and Exim treats a non-zero pipe exit as a permanent bounce — even after the
Roundcube copy already succeeded.

Do NOT forward to Gmail through the SES smart host (554 unverified From).
Do NOT change MX away from DirectAdmin.

Config: Secrets Manager tellerstech/ses-gmail-forward/runtime-config
Always exit 0 so Exim never bounces on SES/config failures (log instead).
Never write to stdout/stderr under Exim (treated as pipe failure).
"""

from __future__ import annotations

import email
import email.policy
import email.utils
import json
import logging
import os
import re
import sys
import time
from datetime import datetime, timezone
from email.utils import formataddr, parseaddr
from pathlib import Path

import boto3
from botocore.exceptions import ClientError

LOG_PATH = os.environ.get("SES_GMAIL_FORWARD_LOG", "/var/log/ses-gmail-forward.log")
SECRET_ID = os.environ.get(
    "SES_GMAIL_FORWARD_SECRET",
    "tellerstech/ses-gmail-forward/runtime-config",
)
STATE_DIR = Path(os.environ.get("SES_GMAIL_FORWARD_STATE", "/var/lib/ses-gmail-forward"))
AWS_REGION = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")

# Pipe-specific re-entry marker (do NOT use generic X-Forwarded-* — those are
# set by legitimate upstream forwards and would silently skip Gmail copies).
_PIPE_MARKER_HEADER = "X-Ses-Gmail-Forward"
_PIPE_MARKER_VALUE = "1"
_MAILER_DAEMON_RE = re.compile(
    r"(?i)^(mailer-daemon|postmaster|mail-daemon|majordomo)(@|$)",
)


def _setup_logging() -> logging.Logger:
    # A handler that cannot encode or write its record reports that on stderr, and Exim
    # reads anything on stderr as pipe failure. Neither a log line nor a log failure is
    # worth bouncing a delivered message over.
    logging.raiseExceptions = False
    handlers: list[logging.Handler] = []
    try:
        handlers.append(logging.FileHandler(LOG_PATH, encoding="utf-8"))
    except OSError:
        pass
    if sys.stderr.isatty():
        handlers.append(logging.StreamHandler(sys.stderr))
    if not handlers:
        handlers.append(logging.NullHandler())
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        handlers=handlers,
        force=True,
    )
    return logging.getLogger("ses-gmail-forward")


logger = _setup_logging()

secretsmanager = boto3.client("secretsmanager", region_name=AWS_REGION)
ses = boto3.client("ses", region_name=AWS_REGION)

_config_cache: dict | None = None
_config_loaded_at = 0.0


def _config() -> dict:
    global _config_cache, _config_loaded_at
    now = time.time()
    if _config_cache is None or (now - _config_loaded_at) > 60:
        raw = secretsmanager.get_secret_value(SecretId=SECRET_ID)["SecretString"]
        _config_cache = json.loads(raw)
        _config_loaded_at = now
    return _config_cache


def _allowlist(cfg: dict) -> set[str]:
    return {a.strip().lower() for a in (cfg.get("recipients") or []) if a}


def _log_skip(reason: str, recipient: str = "", **extra: str) -> None:
    parts = [f"skip_ses reason={reason}"]
    if recipient:
        parts.append(f"recipient={recipient}")
    for k, v in extra.items():
        if v:
            parts.append(f"{k}={v}")
    logger.warning(" ".join(parts))


def _addresses_from_headers(mail_obj: email.message.Message) -> list[str]:
    found: list[str] = []
    for header in (
        "Envelope-To",
        "X-Envelope-To",
        "Delivered-To",
        "X-Original-To",
        "X-Forwarded-To",
        "To",
        "Cc",
    ):
        for value in mail_obj.get_all(header) or []:
            for _, addr in email.utils.getaddresses([value]):
                if addr:
                    found.append(addr.strip().lower())
    return found


def _recipient_from_env() -> str | None:
    local = os.environ.get("LOCAL_PART") or os.environ.get("local_part")
    domain = os.environ.get("DOMAIN") or os.environ.get("domain")
    if local and domain:
        return f"{local}@{domain}".lower()
    return None


def _resolve_recipient(argv: list[str], mail_obj: email.message.Message, allow: set[str]) -> str | None:
    candidates: list[str] = []
    if len(argv) >= 2 and argv[1].strip():
        candidates.append(argv[1].strip().lower())
    env_recip = _recipient_from_env()
    if env_recip:
        candidates.append(env_recip)
    candidates.extend(_addresses_from_headers(mail_obj))

    for addr in candidates:
        if addr in allow:
            return addr
    for addr in candidates:
        if "@" in addr:
            return addr
    return None


def _addrs_in(mail_obj: email.message.Message, *headers: str) -> list[str]:
    out: list[str] = []
    for header in headers:
        for value in mail_obj.get_all(header) or []:
            for _, addr in email.utils.getaddresses([value]):
                if addr:
                    out.append(addr.strip().lower())
    return out


def _should_skip_forward(mail_obj: email.message.Message, gmail_dest: str) -> str | None:
    """Return skip reason, or None if the message may be forwarded to SES.

    Do not skip on Precedence / List-Unsubscribe / X-Auto-Response-Suppress alone —
    those are common on legitimate newsletters and list mail.
    """
    auto = (mail_obj.get("Auto-Submitted") or "").strip().lower()
    if auto and auto != "no":
        return "auto_submitted"

    marker = (mail_obj.get(_PIPE_MARKER_HEADER) or "").strip()
    if marker == _PIPE_MARKER_VALUE:
        return "pipe_reentry"

    gmail_dest_l = gmail_dest.strip().lower()
    for addr in _addrs_in(mail_obj, "From", "Sender", "Reply-To"):
        if addr == gmail_dest_l:
            return "from_gmail_dest"
        if _MAILER_DAEMON_RE.search(addr):
            return "mailer_daemon"

    return None


def _rate_path(key: str) -> Path:
    hour = datetime.now(timezone.utc).strftime("%Y%m%d%H")
    return STATE_DIR / f"rate-{key.replace('/', '_')}-{hour}.count"


def _rate_check(key: str, limit: int) -> bool:
    """True if under limit (does not increment). Fail-open if state unwritable."""
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        path = _rate_path(key)
        try:
            count = int(path.read_text().strip() or "0")
        except FileNotFoundError:
            count = 0
        except OSError:
            count = 0
        return count < limit
    except OSError:
        logger.warning("Rate-limit state unwritable; allowing send")
        return True


def _rate_increment(key: str) -> None:
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        path = _rate_path(key)
        try:
            count = int(path.read_text().strip() or "0")
        except FileNotFoundError:
            count = 0
        except OSError:
            count = 0
        path.write_text(str(count + 1))
    except OSError:
        logger.warning("Rate-limit state unwritable; could not increment")


def _has_payload(msg: email.message.Message) -> bool:
    if msg.is_multipart():
        for part in msg.walk():
            if part.get_content_maintype() == "multipart":
                continue
            if part.get_filename():
                return True
            payload = part.get_payload(decode=True)
            if payload and payload.strip():
                return True
        return False
    payload = msg.get_payload(decode=True)
    return bool(payload and payload.strip())


def _addr_pairs(values: list) -> list[tuple[str, str]]:
    """(display name, address) pairs across one header's values, in order."""
    pairs: list[tuple[str, str]] = []
    for value in values:
        for name, addr in email.utils.getaddresses([str(value)]):
            if addr:
                pairs.append((name, addr.strip()))
    return pairs


def _render_addr(name: str, addr: str) -> str | None:
    """RFC 5322 form of one address, or None when the address itself is not ASCII.

    An SMTPUTF8 address (RFC 6531) such as bjorn-with-an-umlaut@example.net has no
    representation in an ordinary address header, and formataddr raises rather than
    invent one. Letting that raise would exit the pipe nonzero, which Exim turns into
    a bounce of a message Roundcube has already accepted -- the one outcome this
    script exists to avoid. Callers leave these out of To/Cc and report them instead.
    """
    try:
        return formataddr((name, addr))
    except UnicodeEncodeError:
        return None


def _render_new(
    pairs: list[tuple[str, str]],
    seen: set[str],
    unencodable: list[str] | None = None,
) -> list[str]:
    """Render pairs whose address is not already in `seen`, adding each to `seen`."""
    out: list[str] = []
    for name, addr in pairs:
        low = addr.lower()
        if low in seen:
            continue
        seen.add(low)
        rendered = _render_addr(name, addr)
        if rendered is None:
            if unencodable is not None:
                unencodable.append(addr)
            continue
        out.append(rendered)
    return out


def _via_label(addr: str, labels: dict | None = None) -> str:
    """Display suffix for the forwarded From, keyed on the domain the mail arrived at.

    Gmail shows the display name and hides the address behind a click, so with several
    domains funnelling into one inbox this is the only thing that says which one a
    message came in on. The default is the domain itself, which is never wrong; a
    prettier house name is per-domain runtime config, because that is where the real
    domains live -- the same reason recipients are not in git.
    """
    domain = addr.rpartition("@")[2].strip().lower()
    if not domain:
        return "forwarded"
    if not isinstance(labels, dict):
        # Hand-edited JSON: a wrong shape here should cost a nicer display name, not
        # the forward itself.
        return domain
    overrides = {str(k).strip().lower(): str(v).strip() for k, v in labels.items()}
    return overrides.get(domain) or domain


def _original_addr_list(pairs: list[tuple[str, str]]) -> str:
    """Audit-trail form for X-Original-*, which unlike To/Cc can hold an SMTPUTF8
    address: those are unstructured headers, so a non-ASCII address survives there as
    an encoded word and the record of who the message went to stays complete."""
    return ", ".join(_render_addr(name, addr) or addr for name, addr in pairs)


def _build_forward_raw(
    original: email.message.Message,
    from_addr: str,
    gmail_dest: str,
    reply_to_all: bool = False,
    local_addrs: set[str] | None = None,
    via_labels: dict | None = None,
) -> bytes:
    msg = email.message_from_bytes(original.as_bytes(), policy=email.policy.SMTP)
    original_from = msg.get("From", "unknown")
    display_name, original_from_email = parseaddr(original_from)
    if not display_name:
        display_name = original_from_email or "Forwarded"

    to_pairs = _addr_pairs(msg.get_all("To") or [])
    cc_pairs = _addr_pairs(msg.get_all("Cc") or [])
    reply_to_pairs = _addr_pairs(msg.get_all("Reply-To") or [])

    alias = from_addr.lower()
    dest = gmail_dest.lower()
    # Every allowlisted address forwards into the same Gmail inbox, so any of them left
    # in a visible header would make one Reply-All arrive back here as another copy.
    local = {a.lower() for a in (local_addrs or set())} | {alias, dest}

    # Gmail builds Reply-All out of the headers it receives, so replacing To with the
    # Gmail address (as this used to) silently narrowed every reply to the sender and
    # dropped anyone else the message was addressed to. Delivery is the SES envelope
    # (Destinations= below), never these headers, so carrying the other recipients
    # through cannot send mail to any of them.
    seen = set(local)
    unencodable: list[str] = []
    kept_to = _render_new(to_pairs, seen, unencodable)
    kept_cc = _render_new(cc_pairs, seen, unencodable)
    if unencodable:
        # backslashreplace: a raw non-ASCII address in a log record can fail the
        # handler's own encode, and logging reports that on stderr -- which Exim reads
        # as pipe failure just like a traceback would.
        logger.warning(
            "Omitted %d non-ASCII (SMTPUTF8) recipient(s) from forwarded To/Cc: %s",
            len(unencodable),
            ", ".join(a.encode("ascii", "backslashreplace").decode("ascii") for a in unencodable),
        )

    # Substitute the Gmail address for the alias in whichever header carried it, so
    # "cc me" does not read as "to me" and Gmail still drops it from Reply-All.
    to_addrs = {addr.lower() for _, addr in to_pairs}
    if alias not in to_addrs and any(addr.lower() == alias for _, addr in cc_pairs):
        kept_cc.insert(0, gmail_dest)
    else:
        kept_to.insert(0, gmail_dest)

    # An explicit Reply-To is the sender's instruction and outranks their From, which
    # is the address to fall back to when they set none.
    reply_seen = {dest}
    reply_to = _render_new(reply_to_pairs or _addr_pairs([original_from]), reply_seen)
    if reply_to_all:
        reply_seen |= local
        reply_to += _render_new(to_pairs + cc_pairs, reply_seen)

    for header in (
        "DKIM-Signature",
        "DomainKey-Signature",
        "Return-Path",
        "Sender",
        "Reply-To",
        "To",
        "Cc",
        "From",
        "Message-ID",
    ):
        if header in msg:
            del msg[header]

    msg["From"] = formataddr((f"{display_name} via {_via_label(from_addr, via_labels)}", from_addr))
    if kept_to:
        msg["To"] = ", ".join(kept_to)
    if kept_cc:
        msg["Cc"] = ", ".join(kept_cc)
    if reply_to:
        msg["Reply-To"] = ", ".join(reply_to)
    msg["X-Original-From"] = original_from
    if to_pairs:
        msg["X-Original-To"] = _original_addr_list(to_pairs)
    if cc_pairs:
        msg["X-Original-Cc"] = _original_addr_list(cc_pairs)
    msg["X-Forwarded-To"] = gmail_dest
    msg["X-Forwarded-For"] = from_addr
    msg[_PIPE_MARKER_HEADER] = _PIPE_MARKER_VALUE
    return msg.as_bytes()


def _send_ses(
    mail_obj: email.message.Message,
    raw: bytes,
    recipient: str,
    gmail_dest: str,
    cfg: dict,
) -> bool:
    max_bytes = int(cfg.get("max_message_bytes") or 10 * 1024 * 1024)
    if len(raw) > max_bytes:
        _log_skip("oversized", recipient, bytes=str(len(raw)))
        return False
    per_recip = int(cfg.get("rate_limit_per_recipient_per_hour") or 30)
    global_lim = int(cfg.get("rate_limit_global_per_hour") or 100)
    if not _rate_check(f"r-{recipient}", per_recip) or not _rate_check("global", global_lim):
        _log_skip("rate_limit", recipient)
        return False
    if not (mail_obj.get("From") and mail_obj.get("Date")):
        _log_skip("missing_headers", recipient)
        return False
    if not _has_payload(mail_obj):
        _log_skip("empty_payload", recipient)
        return False
    try:
        ses.send_raw_email(
            Source=recipient,
            Destinations=[gmail_dest],
            RawMessage={
                "Data": _build_forward_raw(
                    mail_obj,
                    recipient,
                    gmail_dest,
                    reply_to_all=bool(cfg.get("reply_to_all")),
                    local_addrs=_allowlist(cfg),
                    via_labels=cfg.get("via_labels") or {},
                )
            },
        )
        _rate_increment(f"r-{recipient}")
        _rate_increment("global")
        logger.info("Forwarded SES copy for %s", recipient)
        return True
    except ClientError:
        logger.exception("SES SendRawEmail failed")
        _log_skip("ses_error", recipient)
        return False


def main(argv: list[str]) -> int:
    # Always return 0: non-zero makes Exim bounce even when Roundcube already has mail.
    raw = sys.stdin.buffer.read()
    if not raw:
        _log_skip("empty_stdin")
        return 0

    try:
        cfg = _config()
    except ClientError:
        logger.exception("Failed to load runtime config")
        _log_skip("config_error")
        return 0

    allow = _allowlist(cfg)
    mail_obj = email.message_from_bytes(raw, policy=email.policy.default)
    recipient = _resolve_recipient(argv, mail_obj, allow)
    if not recipient:
        logger.error("Could not resolve recipient for SES forward")
        _log_skip("no_recipient")
        return 0

    gmail_dest = (cfg.get("gmail_destination") or "").strip()
    if recipient not in allow:
        logger.info("Recipient not in SES allowlist; skip SES (Roundcube via Exim)")
        return 0
    if not gmail_dest:
        logger.error("gmail_destination missing in runtime config")
        _log_skip("missing_gmail_dest", recipient)
        return 0

    skip = _should_skip_forward(mail_obj, gmail_dest)
    if skip:
        _log_skip(skip, recipient)
        return 0

    _send_ses(mail_obj, raw, recipient, gmail_dest, cfg)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception:  # noqa: BLE001
        # Same reason main() returns 0 on every handled path, extended to the paths
        # nobody anticipated: a traceback exits nonzero and prints to stderr, and Exim
        # turns either into a bounce of a message Roundcube already has. ERROR is what
        # ses_gmail_forward_health.sh greps for, so this is quiet toward Exim and loud
        # toward us rather than silent.
        logger.exception("Unhandled error; exiting 0 so Exim does not bounce")
        sys.exit(0)
