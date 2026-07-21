"""
SES inbound worker: validate, rate-limit, forward to Gmail, inject Roundcube copy.

Triggered by SQS messages from S3 ObjectCreated notifications after SES stores
raw MIME under inbound/<recipient>/<messageId>.
"""

from __future__ import annotations

import email
import email.policy
import json
import logging
import os
import smtplib
import time
import urllib.parse
from datetime import datetime, timezone
from email.utils import formataddr, parseaddr

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")
ses = boto3.client("ses")
secretsmanager = boto3.client("secretsmanager")
dynamodb = boto3.resource("dynamodb")
cloudwatch = boto3.client("cloudwatch")

SECRET_ARN = os.environ["RUNTIME_CONFIG_SECRET_ARN"]
INBOUND_PREFIX = os.environ.get("INBOUND_PREFIX", "inbound/")
QUARANTINE_PREFIX = os.environ.get("QUARANTINE_PREFIX", "quarantine/")
TABLE_NAME = os.environ["LIMITS_TABLE_NAME"]
INBOUND_BUCKET = os.environ["INBOUND_BUCKET"]
MAX_BYTES = int(os.environ.get("MAX_MESSAGE_BYTES", str(10 * 1024 * 1024)))
RATE_PER_RECIPIENT = int(os.environ.get("RATE_LIMIT_PER_RECIPIENT", "30"))
RATE_GLOBAL = int(os.environ.get("RATE_LIMIT_GLOBAL", "100"))
METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "TellersTech/SESInbound")

_config_cache: dict | None = None
_table = None


def _config() -> dict:
    global _config_cache
    if _config_cache is None:
        raw = secretsmanager.get_secret_value(SecretId=SECRET_ARN)["SecretString"]
        _config_cache = json.loads(raw)
    return _config_cache


def _table_resource():
    global _table
    if _table is None:
        _table = dynamodb.Table(TABLE_NAME)
    return _table


def _allowlist() -> set[str]:
    return {addr.strip().lower() for addr in _config().get("recipients") or [] if addr}


def _put_metric(name: str, value: float = 1.0, unit: str = "Count") -> None:
    try:
        cloudwatch.put_metric_data(
            Namespace=METRIC_NAMESPACE,
            MetricData=[{"MetricName": name, "Value": value, "Unit": unit}],
        )
    except Exception:  # noqa: BLE001
        logger.exception("Failed to put metric %s", name)


def _recipient_from_key(key: str) -> str | None:
    if not key.startswith(INBOUND_PREFIX):
        return None
    rest = key[len(INBOUND_PREFIX) :]
    recipient = rest.split("/", 1)[0].strip().lower()
    if recipient in _allowlist():
        return recipient
    return None


def _message_id_from_key(key: str) -> str:
    return key.rstrip("/").rsplit("/", 1)[-1]


def _header(msg: email.message.Message, name: str, default: str = "") -> str:
    return str(msg.get(name) or default).strip()


def _verdict_fail(msg: email.message.Message, header_name: str) -> bool:
    return _header(msg, header_name).upper() == "FAIL"


def _auth_all_fail(msg: email.message.Message) -> bool:
    spf = _header(msg, "X-SES-SPF-Verdict").upper()
    dkim = _header(msg, "X-SES-DKIM-Verdict").upper()
    dmarc = _header(msg, "X-SES-DMARC-Verdict").upper()
    # Treat missing as GRAY (not fail). Quarantine only when every present check is FAIL
    # and at least one FAIL exists; plan: SPF/DKIM/DMARC all FAIL.
    statuses = [s for s in (spf, dkim, dmarc) if s]
    if len(statuses) < 3:
        return False
    return all(s == "FAIL" for s in statuses)


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


def _claim_idempotency(message_id: str) -> bool:
    """Return True if this is the first time we process message_id."""
    ttl = int(time.time()) + 7 * 24 * 3600
    try:
        _table_resource().put_item(
            Item={
                "pk": f"IDEM#{message_id}",
                "sk": "v1",
                "ttl": ttl,
                "created_at": datetime.now(timezone.utc).isoformat(),
            },
            ConditionExpression="attribute_not_exists(pk)",
        )
        return True
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False
        raise


def _release_idempotency(message_id: str) -> None:
    """Allow SQS retries after a failed forward attempt."""
    try:
        _table_resource().delete_item(Key={"pk": f"IDEM#{message_id}", "sk": "v1"})
    except Exception:  # noqa: BLE001
        logger.exception("Failed to release idempotency for %s", message_id)


def _increment_rate(key: str, limit: int) -> bool:
    """
    Increment hourly counter. Return True if still within limit after increment.
    """
    hour = datetime.now(timezone.utc).strftime("%Y%m%d%H")
    pk = f"RATE#{key}#{hour}"
    ttl = int(time.time()) + 2 * 3600
    try:
        resp = _table_resource().update_item(
            Key={"pk": pk, "sk": "count"},
            UpdateExpression="ADD #c :one SET #ttl = :ttl",
            ExpressionAttributeNames={"#c": "count", "#ttl": "ttl"},
            ExpressionAttributeValues={":one": 1, ":ttl": ttl, ":limit": limit},
            ConditionExpression="attribute_not_exists(#c) OR #c < :limit",
            ReturnValues="UPDATED_NEW",
        )
        logger.info("Rate %s => %s", pk, resp.get("Attributes"))
        return True
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False
        raise


def _quarantine(bucket: str, key: str, reason: str) -> None:
    dest_key = f"{QUARANTINE_PREFIX}{key[len(INBOUND_PREFIX):]}" if key.startswith(INBOUND_PREFIX) else f"{QUARANTINE_PREFIX}{key}"
    s3.copy_object(
        Bucket=bucket,
        CopySource={"Bucket": bucket, "Key": key},
        Key=dest_key,
        MetadataDirective="REPLACE",
        Metadata={"quarantine-reason": reason[:256]},
    )
    logger.warning("Quarantined s3://%s/%s reason=%s", bucket, dest_key, reason)
    _put_metric("Quarantined")


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


def _send_to_gmail(raw: bytes, from_addr: str, gmail_dest: str) -> None:
    ses.send_raw_email(
        Source=from_addr,
        Destinations=[gmail_dest],
        RawMessage={"Data": raw},
    )
    logger.info("Forwarded to Gmail as %s", from_addr)
    _put_metric("ForwardedToGmail")


def _deliver_local(raw_original: bytes, recipient: str) -> None:
    smtp_cfg = (_config().get("smtp") or {})
    host = smtp_cfg.get("host")
    port = int(smtp_cfg.get("port") or 587)
    password = (smtp_cfg.get("mailboxes") or {}).get(recipient)
    if not host or not password:
        raise RuntimeError("SMTP host/password missing in runtime config")

    with smtplib.SMTP(host, port, timeout=30) as smtp:
        smtp.ehlo()
        smtp.starttls()
        smtp.ehlo()
        smtp.login(recipient, password)
        smtp.sendmail(recipient, [recipient], raw_original)

    logger.info("Delivered Roundcube copy for recipient via %s:%s", host, port)
    _put_metric("DeliveredLocal")


def _process(bucket: str, key: str) -> None:
    recipient = _recipient_from_key(key)
    if not recipient:
        logger.warning("Skipping non-allowlisted key %s", key)
        return

    message_id = _message_id_from_key(key)
    if not _claim_idempotency(message_id):
        logger.info("Duplicate message_id %s; skipping", message_id)
        _put_metric("DuplicateSkipped")
        return

    try:
        head = s3.head_object(Bucket=bucket, Key=key)
        size = int(head.get("ContentLength") or 0)
        if size > MAX_BYTES:
            _quarantine(bucket, key, "oversized")
            _put_metric("Oversized")
            return

        raw = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
        mail_obj = email.message_from_bytes(raw, policy=email.policy.default)

        if _verdict_fail(mail_obj, "X-SES-Virus-Verdict"):
            _quarantine(bucket, key, "virus")
            return

        if _verdict_fail(mail_obj, "X-SES-Spam-Verdict") or _auth_all_fail(mail_obj):
            _quarantine(bucket, key, "spam_or_auth_fail")
            return

        if not _header(mail_obj, "From") or not _header(mail_obj, "Date"):
            _quarantine(bucket, key, "missing_from_or_date")
            return

        if not _has_payload(mail_obj):
            _quarantine(bucket, key, "empty_payload")
            return

        if not _increment_rate(f"recipient#{recipient}", RATE_PER_RECIPIENT):
            _quarantine(bucket, key, "flood_recipient")
            _put_metric("FloodSuppressed")
            return

        if not _increment_rate("global", RATE_GLOBAL):
            _quarantine(bucket, key, "flood_global")
            _put_metric("FloodSuppressed")
            return

        gmail_dest = (_config().get("gmail_destination") or "").strip()
        if not gmail_dest:
            raise RuntimeError("gmail_destination missing in runtime config")

        errors: list[str] = []
        try:
            _send_to_gmail(_build_forward_raw(mail_obj, recipient, gmail_dest), recipient, gmail_dest)
        except Exception as exc:  # noqa: BLE001
            logger.exception("Gmail forward failed")
            errors.append(f"gmail:{exc}")

        try:
            _deliver_local(raw, recipient)
        except Exception as exc:  # noqa: BLE001
            logger.exception("Local delivery failed")
            errors.append(f"local:{exc}")

        if errors:
            raise RuntimeError("; ".join(errors))
    except Exception:
        _release_idempotency(message_id)
        raise


def handler(event, _context):
    for record in event.get("Records", []):
        body = record.get("body") or ""
        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            logger.error("Invalid SQS body")
            raise

        # S3 event notification wrapped in SQS
        for s3_record in payload.get("Records", []):
            bucket = s3_record["s3"]["bucket"]["name"]
            key = urllib.parse.unquote_plus(s3_record["s3"]["object"]["key"])
            if key.startswith(QUARANTINE_PREFIX):
                continue
            logger.info("Processing s3://%s/%s", bucket, key)
            _process(bucket, key)

    return {"ok": True}
