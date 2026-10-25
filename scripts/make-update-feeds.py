"""Write a release's update feeds: appcast.xml for the Mac (Sparkle) and update.json for Windows and Android.

Every file is signed with the release key (Sparkle's sign_update: EdDSA, ed25519), and each app installs a file only
when its signature checks out against the key built into it. Both feeds go up with the release; the apps read the
latest release's (releases/latest/download/appcast.xml and update.json).

    python3 -I scripts/make-update-feeds.py --version 0.4.1 --build 11 --notes NEXT_RELEASE.md \\
        --base-url https://github.com/ego004/NoNonsenseMusic/releases/download/v0.4.1 --out <folder> \\
        --sign ~/projects/music-tools/sparkle-2.10.0/bin/sign_update --account nononsensemusic \\
        NoNonsenseMusic-macOS.zip NoNonsenseMusic-Setup.exe NoNonsenseMusic-Android.apk

--key-file instead of --account signs with a key file (the self-tests' test key, mac/UpdateTest).
"""
from __future__ import annotations

import argparse
import html
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path

MAC, WINDOWS, ANDROID = "NoNonsenseMusic-macOS.zip", "NoNonsenseMusic-Setup.exe", "NoNonsenseMusic-Android.apk"
MAC_MINIMUM = "15.0"            # mac/project.yml's deploymentTarget


def signature(sign: str, account: str | None, key_file: str | None, path: Path) -> str:
    who = ["--ed-key-file", key_file] if key_file else ["--account", account]
    out = subprocess.run([sign, *who, "-p", str(path)], capture_output=True, text=True, check=True).stdout.strip()
    if not re.fullmatch(r"[A-Za-z0-9+/=]{80,100}", out):
        sys.exit(f"sign_update gave no signature for {path.name}: {out!r}")
    return out


def notes_of(markdown: str) -> str:
    """What's new and the fixes: the notes above "## Downloads" (the install steps are for a first install)."""
    return markdown.split("\n## Downloads", 1)[0].strip()


def to_html(markdown: str) -> str:
    """The few things the notes use: headings, bullets, paragraphs, `code`, **bold** and [links](url)."""
    def inline(text: str) -> str:
        text = html.escape(text, quote=False)
        text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
        text = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", text)
        return re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)", r'<a href="\2">\1</a>', text)
    out, bullets = [], False
    for line in markdown.splitlines():
        if bullets and not line.startswith("- "):
            out.append("</ul>")
            bullets = False
        if line.startswith("## "):
            out.append(f"<h3>{inline(line[3:])}</h3>")
        elif line.startswith("- "):
            if not bullets:
                out.append("<ul>")
                bullets = True
            out.append(f"<li>{inline(line[2:])}</li>")
        elif line.strip():
            out.append(f"<p>{inline(line)}</p>")
    if bullets:
        out.append("</ul>")
    return "\n".join(out)


def main() -> None:
    parser = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True, help="the Mac's CFBundleVersion: what Sparkle compares")
    parser.add_argument("--notes", required=True, type=Path)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--sign", required=True)
    who = parser.add_mutually_exclusive_group(required=True)
    who.add_argument("--account")
    who.add_argument("--key-file")
    parser.add_argument("files", nargs="+", type=Path)
    args = parser.parse_args()

    notes = notes_of(args.notes.read_text())
    signed = {}
    for path in args.files:
        signed[path.name] = {"url": f"{args.base_url.rstrip('/')}/{path.name}", "length": path.stat().st_size,
                             "ed_signature": signature(args.sign, args.account, args.key_file, path)}
    args.out.mkdir(parents=True, exist_ok=True)

    if MAC in signed:
        mac = signed[MAC]
        appcast = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>NoNonsenseMusic</title>
    <item>
      <title>NoNonsenseMusic {html.escape(args.version)}</title>
      <sparkle:version>{html.escape(args.build)}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(args.version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{MAC_MINIMUM}</sparkle:minimumSystemVersion>
      <pubDate>{format_datetime(datetime.now(timezone.utc))}</pubDate>
      <description><![CDATA[{to_html(notes)}]]></description>
      <enclosure url="{html.escape(mac["url"])}" length="{mac["length"]}" type="application/octet-stream"
                 sparkle:edSignature="{mac["ed_signature"]}"/>
    </item>
  </channel>
</rss>
"""
        (args.out / "appcast.xml").write_text(appcast)

    others = {name: signed[name] for name in (WINDOWS, ANDROID) if name in signed}
    if others:
        (args.out / "update.json").write_text(json.dumps(
            {"version": args.version, "notes": notes, "files": others}, indent=2, ensure_ascii=False) + "\n")
    print(f"feeds for {args.version} in {args.out}: " + ", ".join(sorted(p.name for p in args.out.iterdir())))


if __name__ == "__main__":
    main()
