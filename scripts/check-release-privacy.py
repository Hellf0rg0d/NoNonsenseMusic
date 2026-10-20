#!/usr/bin/env python3
"""Checks release files for anything that points at the person who built them, before they are uploaded.

    python3 -I scripts/check-release-privacy.py <file or folder>...

Looks inside every file, and inside every file of a .zip or .apk, for this machine's user name, home folder, computer
name and host name, and for any extra words listed one per line in ~/.config/nononsense/private-words (kept out of
the repository, which is public: a list of names here would publish them). Prints which kind of value was found where,
never the value, and exits 1 when anything was found.

Why (20 Oct 2026): every Mac app and Android APK released until then carried the builder's home folder, and so their
name: the Mac app in 65,130 unstripped debug entries, the APK in one generated file's path. Release builds are now
stripped (mac/project.yml) and made in a folder whose path names nobody; this check is the last look before upload.
"""
import os
import re
import socket
import subprocess
import sys
import zipfile


def identifiers() -> dict[str, str]:
    found = {"user name": os.environ.get("USER", ""), "home folder": os.path.expanduser("~"), "host name": socket.gethostname()}
    for key, label in (("ComputerName", "computer name"), ("LocalHostName", "local host name")):
        try:
            found[label] = subprocess.run(["scutil", "--get", key], capture_output=True, text=True).stdout.strip()
        except OSError:                                    # not a Mac
            pass
    words = os.path.expanduser("~/.config/nononsense/private-words")
    if os.path.exists(words):
        for i, line in enumerate(open(words, encoding="utf-8")):
            if line.strip() and not line.startswith("#"):
                found[f"private word {i + 1}"] = line.strip()
    # values too short to mean anything ("a", "/") would match everywhere
    return {label: value.lower() for label, value in found.items() if len(value) >= 4}


def scan(label: str, data: bytes, values: dict[str, str], hits: list[str]) -> None:
    low = data.lower()
    for kind, value in values.items():
        for encoding in ("utf-8", "utf-16-le"):              # Windows files keep their text as UTF-16
            count = low.count(value.encode(encoding))
            if count:
                hits.append(f"{label}: {kind} x{count}")


def files(paths: list[str]):
    for path in paths:
        if os.path.isdir(path):
            for folder, _, names in os.walk(path):
                for name in names:
                    yield os.path.join(folder, name)
        else:
            yield path


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    values = identifiers()
    hits: list[str] = []
    for path in files(sys.argv[1:]):
        with open(path, "rb") as f:
            scan(path, f.read(), values, hits)
        if zipfile.is_zipfile(path):
            with zipfile.ZipFile(path) as archive:
                for entry in archive.infolist():
                    if not entry.is_dir():
                        scan(f"{path} › {entry.filename}", archive.read(entry), values, hits)
                    if re.search(r"(^|/)\._|__MACOSX/", entry.filename) and not path.endswith("macOS.zip"):
                        hits.append(f"{path} › {entry.filename}: a Mac metadata file (made by zipping on a Mac)")
    for hit in hits:
        print(hit)
    print(f"{len(hits)} found" if hits else f"clean ({len(values)} kinds of value looked for)")
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
