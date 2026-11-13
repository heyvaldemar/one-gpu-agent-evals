#!/usr/bin/env python3
"""private_check.py DIR... - nothing that names or locates the workstation or
its network, in any file under DIR.

    private_check.py DIR...    exit 1, and one line per finding, on any

Run by scripts/validate.sh over this repository on every change, and over a
series' files before they are committed here (ADR 3: published after review).
It refuses:
  - the names of the machines and the domain they live under, listed below in
    base64 so that this file does not carry them in the clear;
  - an address in a private range: the three ranges of RFC 1918, the shared
    range of RFC 6598, IPv4 link-local, and IPv6 link-local and unique local
    addresses. The ranges are written below as numbers, so that this file
    passes its own check.
Documentation addresses (192.0.2/24, 198.51.100/24, 203.0.113/24, RFC 5737)
and loopback are not a place, and pass. A finding prints the file, the line
and what kind of thing it is, never the matched text.
"""
import base64
import ipaddress
import os
import re
import sys

NAMES = [n for n in base64.b64decode("b255eC5ob3N0CnZtLWR0LTEKc3J2LTEKc3J2LTI=").decode().split("\n") if n]
IPV4 = re.compile(r"(?<![\w.])(\d{1,3}(?:\.\d{1,3}){3})(?![\w.])")
IPV6 = re.compile(r"(?<![\w:])((?:[0-9a-fA-F]{1,4}:){1,7}:?(?:[0-9a-fA-F]{1,4})?)(?![\w:])")
# RFC 1918 (three), RFC 6598, IPv4 link-local; IPv6 link-local and unique local.
PRIVATE_V4 = [ipaddress.IPv4Network((base, bits)) for base, bits in
              ((10 << 24, 8), ((172 << 24) | (16 << 16), 12), ((192 << 24) | (168 << 16), 16),
               ((100 << 24) | (64 << 16), 10), ((169 << 24) | (254 << 16), 16))]
PRIVATE_V6 = [ipaddress.IPv6Network((0xFE80 << 112, 10)), ipaddress.IPv6Network((0xFC00 << 112, 7))]
SKIP_DIRS = {".git", ".cache", "__pycache__"}


def findings(path):
    try:
        text = open(path, encoding="utf-8").read()
    except (UnicodeDecodeError, OSError):
        return []
    out = []
    for n, line in enumerate(text.splitlines(), 1):
        low = line.lower()
        for name in NAMES:
            if re.search(r"(?<![\w-])%s(?![\w-])" % re.escape(name), low):
                out.append((n, "the name of a machine or of its domain"))
        for m in IPV4.finditer(line):
            try:
                ip = ipaddress.ip_address(m.group(1))
            except ValueError:
                continue
            if any(ip in net for net in PRIVATE_V4):
                out.append((n, "an address in a private range"))
        for m in IPV6.finditer(line):
            try:
                ip = ipaddress.ip_address(m.group(1))
            except ValueError:
                continue
            if any(ip in net for net in PRIVATE_V6):
                out.append((n, "an IPv6 link-local or unique local address"))
    return out


def main(argv):
    if not argv:
        sys.exit(__doc__)
    bad = 0
    for top in argv:
        for root, dirs, files in os.walk(top):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith("series-test")]
            for f in files:
                path = os.path.join(root, f)
                for n, what in findings(path):
                    bad += 1
                    print("FAIL  private: %s:%d holds %s" % (os.path.relpath(path, top), n, what))
    if not bad:
        print("PASS  private: no machine's name, domain or private address in %s" % ", ".join(argv))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
