#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."
./scripts/bootstrap.sh
xcodebuild -project MacPict.xcodeproj -scheme MacPict -configuration Debug -derivedDataPath DerivedData -destination 'platform=macOS' test
