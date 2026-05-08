#!/usr/bin/env python3
"""Prepend a new <item> entry to a Sparkle appcast.xml.

Used by both the local rehearsal flow (scripts/test-update.sh) and the GitHub
Actions release workflow. Pure stdlib — no third-party deps.

The appcast format is RSS 2.0 with the Sparkle namespace; we keep it pretty-
printed so diffs in PRs read naturally.
"""

from __future__ import annotations

import argparse
import html
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)


def parse_signature_line(line: str) -> tuple[str, str | None]:
    """Sparkle's `sign_update` prints something like:
        sparkle:edSignature="<sig>" length="<bytes>"
    Pull the signature out; length we can derive ourselves but accept it too.
    """
    sig_match = re.search(r'sparkle:edSignature="([^"]+)"', line)
    len_match = re.search(r'length="(\d+)"', line)
    if not sig_match:
        raise SystemExit(f"Could not parse signature from: {line!r}")
    sig = sig_match.group(1)
    length = len_match.group(1) if len_match else None
    return sig, length


def build_item(args, signature: str, length: str) -> ET.Element:
    item = ET.Element("item")
    title = ET.SubElement(item, "title")
    title.text = f"Version {args.short_version}"

    pub = ET.SubElement(item, "pubDate")
    pub.text = args.pub_date

    short = ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString")
    short.text = args.short_version

    ver = ET.SubElement(item, f"{{{SPARKLE_NS}}}version")
    ver.text = args.version

    if args.minimum_system_version:
        msv = ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion")
        msv.text = args.minimum_system_version

    desc = ET.SubElement(item, "description")
    # Wrap HTML in CDATA. ElementTree won't emit CDATA on its own, so we slot
    # in a placeholder and substitute after serialization.
    desc.text = f"__CDATA_PLACEHOLDER_{id(desc)}__"
    desc.set("__cdata_payload__", args.description or "")

    enc = ET.SubElement(item, "enclosure")
    enc.set("url", args.url)
    enc.set("length", length)
    enc.set("type", "application/octet-stream")
    enc.set(f"{{{SPARKLE_NS}}}edSignature", signature)

    return item


def load_or_init(path: Path) -> ET.ElementTree:
    if path.exists() and path.stat().st_size > 0:
        return ET.parse(path)
    rss = ET.Element("rss", attrib={
        "version": "2.0",
        "xmlns:sparkle": SPARKLE_NS,
    })
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "GitPilot"
    ET.SubElement(channel, "link").text = "https://github.com/benjamingarcia10/GitPilot"
    ET.SubElement(channel, "description").text = "Most recent GitPilot updates"
    ET.SubElement(channel, "language").text = "en"
    return ET.ElementTree(rss)


def _indent(elem: ET.Element, level: int = 0) -> None:
    """Pretty-print indenter for Python < 3.9 (ET.indent didn't exist yet)."""
    pad = "\n" + level * "  "
    if len(elem):
        if not elem.text or not elem.text.strip():
            elem.text = pad + "  "
        for i, child in enumerate(list(elem)):
            _indent(child, level + 1)
            if not child.tail or not child.tail.strip():
                child.tail = pad + ("  " if i < len(elem) - 1 else "")
    else:
        if level and (not elem.tail or not elem.tail.strip()):
            elem.tail = pad


def serialize(tree: ET.ElementTree) -> str:
    """Serialize with Sparkle's xmlns prefix and inline CDATA payloads."""
    if hasattr(ET, "indent"):
        ET.indent(tree, space="  ")
    else:
        _indent(tree.getroot())
    raw = ET.tostring(tree.getroot(), encoding="unicode")

    # ElementTree refuses to emit CDATA. Find each placeholder and rewrite the
    # surrounding <description> to use a CDATA section with the saved payload.
    def cdata_sub(match: re.Match) -> str:
        # The surrounding tag carries our payload as a private attribute.
        attrs = match.group(1)
        payload_match = re.search(r' __cdata_payload__="([^"]*)"', attrs)
        payload = payload_match.group(1) if payload_match else ""
        # ElementTree may emit any of &amp; &lt; &gt; &quot; &#10; &#13; &#39;
        # depending on Python version when serializing attributes. Use the
        # full HTML entity decoder (covers numeric refs and named entities) to
        # round-trip the original markup byte-for-byte.
        payload = html.unescape(payload)
        # CDATA terminates at the first `]]>`. If that sequence appears in the
        # payload (e.g. release notes containing a code block with `]]>`), it
        # would close our CDATA early and leave the rest as raw XML, which
        # Sparkle's parser would reject and break the entire feed. Split each
        # occurrence across two CDATA sections so the literal `]]>` is
        # preserved as text without ever appearing as the closer.
        payload = payload.replace("]]>", "]]]]><![CDATA[>")
        return f"<description><![CDATA[{payload}]]></description>"

    raw = re.sub(
        r'<description([^>]*)>__CDATA_PLACEHOLDER_\d+__</description>',
        cdata_sub,
        raw,
    )
    return '<?xml version="1.0" encoding="utf-8"?>\n' + raw + "\n"


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--appcast", required=True, type=Path)
    p.add_argument("--version", required=True, help="CFBundleVersion (build #)")
    p.add_argument("--short-version", required=True, help="CFBundleShortVersionString")
    p.add_argument("--url", required=True)
    p.add_argument("--length", required=True)
    p.add_argument("--signature-line", required=True,
                   help="Raw output from sign_update")
    p.add_argument("--pub-date", required=True,
                   help='RFC 822 date, e.g. "Mon, 10 Jun 2024 12:00:00 +0000"')
    p.add_argument("--description", default="",
                   help="Release notes HTML to embed in <description>")
    p.add_argument("--minimum-system-version", default="13.0")
    args = p.parse_args()

    sig, sig_len = parse_signature_line(args.signature_line)
    length = sig_len or args.length

    tree = load_or_init(args.appcast)
    channel = tree.getroot().find("channel")
    if channel is None:
        raise SystemExit("Appcast missing <channel> — bad file?")

    new_item = build_item(args, sig, length)

    # Insert the new item *after* channel metadata but *before* existing items
    # so the most recent release appears first (RSS readers, including Sparkle,
    # walk top-down to find the highest version).
    insert_idx = 0
    for i, child in enumerate(list(channel)):
        if child.tag == "item":
            insert_idx = i
            break
        insert_idx = i + 1
    channel.insert(insert_idx, new_item)

    args.appcast.write_text(serialize(tree))
    print(f"Wrote {args.appcast} ({args.short_version})")


if __name__ == "__main__":
    main()
