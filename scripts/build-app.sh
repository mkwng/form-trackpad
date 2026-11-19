#!/bin/zsh
# Builds "Form Trackpad.app" into build/. Pass --install to copy it into /Applications.
# Signs with a Developer ID identity when there is one, so macOS keeps the app's Accessibility
# permission across rebuilds; otherwise signs ad hoc.
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release
app="build/Form Trackpad.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/FormTrackpad "$app/Contents/MacOS/FormTrackpad"
cp Support/Info.plist "$app/Contents/Info.plist"

identity=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
if [[ -n $identity ]]; then
  codesign --force --options runtime --timestamp=none --sign "$identity" "$app"
else
  echo "No Developer ID identity found; signing ad hoc. macOS will ask for Accessibility again after each rebuild." >&2
  codesign --force --sign - "$app"
fi
codesign --verify --strict "$app"

if [[ ${1:-} == --install ]]; then
  rm -rf "/Applications/Form Trackpad.app"
  cp -R "$app" "/Applications/Form Trackpad.app"
  echo "Installed /Applications/Form Trackpad.app"
fi
