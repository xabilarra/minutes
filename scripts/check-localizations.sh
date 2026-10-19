#!/usr/bin/env bash
# Fails when a localizable UI string (Spanish source) has no English translation, or when the
# English table keeps a key the code no longer uses. Keys are extracted by the Swift compiler.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift build --package-path "$ROOT" --scratch-path "$WORK/build" --product Minutes \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$WORK/strings" >/dev/null

python3 -I - "$WORK/strings" "$ROOT/Resources/en.lproj/Localizable.strings" <<'EOF'
import json, pathlib, plistlib, subprocess, sys
used = set()
for f in pathlib.Path(sys.argv[1]).glob("*.stringsdata"):
    for table in json.loads(f.read_text()).get("tables", {}).values():
        used.update(entry["key"] for entry in table)
english = plistlib.loads(subprocess.run(
    ["plutil", "-convert", "xml1", "-o", "-", sys.argv[2]], check=True, capture_output=True).stdout)
missing = sorted(used - english.keys())
unused = sorted(english.keys() - used)
for key in missing:
    print(f"missing English translation: {key!r}")
for key in unused:
    print(f"unused English key: {key!r}")
print(f"{len(used)} localizable strings, {len(missing)} missing, {len(unused)} unused")
sys.exit(1 if missing or unused else 0)
EOF
