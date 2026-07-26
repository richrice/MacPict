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
# The Screen Recording grant is recorded against the bundle identifier and the signing
# identity, not the binary, so replacing the bundle leaves an existing grant in force.
print "A first install asks for Screen Recording on the first capture, and usually needs a"
print "relaunch after you grant it. A reinstall keeps the grant you have already given."
