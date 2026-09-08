#!/usr/bin/env python3
"""Sanitise a captured ``nginx -T`` fixture for a public repository.

This repository is public, so a verbatim capture from the production box cannot
be committed: it carries every hosted domain, every DirectAdmin account name,
and the exact package versions. Account names are the part that matters, since
they are half a credential pair for DirectAdmin, SSH, FTP and mail and are not
otherwise discoverable.

What is preserved is everything the invariant parser is tested on: listen
addresses, ``server_name`` shape, block nesting, and the asymmetry between
hand-patched and unpatched vhosts. Line counts and per-address listen counts
come out identical to the input.

What is deliberately *not* placeholdered: IP addresses and the server hostname.
The EIP is the public A record for most of these domains, the hostname is the
catch-all certificate CN, and the detector asserts on the private addresses --
masking them would break the test while hiding nothing.

Usage:
    scripts/directadmin/sanitize_nginx_capture.py <fixture-dir>
    scripts/directadmin/sanitize_nginx_capture.py --verify <fixture-dir> <original-dir>

``--verify`` re-reads the original capture and asserts that no account name and
no hosted domain survives anywhere in the sanitised tree. That check exists
because the obvious way to verify -- grepping for ``/home/<user>`` -- misses the
places a name appears without its path prefix, such as the per-account PHP-FPM
socket ``/usr/local/php82/sockets/<user>.sock``.
"""
import argparse
import os
import re
import sys

# The operator's own hostname, kept real: it is public via DNS and certificate
# transparency, and the detector's allowlist matches on it.
KEEP_DOMAINS = {"wbat.net", "server.wbat.net"}
# DirectAdmin's stock administrative account. Universal, so it discloses nothing.
KEEP_USERS = {"admin"}
# Named rather than numbered so the proof script reads as intent.
ROLE_DOMAINS = {
    "tellerstech.com": "patched-site.example",
    "iots.com": "broken-site.example",
}
SENTINEL = "\x00KEEP%d\x00"


def read_owned(fixdir):
    """Hosted domains, from the capture's own domainowners list."""
    owned = []
    with open(os.path.join(fixdir, "domainowners.txt")) as fh:
        for line in fh:
            d = line.split(":")[0].strip()
            if d:
                owned.append(d)
    return owned


def read_users(fixdir):
    """Account names, taken from paths that can only be an account name."""
    users = set()
    for name in os.listdir(fixdir):
        path = os.path.join(fixdir, name)
        if not os.path.isfile(path):
            continue
        text = open(path, encoding="utf-8", errors="replace").read()
        users.update(re.findall(r"/home/([a-z0-9_]+)", text))
        users.update(re.findall(r"data/users/([a-z0-9_]+)", text))
        users.update(re.findall(r"/sockets/([a-z0-9_]+)\.sock", text))
    return {u for u in users if u not in KEEP_USERS}


def build_maps(owned, users):
    dmap, idx = {}, 0
    for d in sorted(set(owned)):
        if d in KEEP_DOMAINS:
            continue
        if d in ROLE_DOMAINS:
            dmap[d] = ROLE_DOMAINS[d]
        else:
            idx += 1
            dmap[d] = "site%02d.example" % idx
    umap = {u: "user%02d" % i for i, u in enumerate(sorted(users), start=1)}
    return dmap, umap


def sanitise_text(text, dmap, umap):
    # Park the hostnames that must survive. An account name can also be a DNS
    # label here ("wbat" is both a user and part of server.wbat.net), and the
    # account pass below is deliberately unguarded so it reaches <user>.sock,
    # so the only safe way to protect a hostname is to remove it from the text
    # while that pass runs.
    keep = sorted(KEEP_DOMAINS, key=len, reverse=True)
    for i, host in enumerate(keep):
        # The lookbehind allows a leading label on purpose: www.wbat.net has to
        # be parked as well, or the deliberately unguarded account pass rewrites
        # the "wbat" inside it and the hostname silently changes identity.
        text = re.sub(r"(?<![\w-])%s(?![\w-])" % re.escape(host), SENTINEL % i, text)

    # Domains, longest first, preserving any subdomain labels so vhost shape
    # survives (www.x.com -> www.siteNN.example).
    for real, fake in sorted(dmap.items(), key=lambda kv: -len(kv[0])):
        text = re.sub(
            r"(?<![\w.-])((?:[a-z0-9_-]+\.)*)%s(?![\w-])" % re.escape(real),
            lambda m, f=fake: m.group(1) + f,
            text,
        )

    # Account names, anywhere they appear. No lookahead guard: a guard that
    # skipped "name followed by a dot and letters" would protect the hostname
    # but also protect <user>.sock, which is precisely where account names hid
    # the first time this was attempted.
    for real, fake in sorted(umap.items(), key=lambda kv: -len(kv[0])):
        text = re.sub(r"\b%s\b" % re.escape(real), fake, text)

    # Package versions. The config sets server_tokens off, so these are not
    # externally observable and the capture would be the only public source.
    # The FastCGI socket path carries the PHP branch too, so match the version
    # wherever it appears rather than only in the CustomBuild options file.
    text = re.sub(r"\bphp(\d)(\d)\b", "phpXY", text)
    text = re.sub(r"\bphp-(\d+\.\d+)\b", "php-X.Y", text)
    # The CustomBuild options dump lists exact versions as "Label: 1.2.3". The
    # match is anchored to a whole line so it cannot bite an IP address, which
    # would otherwise be at risk from a bare \d+\.\d+\.\d+ pattern -- and the
    # addresses in this fixture are load-bearing for the detector proof.
    text = re.sub(
        r"(?m)^([A-Za-z][A-Za-z0-9 ()\"'._-]*?):[ \t]*\d+\.\d+(?:\.\d+)?[ \t]*$",
        r"\1: <redacted>",
        text,
    )

    for i, _ in enumerate(keep):
        text = text.replace(SENTINEL % i, keep[i])
    return text


def run(fixdir):
    owned = read_owned(fixdir)
    users = read_users(fixdir)
    dmap, umap = build_maps(owned, users)
    print("domains: %d, accounts: %d" % (len(dmap), len(umap)))
    changed = 0
    for name in sorted(os.listdir(fixdir)):
        path = os.path.join(fixdir, name)
        if not os.path.isfile(path):
            continue
        text = open(path, encoding="utf-8", errors="replace").read()
        new = sanitise_text(text, dmap, umap)
        if new != text:
            open(path, "w", encoding="utf-8").write(new)
            changed += 1
    print("files rewritten: %d" % changed)
    # File names can carry identifiers too (ips/<addr> does not, but a future
    # capture might include per-account files).
    for name in sorted(os.listdir(fixdir)):
        new = name
        for real, fake in sorted(dmap.items(), key=lambda kv: -len(kv[0])):
            new = new.replace(real, fake)
        for real, fake in sorted(umap.items(), key=lambda kv: -len(kv[0])):
            new = re.sub(r"\b%s\b" % re.escape(real), fake, new)
        if new != name:
            os.rename(os.path.join(fixdir, name), os.path.join(fixdir, new))
            print("  renamed %s -> %s" % (name, new))


def verify(fixdir, origdir):
    """Assert nothing identifying survived. Scans for literal tokens anywhere."""
    owned = [d for d in read_owned(origdir) if d not in KEEP_DOMAINS]
    users = read_users(origdir)
    blob = []
    for name in sorted(os.listdir(fixdir)):
        path = os.path.join(fixdir, name)
        if os.path.isfile(path):
            blob.append(open(path, encoding="utf-8", errors="replace").read())
    text = "\n".join(blob)
    # Remove the kept hostnames before scanning: an account name can be a label
    # inside one ("wbat" within server.wbat.net), and counting that as a
    # surviving account would be a false positive that trains people to ignore
    # this check.
    for i, host in enumerate(sorted(KEEP_DOMAINS, key=len, reverse=True)):
        # The lookbehind allows a leading label on purpose: www.wbat.net has to
        # be parked as well, or the deliberately unguarded account pass rewrites
        # the "wbat" inside it and the hostname silently changes identity.
        text = re.sub(r"(?<![\w-])%s(?![\w-])" % re.escape(host), SENTINEL % i, text)
    bad = []
    for d in owned:
        if re.search(r"(?<![\w.-])%s(?![\w-])" % re.escape(d), text):
            bad.append("domain %s" % d)
    for u in users:
        if re.search(r"\b%s\b" % re.escape(u), text):
            bad.append("account %s" % u)
    for pat, label in (
        (r"\bphp\d\d\b", "php branch in a path"),
        (r"\bphp-\d+\.\d+\b", "php version"),
        (r"(?mi)^[A-Za-z][A-Za-z0-9 ()\"'._-]*?:[ \t]*\d+\.\d+(?:\.\d+)?[ \t]*$", "package version"),
    ):
        m = re.search(pat, text)
        if m:
            bad.append("%s (%s)" % (label, m.group(0).strip()))
    if bad:
        print("VERIFY FAILED -- still present:")
        for b in bad:
            print("  %s" % b)
        return 1
    print("VERIFY OK: %d domains and %d accounts absent from the sanitised tree"
          % (len(owned), len(users)))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--verify", action="store_true")
    ap.add_argument("fixture")
    ap.add_argument("original", nargs="?")
    args = ap.parse_args()
    if args.verify:
        if not args.original:
            ap.error("--verify needs the original capture directory")
        return verify(args.fixture, args.original)
    run(args.fixture)
    return 0


if __name__ == "__main__":
    sys.exit(main())
