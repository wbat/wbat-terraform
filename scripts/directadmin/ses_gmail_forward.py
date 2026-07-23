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


def _setup_logging() -> logging.Logger:
    handlers: list[logging.Handler] = []
    try:
        handlers.append(logging.FileHandler(LOG_PATH))
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


def _rate_ok(key: str, limit: int) -> bool:
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        hour = datetime.now(timezone.utc).strftime("%Y%m%d%H")
        path = STATE_DIR / f"rate-{key.replace('/', '_')}-{hour}.count"
        try:
            count = int(path.read_text().strip() or "0")
        except FileNotFoundError:
            count = 0
        except OSError:
            count = 0
        if count >= limit:
            return False
        path.write_text(str(count + 1))
        return True
    except OSError:
        logger.warning("Rate-limit state unwritable; allowing send")
        return True


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


def _build_forward_raw(original: email.message.Message, from_addr: str, gmail_dest: str) -> bytes:
    msg = email.message_from_bytes(original.as_bytes(), policy=email.policy.SMTP)
    original_from = msg.get("From", "unknown")
    _, original_from_email = parseaddr(original_from)
    display_name, _ = parseaddr(original_from)
    if not display_name:
        display_name = original_from_email or "Forwarded"

    for header in (
        "DKIM-Signature",
        "DomainKey-Signature",
        "Return-Path",
        "Sender",
        "Reply-To",
        "To",
        "From",
        "Message-ID",
    ):
        if header in msg:
            del msg[header]

    msg["From"] = formataddr((f"{display_name} via TellersTech", from_addr))
    msg["To"] = gmail_dest
    if original_from_email:
        msg["Reply-To"] = original_from
    msg["X-Original-From"] = original_from
    msg["X-Forwarded-To"] = gmail_dest
    msg["X-Forwarded-For"] = from_addr
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
        logger.warning("Message oversized (%s bytes); skip SES", len(raw))
        return False
    per_recip = int(cfg.get("rate_limit_per_recipient_per_hour") or 30)
    global_lim = int(cfg.get("rate_limit_global_per_hour") or 100)
    if not _rate_ok(f"r-{recipient}", per_recip) or not _rate_ok("global", global_lim):
        logger.warning("Rate limit exceeded for %s; skip SES", recipient)
        return False
    if not (mail_obj.get("From") and mail_obj.get("Date")):
        logger.warning("Missing From/Date; skip SES")
        return False
    if not _has_payload(mail_obj):
        logger.warning("Empty payload; skip SES")
        return False
    try:
        ses.send_raw_email(
            Source=recipient,
            Destinations=[gmail_dest],
            RawMessage={"Data": _build_forward_raw(mail_obj, recipient, gmail_dest)},
        )
        logger.info("Forwarded SES copy for %s", recipient)
        return True
    except ClientError:
        logger.exception("SES SendRawEmail failed")
        return False


def main(argv: list[str]) -> int:
    # Always return 0: non-zero makes Exim bounce even when Roundcube already has mail.
    raw = sys.stdin.buffer.read()
    if not raw:
        logger.warning("Empty stdin; skip")
        return 0

    try:
        cfg = _config()
    except ClientError:
        logger.exception("Failed to load runtime config")
        return 0

    allow = _allowlist(cfg)
    mail_obj = email.message_from_bytes(raw, policy=email.policy.default)
    recipient = _resolve_recipient(argv, mail_obj, allow)
    if not recipient:
        logger.error("Could not resolve recipient for SES forward")
        return 0

    gmail_dest = (cfg.get("gmail_destination") or "").strip()
    if recipient in allow and gmail_dest:
        _send_ses(mail_obj, raw, recipient, gmail_dest, cfg)
    elif recipient not in allow:
        logger.info("Recipient not in SES allowlist; skip SES (Roundcube via Exim)")
    else:
        logger.error("gmail_destination missing in runtime config")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
