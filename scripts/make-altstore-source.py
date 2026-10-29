"""Write altstore.json: the source SideStore and AltStore read to list the iPhone app and offer its updates.

A source is a JSON file at a fixed address; the people who install add that address once. It goes up with each
release, and the address that never changes is the latest release's:

    https://github.com/ego004/NoNonsenseMusic/releases/latest/download/altstore.json

    python3 -I scripts/make-altstore-source.py --version 0.6.0 --build 14 --notes NEXT_RELEASE.md \\
        --base-url https://github.com/ego004/NoNonsenseMusic/releases/download/v0.6.0 --out <folder> \\
        NoNonsenseMusic-iOS.ipa icon.png

The .ipa is unsigned: SideStore and AltStore sign it with the installer's own Apple ID. The app entry carries both
the older flat fields (version, versionDate, downloadURL, size) and the newer `versions` list, because both apps read
whichever they know. Nothing here names a person: the developer is the GitHub handle.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from datetime import date
from pathlib import Path

BUNDLE_ID = "app.nononsense.music"        # mac/project.yml, target NoNonsenseiOS
MINIMUM_IOS = "18.0"
REPO = "https://github.com/ego004/NoNonsenseMusic"


def plain_notes(notes_file: Path) -> str:
    """The "What's new" section as plain text: bullets as lines, Markdown marks gone."""
    text = notes_file.read_text(encoding="utf-8")
    match = re.search(r"## What's new\n(.*?)(?=\n## )", text, re.S)
    section = match.group(1) if match else ""
    lines = [re.sub(r"^- ", "", line).replace("`", "").replace("›", ">") for line in section.splitlines() if line.strip()]
    return "\n".join(lines)


def build(version: str, build_number: str, ipa: Path, icon: str, base_url: str, notes: str, today: str) -> dict:
    size = ipa.stat().st_size
    digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
    version_entry = {
        "version": version, "buildVersion": build_number, "date": today, "localizedDescription": notes,
        "downloadURL": f"{base_url}/{ipa.name}", "size": size, "sha256": digest, "minOSVersion": MINIMUM_IOS,
    }
    return {
        "name": "NoNonsenseMusic",
        "identifier": f"{BUNDLE_ID}.source",
        "sourceURL": f"{REPO}/releases/latest/download/altstore.json",
        "subtitle": "A player for your own music server",
        "description": "NoNonsenseMusic for iPhone and iPad. It needs a NoNonsenseMusic server: host your own, or ask a friend.",
        "website": REPO,
        "tintColor": "#1C1C1E",
        "apps": [{
            "name": "NoNonsenseMusic",
            "bundleIdentifier": BUNDLE_ID,
            "developerName": "ego004",
            "subtitle": "Your music server, on your phone",
            "localizedDescription": "Plays from your own NoNonsenseMusic server. Playlists, lyrics, jams, an equalizer and headphone correction.",
            "iconURL": f"{base_url}/{icon}",
            "tintColor": "#1C1C1E",
            "screenshotURLs": [],
            "versions": [version_entry],
            # the older flat form, for installers that do not read `versions`
            "version": version, "versionDate": today, "versionDescription": notes,
            "downloadURL": version_entry["downloadURL"], "size": size,
            "appPermissions": {"entitlements": [], "privacy": {}},
        }],
        "news": [],
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--notes", required=True, type=Path)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--date", default=date.today().isoformat())
    parser.add_argument("ipa", type=Path)
    parser.add_argument("icon")
    args = parser.parse_args()
    source = build(args.version, args.build, args.ipa, args.icon, args.base_url.rstrip("/"), plain_notes(args.notes), args.date)
    app = source["apps"][0]
    problems = [name for name in ("downloadURL", "iconURL", "version", "size") if not app.get(name)]
    if not app["downloadURL"].endswith(args.ipa.name) or app["size"] < 1_000_000:
        problems.append("the .ipa looks wrong (name or size)")
    if problems:
        sys.exit(f"not written: {', '.join(problems)}")
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "altstore.json").write_text(json.dumps(source, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"altstore.json for {args.version}: {app['size']:,} bytes, {len(source['apps'][0]['versions'])} version")


if __name__ == "__main__":
    main()
