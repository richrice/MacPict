#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."
./scripts/bootstrap.sh

xcodebuild -project MacPict.xcodeproj -scheme MacPict -configuration Release -derivedDataPath DerivedData -destination 'platform=macOS' build

APP="DerivedData/Build/Products/Release/MacPict.app"
DEST="/Applications/MacPict.app"

if [[ ! -d "$APP" ]]; then
  print -u2 "Release build not found at $APP"
  exit 1
fi

# A running copy holds the status item and the hotkey registration, so replacing the
# bundle underneath it would leave both pointing at a deleted binary.
pkill -x MacPict 2>/dev/null || true

rm -rf "$DEST"
ditto "$APP" "$DEST"

print "Installed $DEST"
print "Screen Recording is granted per binary. A newly installed build is a new binary, so"
print "macOS will ask again, and it usually needs a relaunch after you grant it."
