#!/bin/zsh
# Builds "Form Trackpad.app" into build/, signed so macOS keeps its Accessibility permission
# across rebuilds. Pass --install to copy it into /Applications.
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release
app="build/Form Trackpad.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/FormTrackpad "$app/Contents/MacOS/FormTrackpad"
cp Support/Info.plist "$app/Contents/Info.plist"

identity=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
[[ -n $identity ]] || { echo "No Developer ID signing identity found" >&2; exit 1 }
codesign --force --options runtime --timestamp=none --sign "$identity" "$app"

if [[ ${1:-} == --install ]]; then
  rm -rf "/Applications/Form Trackpad.app"
  cp -R "$app" "/Applications/Form Trackpad.app"
  echo "Installed /Applications/Form Trackpad.app"
fi
