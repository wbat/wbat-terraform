#!/bin/bash
# Reject security-group rule descriptions that AWS will not accept.
#
# Why this exists as a separate check: the constraint is enforced by the EC2 API,
# not by the Terraform schema, so `terraform validate` passes and the apply fails
# in HCP Terraform with a message that does not name the character. An em dash in
# a rule description is the way this happens in practice, because prose written
# for humans picks up typographic punctuation.
#
# AWS allows, per the IpRange and UserIdGroupPair API references:
#   a-z A-Z 0-9 space . _ - : / ( ) # , @ [ ] + = ; { } ! $ *
# Notably absent: em/en dashes, curly quotes, apostrophes, ampersands, ?, %, &.
#
# Usage: scripts/check-sg-rule-descriptions.sh [path ...]     (default: aws/)

set -euo pipefail

exec python3 - "${@:-aws}" <<'PY'
import re
import sys
import os

ALLOWED = re.compile(r"^[A-Za-z0-9 ._\-:/()#,@\[\]+=;{}!$*]*$")

# Resource types whose `description` goes to the EC2 API under this constraint,
# plus the inline block names inside aws_security_group.
RULE_RESOURCES = (
    "aws_vpc_security_group_ingress_rule",
    "aws_vpc_security_group_egress_rule",
    "aws_security_group_rule",
)
INLINE_BLOCKS = ("ingress", "egress")


def offending_descriptions(path):
    """Yield (line_no, text, bad_chars) for constrained description strings."""
    out = []
    depth_stack = []  # (kind, depth_at_open)
    depth = 0
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            stripped = line.strip()

            m = re.match(r'resource\s+"([^"]+)"', stripped)
            if m and m.group(1) in RULE_RESOURCES:
                depth_stack.append(("rule", depth))
            elif re.match(r"(%s)\s*\{" % "|".join(INLINE_BLOCKS), stripped):
                depth_stack.append(("rule", depth))

            if depth_stack:
                d = re.match(r'description\s*=\s*"((?:[^"\\]|\\.)*)"', stripped)
                if d:
                    # Interpolations are runtime values; only the literal text
                    # can be checked here, so strip them before judging.
                    literal = re.sub(r"\$\{[^}]*\}", "", d.group(1))
                    if not ALLOWED.match(literal):
                        bad = sorted({c for c in literal if not ALLOWED.match(c)})
                        out.append((n, stripped, bad))

            depth += line.count("{") - line.count("}")
            while depth_stack and depth <= depth_stack[-1][1]:
                depth_stack.pop()
    return out


def main(roots):
    files = []
    for root in roots:
        if os.path.isfile(root):
            files.append(root)
            continue
        for dirpath, _, names in os.walk(root):
            if ".terraform" in dirpath:
                continue
            files.extend(os.path.join(dirpath, f) for f in names if f.endswith(".tf"))

    failures = 0
    for path in sorted(files):
        for n, text, bad in offending_descriptions(path):
            failures += 1
            chars = ", ".join("%r (U+%04X)" % (c, ord(c)) for c in bad)
            print("%s:%d: security-group rule description rejected by AWS" % (path, n))
            print("    %s" % text)
            print("    disallowed: %s" % chars)

    if failures:
        print()
        print("%d description(s) would fail AuthorizeSecurityGroup* at apply time." % failures)
        print("Allowed: a-z A-Z 0-9 space . _ - : / ( ) # , @ [ ] + = ; { } ! $ *")
        return 1
    print("OK %d Terraform file(s): no security-group rule description AWS would reject" % len(files))
    return 0


sys.exit(main(sys.argv[1:]))
PY
