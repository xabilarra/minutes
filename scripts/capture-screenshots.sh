#!/usr/bin/env bash
# Regenerates the README screenshots in docs/images from the installed app running in showcase
# mode (sample data, nothing is recorded). Your terminal needs Screen Recording permission.
# A running Minutes is quit first; the script refuses while a meeting is being recorded.
#
# Usage: scripts/capture-screenshots.sh   (APP=/path/to/Minutes.app to use another build)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${APP:-$HOME/Applications/Minutes.app}"
OUT="$ROOT/docs/images"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
mkdir -p "$OUT"

recording_in_progress() {
  python3 -I - "$HOME/Reuniones" <<'EOF'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
for meta in root.glob("*/meta.json") if root.exists() else []:
    if not json.loads(meta.read_text()).get("endedAt"):
        sys.exit(0)
sys.exit(1)
EOF
}

quit_minutes() {
  pgrep -x Minutes >/dev/null || return 0
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null
  for _ in $(seq 1 20); do pgrep -x Minutes >/dev/null || return 0; sleep 0.5; done
  echo "Minutes did not quit." >&2
  exit 1
}

# Prints "<layer> <window id>" for every on-screen window of the given process.
windows_of() {
  swift - "$1" <<'EOF'
import CoreGraphics
let pid = Int32(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows where (window[kCGWindowOwnerPID as String] as? Int32) == pid {
    print(window[kCGWindowLayer as String] as? Int ?? 0, window[kCGWindowNumber as String] as? Int ?? 0)
}
EOF
}

if pgrep -x Minutes >/dev/null && recording_in_progress; then
  echo "A meeting is being recorded; try again when it ends." >&2
  exit 1
fi
quit_minutes

# language, transcription language shown in the settings
for spec in "en auto" "es es"; do
  set -- $spec
  lang=$1 transcription=$2
  for scene in recording ending ready; do
    open "$APP" --args --showcase "$scene" -AppleLanguages "($lang)" -transcriptionLanguage "$transcription"
    sleep 3
    pid="$(pgrep -x Minutes)"
    while read -r layer id; do
      if [ "$layer" = 0 ] && [ "$scene" = ready ]; then
        screencapture -x -l"$id" "$OUT/window-$lang.png"
      elif [ "$layer" != 0 ]; then
        screencapture -x -l"$id" "$OUT/pill-$scene-$lang.png"
      fi
    done < <(windows_of "$pid")
    quit_minutes
  done
done

ls -1 "$OUT"
echo "Done. Reopen Minutes normally with: open \"$APP\""
