# Form Trackpad

A menu bar app that gives the Kinesis Form keyboard's touchpad Mac trackpad gestures.

Out of the box macOS treats the Form's touchpad as a mouse: point, scroll, tap. The pad can
report every finger, though; it just has to be asked (this is how Windows drives it). Form
Trackpad asks, reads the fingers, and posts the same events a Magic Trackpad produces.

There is no driver or system extension. It is an ordinary app that needs Accessibility
permission to post events. Quitting it hands the pad back to macOS unchanged.

## Gestures

| Fingers | Gesture | Result |
| --- | --- | --- |
| 1 | Move | Pointer |
| 1 | Tap | Click |
| 1 | Tap, then touch and move | Drag (lift briefly to reposition; the drag ends a quarter second after letting go) |
| 2 | Tap | Right click |
| 2 | Move | Scroll, with momentum; swipes between pages in Safari |
| 2 | Pinch | Zoom |
| 2 | Twist | Rotate |
| 3 | Tap | Middle click |
| 3 or 4 | Swipe sideways | Switch Spaces and full-screen apps |
| 3 or 4 | Swipe up or down | Mission Control, App Exposé |

Touches that land within a third of a second of a keystroke are ignored, so palms don't click.

## Building

    ./scripts/build-app.sh --install

Needs a Developer ID signing identity in the keychain. `swift test` runs the gesture tests.

## Layout

- `Sources/TouchCore` turns finger reports into actions. No system calls; fully tested.
- `Sources/FormTrackpad/TouchpadDevice.swift` switches the pad into multi-touch mode and reads it.
- `Sources/FormTrackpad/EventSynth.swift` posts events. Pinch, rotate and the Dock swipes use
  macOS's undocumented event layout, which can change between macOS releases.

## Troubleshooting

The log is at `~/Library/Logs/FormTrackpad.log`. To record every finger report and action:

    defaults write com.mkwng.FormTrackpad logFrames -bool YES

then quit and reopen the app.

If the pointer stops responding, open Form Trackpad again from Spotlight; its menu opens and
Quit can be chosen with the arrow keys.
