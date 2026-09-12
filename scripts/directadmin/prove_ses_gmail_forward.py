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
import json
import os
import shutil
import subprocess
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
# An SMTPUTF8 address (RFC 6531). formataddr() refuses to render one, so it is the
# shape of recipient that can turn the header rewrite into a bounce.
UTF8_TO = "bj\u00f6rn@other.example"
UTF8_HEADER = f"=?utf-8?q?Bj=C3=B6rn?= <{UTF8_TO}>"

PYLIB = SANDBOX / "pylib"
FAKE_BOTO3 = '''
import os

class _Secrets:
    def get_secret_value(self, SecretId=None):
        return {"SecretString": os.environ["FAKE_SES_CONFIG"]}

class _Ses:
    def send_raw_email(self, **kwargs):
        if os.environ.get("FAKE_SES_MODE") == "boom":
            raise ValueError("unexpected SDK failure that is not a ClientError")
        with open(os.environ["FAKE_SES_OUT"], "ab") as handle:
            handle.write(kwargs["RawMessage"]["Data"])
        return {"MessageId": "proof"}

def client(name, **kwargs):
    return _Secrets() if name == "secretsmanager" else _Ses()
'''


def run_pipe(
    raw: bytes,
    mode: str = "ok",
    recipient: str = ALIAS,
    script: Path = SCRIPT,
    recipients: list[str] | None = None,
) -> dict:
    """Run the real script the way Exim does: argv recipient, message on stdin.

    boto3 is a fake module on PYTHONPATH rather than a stub inside this process, so the
    exit code and the streams are the genuine article -- which is the only way to assert
    the property Exim actually cares about.
    """
    (PYLIB / "botocore").mkdir(parents=True, exist_ok=True)
    (PYLIB / "boto3.py").write_text(FAKE_BOTO3)
    (PYLIB / "botocore" / "__init__.py").write_text("")
    (PYLIB / "botocore" / "exceptions.py").write_text("class ClientError(Exception):\n    pass\n")

    sent = SANDBOX / "pipe-sent.eml"
    log = SANDBOX / "pipe.log"
    for path in (sent, log):
        path.unlink(missing_ok=True)
    env = dict(os.environ)
    env.update(
        {
            "PYTHONPATH": str(PYLIB),
            "SES_GMAIL_FORWARD_LOG": str(log),
            "SES_GMAIL_FORWARD_STATE": str(SANDBOX / "pipe-state"),
            "FAKE_SES_OUT": str(sent),
            "FAKE_SES_MODE": mode,
            "FAKE_SES_CONFIG": json.dumps(
                {
                    "gmail_destination": GMAIL,
                    "recipients": recipients if recipients is not None else [ALIAS],
                    "via_labels": {"example.com": "HouseName"},
                }
            ),
        }
    )
    proc = subprocess.run(
        [sys.executable, str(script), recipient],
        input=raw,
        env=env,
        capture_output=True,
        check=False,
    )
    return {
        "code": proc.returncode,
        "stdout": proc.stdout,
        "stderr": proc.stderr,
        "sent": sent.read_bytes() if sent.exists() else b"",
        "log": log.read_text() if log.exists() else "",
    }


def raw_message(to: str) -> bytes:
    return (
        f"From: Alice Sender <{SENDER}>\n"
        f"To: {to}\n"
        "Subject: quarterly numbers\n"
        "Date: Mon, 1 Sep 2025 09:00:00 -0400\n"
        "\n"
        "See attached.\n"
    ).encode()


def is_ascii(raw: bytes) -> bool:
    try:
        raw.decode("ascii")
        return True
    except UnicodeDecodeError:
        return False


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
    via_labels: dict | None = None,
    alias: str = ALIAS,
) -> email.message.Message:
    raw = mod._build_forward_raw(
        original if original is not None else message(),
        alias,
        GMAIL,
        reply_to_all=reply_to_all,
        local_addrs=local_addrs,
        via_labels=via_labels,
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

print("\nSMTPUTF8 recipients (formataddr refuses these, and a raise here is a bounce)")
out = forward(mod, message(to=f"{ALIAS}, {UTF8_HEADER}, {OTHER_TO}"))
assert_that("one unrenderable address does not cost the renderable ones", addrs(out, "To") == [GMAIL, OTHER_TO])
assert_that("it is kept out of To, which has to stay ASCII", UTF8_TO not in addrs(out, "To"))
assert_that("but X-Original-To still records it", UTF8_TO in addrs(out, "X-Original-To"))
assert_that("the copy handed to SES is 7-bit clean", is_ascii(out.as_bytes()))
out = forward(mod, message(to=OTHER_TO, cc=f"{ALIAS}, {UTF8_HEADER}"))
assert_that("the same holds on Cc", GMAIL in addrs(out, "Cc") and UTF8_TO not in addrs(out, "Cc"))
assert_that("and Cc's copy is recorded too", UTF8_TO in addrs(out, "X-Original-Cc"))

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
assert_that("the sender's name is still shown", "Alice Sender via " in out["From"])
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

print("\nvia label (which of your domains a message came in on)")
second = "brian@second.example"
assert_that(
    "the default label is the domain the mail arrived at",
    "via example.com" in str(forward(mod)["From"]),
)
assert_that(
    "a different alias domain gets a different label, unconfigured",
    "via second.example" in str(forward(mod, alias=second)["From"]),
)
labels = {"example.com": "HouseName", "SECOND.Example": "SecondName"}
assert_that(
    "a configured label replaces the domain",
    "via HouseName" in str(forward(mod, via_labels=labels)["From"]),
)
assert_that(
    "the domain key is matched case-insensitively",
    "via SecondName" in str(forward(mod, alias=second, via_labels=labels)["From"]),
)
assert_that(
    "an unlisted domain still falls back to itself rather than another domain's name",
    "via third.example" in str(forward(mod, alias="brian@third.example", via_labels=labels)["From"]),
)
assert_that(
    "the label never changes the address SES has to verify",
    addrs(forward(mod, alias=second, via_labels=labels), "From") == [second],
)
for broken in ("not-a-map", ["a"], None):
    assert_that(
        f"config shaped {type(broken).__name__} costs the label, not the forward",
        "via example.com" in str(forward(mod, via_labels=broken)["From"]),
    )
assert_that(
    "a non-ASCII label still leaves the message 7-bit clean",
    is_ascii(forward(mod, via_labels={"example.com": "Br\u00fccke"}).as_bytes()),
)

print("\nthe scanning server's spam verdict (present per-domain, so it made copies differ)")
# Reproduces what DirectAdmin/SpamAssassin prepends on a domain with scanning enabled,
# folded the way it actually arrives, including the placeholder that never got substituted.
scanned = email.message_from_bytes(
    (
        "X-Spam-Score: 0.9 (/)\n"
        "X-Spam-Bar: /\n"
        "X-Spam-Status: No, score=0.9\n"
        'X-Spam-Report: Spam detection software, running on the system "mail.example.com",\n'
        "  has NOT identified this incoming email as spam.\n"
        "  If you have any questions, see @@CONTACT_ADDRESS@@ for details.\n"
        "  1.0 HTML_IMAGE_ONLY_16   BODY: HTML: images with 1200-1600 bytes of words\n"
        f"From: Alice Sender <{SENDER}>\n"
        f"To: {ALIAS}, {OTHER_TO}\n"
        "Subject: quarterly numbers\n"
        "Date: Mon, 1 Sep 2025 09:00:00 -0400\n"
        "\n"
        "See attached.\n"
    ).encode(),
    policy=email.policy.default,
)
assert_that(
    "the fixture really does carry a spam verdict in the first place",
    len([h for h in scanned.keys() if h.lower().startswith("x-spam-")]) == 4,
)
out = forward(mod, scanned)
assert_that(
    "no X-Spam-* header reaches Gmail",
    [h for h in out.keys() if h.lower().startswith("x-spam-")] == [],
)
assert_that(
    "the scanning host is not disclosed to the recipient",
    "mail.example.com" not in out.as_string(),
)
assert_that(
    "nor is the unsubstituted contact placeholder",
    "@@CONTACT_ADDRESS@@" not in out.as_string(),
)
assert_that(
    "a scanned message forwards the same recipients as an unscanned one",
    addrs(out, "To") == addrs(forward(mod), "To"),
)
assert_that(
    "and the same Reply-To, so a scanned domain replies like any other",
    addrs(out, "Reply-To") == addrs(forward(mod), "Reply-To"),
)
scanned_headers = [h for h in out.keys() if h.lower() != "subject"]
plain_headers = [h for h in forward(mod).keys() if h.lower() != "subject"]
assert_that(
    "the two copies carry the same set of headers, which is the consistency being fixed",
    sorted(scanned_headers) == sorted(plain_headers),
)
assert_that("the body still survives the strip", "See attached." in out.as_string())

print("\nrate-limit counter across uids (Exim runs this pipe as more than one user)")
# A 0644 counter owned by another uid cannot be reopened for writing. Owning it and
# dropping write permission reproduces that exactly, without needing a second account.
rate_dir = Path(mod.STATE_DIR)
rate_dir.mkdir(parents=True, exist_ok=True)
counter = mod._rate_path("r-cross-uid")
counter.write_text("7")
os.chmod(counter, 0o444)
privileged = os.geteuid() == 0
mod._rate_increment("r-cross-uid")
if privileged:
    print("  SKIP running as root, which ignores file permissions; CI runs unprivileged")
else:
    assert_that("a counter another uid owns still advances", counter.read_text().strip() == "8")
    assert_that(
        "and is left writable so the next uid does not have to do this again",
        counter.stat().st_mode & 0o666 == 0o666,
    )
assert_that(
    "no temp files are left behind in the state dir",
    not list(rate_dir.glob("*.tmp")),
)
fresh = mod._rate_path("r-brand-new")
fresh.unlink(missing_ok=True)
mod._rate_increment("r-brand-new")
assert_that("a first-time counter still starts at 1", fresh.read_text().strip() == "1")
assert_that(
    "the limit is still enforced once the counter is at it",
    mod._rate_check("r-cross-uid", 8) is False and mod._rate_check("r-cross-uid", 99) is True,
)

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

print("\nthe pipe itself (a nonzero exit or a byte on stderr is an Exim bounce)")
run = run_pipe(raw_message(f"{ALIAS}, {OTHER_TO}"))
assert_that("a normal message exits 0", run["code"] == 0)
assert_that("and writes nothing to stdout or stderr", run["stdout"] == b"" and run["stderr"] == b"")
assert_that("and the other To recipient reaches Gmail", OTHER_TO.encode() in run["sent"])
assert_that(
    "the via label really is read from the runtime config, not just the function arg",
    b"via HouseName" in run["sent"],
)
run = run_pipe(raw_message(f"{ALIAS}, {UTF8_HEADER}, {OTHER_TO}"))
assert_that("an SMTPUTF8 recipient does not bounce the delivery", run["code"] == 0)
assert_that("nor leak a traceback to stderr", run["stderr"] == b"")
assert_that("the Gmail copy is still sent", OTHER_TO.encode() in run["sent"])
assert_that("and the omission is logged", "SMTPUTF8" in run["log"])
utf8_alias = "bj\u00f6rn@example.com"
run = run_pipe(raw_message(utf8_alias), recipient=utf8_alias, recipients=[utf8_alias])
assert_that("an allowlisted address SES cannot send as does not bounce either", run["code"] == 0)
assert_that("nothing is sent, because no such SES identity can exist", run["sent"] == b"")
assert_that(
    "and it says which address is unusable rather than dumping a traceback",
    "unrenderable_recipient" in run["log"] and "Traceback" not in run["log"],
)

run = run_pipe(raw_message(f"{ALIAS}, {OTHER_TO}"), mode="boom")
assert_that("an unexpected exception anywhere still exits 0", run["code"] == 0)
assert_that("with nothing on stderr", run["stderr"] == b"")
assert_that("nothing is sent, since the send is what failed", run["sent"] == b"")
assert_that(
    "and it is logged at ERROR, which is what the health check greps for",
    " ERROR " in run["log"],
)

print("\nnegative value: these assertions are load-bearing")
source = SCRIPT.read_text()


def mutate(name: str, needle: str, replacement: str) -> Path | None:
    """Write a copy of the real script with one line changed, or fail loudly if that
    line has moved -- a proof whose mutant no longer mutates passes for free."""
    assert_that(f"the mutation target for {name} still exists", needle in source)
    if needle not in source:
        return None
    path = SANDBOX / f"mutant_{name}.py"
    path.write_text(source.replace(needle, replacement))
    return path

# 1. Restore the old rewrite that dropped the other To recipients.
mutant_path = mutate(
    "dropped_to",
    "    kept_to = _render_new(to_pairs, seen, unencodable)\n",
    "    kept_to = []\n",
)
if mutant_path:
    mutated = forward(load(mutant_path, "ses_gmail_forward_mutant"))
    assert_that(
        "dropping the other To recipients is what this proof would catch",
        OTHER_TO not in addrs(mutated, "To"),
    )
    assert_that(
        "and the mutant still looks fine to a reader of the Gmail copy",
        addrs(mutated, "To") == [GMAIL],
    )

# 2. Call formataddr directly again, the way the SMTPUTF8 bug did. The guard now keeps
#    that from bouncing, which is exactly why it needs its own assertion: the failure
#    mode degrades from a bounce to a Gmail copy that never arrives and never explains
#    itself, and only the log says so.
utf8_path = mutate(
    "raises_on_utf8",
    "        rendered = _render_addr(name, addr)\n",
    "        rendered = formataddr((name, addr))\n",
)
if utf8_path:
    run = run_pipe(raw_message(f"{ALIAS}, {UTF8_HEADER}, {OTHER_TO}"), script=utf8_path)
    assert_that("the guard still keeps that from bouncing", run["code"] == 0)
    assert_that("but the Gmail copy is lost outright", run["sent"] == b"")
    assert_that("with only the log to say why", " ERROR " in run["log"])

# 3. Write the counter in place again, the way the multi-uid bug did.
rate_path = mutate(
    "in_place_counter",
    "        _write_shared(path, str(count + 1))\n",
    "        path.write_text(str(count + 1))\n",
)
if rate_path and not privileged:
    broken = load(rate_path, "ses_gmail_forward_rate_mutant")
    stuck = Path(broken.STATE_DIR) / "rate-r-stuck-mutant.count"
    stuck.parent.mkdir(parents=True, exist_ok=True)
    stuck.write_text("7")
    os.chmod(stuck, 0o444)
    broken._rate_path = lambda key: stuck
    broken._rate_increment("r-stuck-mutant")
    assert_that("writing in place is what leaves the counter stuck", stuck.read_text().strip() == "7")

# 4. Forward the scanning server's spam verdict again, the way the per-domain
#    inconsistency did. Nothing bounces and nothing is lost, so the only symptom is two
#    copies that differ by which domain they arrived at -- which is why it needs an
#    assertion rather than a reader's attention.
spam_path = mutate(
    "forwards_spam_verdict",
    '    for header in {h for h in msg.keys() if h.lower().startswith("x-spam-")}:\n',
    "    for header in ():\n",
)
if spam_path:
    leaky = forward(load(spam_path, "ses_gmail_forward_spam_mutant"), scanned)
    assert_that(
        "leaving the verdict in is what this proof would catch",
        [h for h in leaky.keys() if h.lower().startswith("x-spam-")] != [],
    )
    assert_that(
        "and it is what leaked the scanning host to the recipient",
        "mail.example.com" in leaky.as_string(),
    )

# 5. Remove the exit guard, so an unexpected exception reaches Exim again.
guard_path = mutate("no_guard", "        sys.exit(0)\n", "        raise\n")
if guard_path:
    run = run_pipe(raw_message(f"{ALIAS}, {OTHER_TO}"), mode="boom", script=guard_path)
    assert_that("without the guard the same failure exits nonzero", run["code"] != 0)
    assert_that("and puts a traceback on stderr, which is the bounce", b"Traceback" in run["stderr"])

shutil.rmtree(SANDBOX, ignore_errors=True)
print()
print(f"passed {passed}, failed {failed}")
sys.exit(1 if failed else 0)
