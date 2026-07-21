"""
SES receipt-rule sync gate.

Returns CONTINUE or STOP_RULE_SET. Virus FAIL and non-allowlisted recipients
stop processing before S3 store / worker forward.
"""

from __future__ import annotations

import json
import logging
import os

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

secretsmanager = boto3.client("secretsmanager")

SECRET_ARN = os.environ["RUNTIME_CONFIG_SECRET_ARN"]

_config_cache: dict | None = None


def _config() -> dict:
    global _config_cache
    if _config_cache is None:
        raw = secretsmanager.get_secret_value(SecretId=SECRET_ARN)["SecretString"]
        _config_cache = json.loads(raw)
    return _config_cache


def _allowlist() -> set[str]:
    return {addr.strip().lower() for addr in _config().get("recipients") or [] if addr}


def _verdict(receipt: dict, name: str) -> str:
    block = receipt.get(name) or {}
    return str(block.get("status") or "GRAY").upper()


def handler(event, _context):
    """SES expects {\"disposition\": \"CONTINUE\"|\"STOP_RULE\"|\"STOP_RULE_SET\"}."""
    logger.info("Gate event keys: %s", list(event.keys()))

    records = event.get("Records") or [event]
    allow = _allowlist()
    if not allow:
        logger.error("Runtime config has empty recipients allowlist; stopping")
        return {"disposition": "STOP_RULE_SET"}

    for record in records:
        ses_block = record.get("ses") or event.get("ses") or {}
        receipt = ses_block.get("receipt") or {}
        mail = ses_block.get("mail") or {}

        recipients = [
            addr.strip().lower()
            for addr in (receipt.get("recipients") or mail.get("destination") or [])
            if addr
        ]
        if not recipients or not any(addr in allow for addr in recipients):
            logger.warning("No allowlisted recipient in %s; STOP_RULE_SET", recipients)
            return {"disposition": "STOP_RULE_SET"}

        if _verdict(receipt, "virusVerdict") == "FAIL":
            logger.warning("Virus FAIL; STOP_RULE_SET")
            return {"disposition": "STOP_RULE_SET"}

    return {"disposition": "CONTINUE"}
