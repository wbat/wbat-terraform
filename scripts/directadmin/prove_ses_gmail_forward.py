#!/usr/bin/env python3
"""Offline proof of the header rewrite in ses_gmail_forward.py. No AWS, no mail server:
boto3 is stubbed and SES is a recorder, so this runs anywhere python3 does.

The property under test is not "it forwards". It is that the forwarded copy still says
who the message was addressed to. Gmail composes Reply-All from the headers it receives,
so a rewrite that replaces To with the Gmail address -- which is what this script used to
do -- makes every reply go to the sender alone and silently drops the other recipients.
The person replying cannot see that anything is missing, which is what made the original
bug survive: Cc was left alone and worked, so only a message with two To addresses
exposed it.

The other half is the reason that fix is safe at all: SES delivers to the Destinations
envelope, not to these headers, so naming third parties in To/Cc must never send mail to
them. Case "envelope" is the one that would catch a regression turning a display header
back into a delivery instruction.

Usage (from repo root):
  ./scripts/directadmin/prove_ses_gmail_forward.py
"""

from __future__ import annotations

import email
import email.policy
import email.utils
import importlib.util
import os
import shutil
import sys
import tempfile
import types
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "directadmin" / "ses_gmail_forward.py"

SANDBOX = Path(tempfile.mkdtemp(prefix="prove-ses-gmail-"))
os.environ["SES_GMAIL_FORWARD_LOG"] = str(SANDBOX / "forward.log")
os.environ["SES_GMAIL_FORWARD_STATE"] = str(SANDBOX / "state")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

ALIAS = "brian@example.com"
GMAIL = "brian.personal@gmail.example"
SENDER = "alice@sender.example"
OTHER_TO = "bob@other.example"
OTHER_CC = "carol@third.example"


def _stub_aws() -> None:
    """The pipe imports boto3 and builds clients at module scope; CI has neither."""
    if "boto3" not in sys.modules:
        boto3 = types.ModuleType("boto3")
        boto3.client = lambda *a, **k: types.SimpleNamespace()
        sys.modules["boto3"] = boto3
    if "botocore.exceptions" not in sys.modules:
        botocore = types.ModuleType("botocore")
        exceptions = types.ModuleType("botocore.exceptions")

        class ClientError(Exception):
            pass

        exceptions.ClientError = ClientError
        botocore.exceptions = exceptions
        sys.modules["botocore"] = botocore
        sys.modules["botocore.exceptions"] = exceptions


def load(path: Path, name: str):
    _stub_aws()
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


passed = 0
failed = 0


def assert_that(what: str, cond: bool) -> None:
    global passed, failed
    if cond:
        print(f"  OK   {what}")
        passed += 1
    else:
        print(f"  FAIL {what}")
        failed += 1


def message(
    to: str = f"{ALIAS}, {OTHER_TO}",
    cc: str | None = None,
    reply_to: str | None = None,
    frm: str = f"Alice Sender <{SENDER}>",
) -> email.message.Message:
    lines = [f"From: {frm}", "Subject: quarterly numbers", "Date: Mon, 1 Sep 2025 09:00:00 -0400"]
    if to:
        lines.append(f"To: {to}")
    if cc:
        lines.append(f"Cc: {cc}")
    if reply_to:
        lines.append(f"Reply-To: {reply_to}")
    raw = ("\n".join(lines) + "\n\nSee attached.\n").encode()
    return email.message_from_bytes(raw, policy=email.policy.default)


def forward(
    mod,
    original=None,
    reply_to_all: bool = False,
    local_addrs: set[str] | None = None,
) -> email.message.Message:
    raw = mod._build_forward_raw(
        original if original is not None else message(),
        ALIAS,
        GMAIL,
        reply_to_all=reply_to_all,
        local_addrs=local_addrs,
    )
    return email.message_from_bytes(raw, policy=email.policy.default)


def addrs(msg: email.message.Message, header: str) -> list[str]:
    return [a.lower() for a in _addr_list(msg, header)]


def _addr_list(msg: email.message.Message, header: str) -> list[str]:
    out = []
    for value in msg.get_all(header) or []:
        for _, addr in email.utils.getaddresses([str(value)]):
            if addr:
                out.append(addr)
    return out


mod = load(SCRIPT, "ses_gmail_forward_under_test")

print("two To addresses (the reported bug)")
out = forward(mod)
assert_that("the other To recipient survives the rewrite", OTHER_TO in addrs(out, "To"))
assert_that("Gmail is addressed so the copy still reads as mail to you", GMAIL in addrs(out, "To"))
assert_that("the alias is not left in To as a second copy of you", ALIAS not in addrs(out, "To"))
assert_that("Reply-To is the original sender", addrs(out, "Reply-To") == [SENDER])
assert_that(
    "a plain Reply does not reach the other recipients by default",
    OTHER_TO not in addrs(out, "Reply-To"),
)

print("\nCc (worked before, must keep working)")
out = forward(mod, message(cc=OTHER_CC))
assert_that("Cc survives", addrs(out, "Cc") == [OTHER_CC])
assert_that("both other recipients are visible to Reply-All", OTHER_TO in addrs(out, "To"))

print("\nalias placement")
out = forward(mod, message(to=OTHER_TO, cc=ALIAS))
assert_that("a Cc'd alias becomes a Cc'd Gmail, not a To", GMAIL in addrs(out, "Cc"))
assert_that("Cc'd alias is not promoted into To", GMAIL not in addrs(out, "To"))
assert_that("the real To recipient stays in To", addrs(out, "To") == [OTHER_TO])
out = forward(mod, message(to=f"{ALIAS}, {OTHER_TO}", cc=ALIAS))
assert_that(
    "an alias on both To and Cc yields exactly one Gmail address",
    (addrs(out, "To") + addrs(out, "Cc")).count(GMAIL) == 1,
)
out = forward(mod, message(to=f"{ALIAS}, {GMAIL}"))
assert_that(
    "an already-present Gmail address is not duplicated",
    addrs(out, "To").count(GMAIL) == 1,
)
out = forward(mod, message(to=""))
assert_that("an envelope-only delivery still addresses Gmail", addrs(out, "To") == [GMAIL])

print("\nyour other allowlisted aliases (a Reply-All to one lands back in this pipe)")
sibling = "info@example.com"
out = forward(mod, message(to=f"{ALIAS}, {sibling}, {OTHER_TO}"), local_addrs={ALIAS, sibling})
assert_that("a second alias of yours is not left where Reply-All would hit it", sibling not in addrs(out, "To"))
assert_that("the unrelated recipient is still kept", OTHER_TO in addrs(out, "To"))
assert_that(
    "and X-Original-To still records that it went to both of your addresses",
    sibling in addrs(out, "X-Original-To") and ALIAS in addrs(out, "X-Original-To"),
)
out = forward(mod, message(to=f"{ALIAS}, {sibling}"), reply_to_all=True, local_addrs={ALIAS, sibling})
assert_that("reply_to_all does not aim a reply at your other alias", sibling not in addrs(out, "Reply-To"))

print("\nquoting (a mangled header is a silently wrong recipient list)")
out = forward(mod, message(to=f'{ALIAS}, "Other, Bob" <{OTHER_TO}>'))
assert_that("a comma inside a display name does not split into two recipients", addrs(out, "To") == [GMAIL, OTHER_TO])
assert_that("the display name survives", "Other, Bob" in str(out["To"]))
try:
    out = forward(mod, message(to=f"{ALIAS}, =?utf-8?q?Bj=C3=B6rn?= <{OTHER_TO}>"))
    out.as_bytes().decode("ascii")
    ascii_clean = True
except (UnicodeError, ValueError):
    ascii_clean = False
assert_that("a non-ASCII display name still serializes as 7-bit ASCII", ascii_clean)
assert_that("and keeps its address", ascii_clean and OTHER_TO in addrs(out, "To"))

print("\nReply-To")
out = forward(mod, message(reply_to="Alice Team <team@sender.example>"))
assert_that(
    "a sender-set Reply-To outranks their From",
    addrs(out, "Reply-To") == ["team@sender.example"],
)
out = forward(mod, message(cc=OTHER_CC), reply_to_all=True)
reply_to = addrs(out, "Reply-To")
assert_that("reply_to_all keeps the sender first", reply_to[0] == SENDER)
assert_that("reply_to_all adds the other To recipient", OTHER_TO in reply_to)
assert_that("reply_to_all adds the Cc recipient", OTHER_CC in reply_to)
assert_that("reply_to_all never aims a reply back at the alias", ALIAS not in reply_to)
assert_that("reply_to_all never aims a reply at your own Gmail", GMAIL not in reply_to)

print("\nidentity and provenance")
out = forward(mod, message(cc=OTHER_CC))
assert_that(
    "From is the SES-verified alias, or SES rejects the send",
    addrs(out, "From") == [ALIAS],
)
assert_that("the sender's name is still shown", "Alice Sender via TellersTech" in out["From"])
assert_that("X-Original-From records the real sender", SENDER in out["X-Original-From"])
assert_that(
    "X-Original-To records the untouched original recipients",
    sorted(addrs(out, "X-Original-To")) == sorted([ALIAS, OTHER_TO]),
)
assert_that("X-Original-Cc records the untouched original Cc", addrs(out, "X-Original-Cc") == [OTHER_CC])
for header in ("DKIM-Signature", "Return-Path", "Sender"):
    signed = message()
    signed[header] = "v=1; d=sender.example" if header == "DKIM-Signature" else SENDER
    assert_that(f"{header} is stripped so Gmail does not judge us by it", header not in forward(mod, signed))

print("\nloop guard")
out = forward(mod)
assert_that("the marker header is set", out[mod._PIPE_MARKER_HEADER] == mod._PIPE_MARKER_VALUE)
assert_that(
    "a forwarded copy fed back into the pipe skips as pipe_reentry",
    mod._should_skip_forward(out, GMAIL) == "pipe_reentry",
)

print("\nbody")
multipart = email.message_from_bytes(
    (
        f"From: Alice Sender <{SENDER}>\n"
        f"To: {ALIAS}, {OTHER_TO}\n"
        "Subject: with attachment\n"
        "Date: Mon, 1 Sep 2025 09:00:00 -0400\n"
        'Content-Type: multipart/mixed; boundary="b1"\n'
        "\n"
        "--b1\n"
        "Content-Type: text/plain\n"
        "\n"
        "body text\n"
        "--b1\n"
        'Content-Type: text/csv; name="q3.csv"\n'
        'Content-Disposition: attachment; filename="q3.csv"\n'
        "\n"
        "a,b\n"
        "--b1--\n"
    ).encode(),
    policy=email.policy.default,
)
out = forward(mod, multipart)
assert_that("multipart structure is preserved", out.is_multipart())
assert_that(
    "the attachment is preserved",
    any(part.get_filename() == "q3.csv" for part in out.walk()),
)
assert_that("the body text is preserved", "body text" in out.as_string())

print("\nenvelope (the header change must not become a delivery instruction)")


class SesRecorder:
    def __init__(self) -> None:
        self.calls: list[dict] = []

    def send_raw_email(self, **kwargs):
        self.calls.append(kwargs)
        return {"MessageId": "proof"}


recorder = SesRecorder()
mod.ses = recorder
cfg = {"rate_limit_per_recipient_per_hour": 30, "rate_limit_global_per_hour": 100}
original = message(cc=OTHER_CC)
sent = mod._send_ses(original, original.as_bytes(), ALIAS, GMAIL, cfg)
assert_that("the send is attempted", sent and len(recorder.calls) == 1)
call = recorder.calls[-1] if recorder.calls else {}
assert_that("SES delivers only to Gmail", call.get("Destinations") == [GMAIL])
assert_that("SES sends from the verified alias", call.get("Source") == ALIAS)
delivered = email.message_from_bytes(call.get("RawMessage", {}).get("Data", b""), policy=email.policy.default)
assert_that(
    "third parties are named in the headers of that same message",
    OTHER_TO in addrs(delivered, "To") and OTHER_CC in addrs(delivered, "Cc"),
)

print("\nnegative value: the To assertion is load-bearing")
mutant_path = SANDBOX / "mutant.py"
source = SCRIPT.read_text()
needle = "    kept_to = _render_new(to_pairs, seen)\n"
assert_that("the mutation target still exists in the script", needle in source)
mutant_path.write_text(source.replace(needle, "    kept_to = []\n"))
mutant = load(mutant_path, "ses_gmail_forward_mutant")
assert_that("the mutant differs from the original", mutant_path.read_text() != source)
mutated = forward(mutant)
assert_that(
    "dropping the other To recipients is what this proof would catch",
    OTHER_TO not in addrs(mutated, "To"),
)
assert_that(
    "and the mutant still looks fine to a reader of the Gmail copy",
    addrs(mutated, "To") == [GMAIL],
)

shutil.rmtree(SANDBOX, ignore_errors=True)
print()
print(f"passed {passed}, failed {failed}")
sys.exit(1 if failed else 0)
