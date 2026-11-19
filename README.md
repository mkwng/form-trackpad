# Form Trackpad

A menu bar app that gives the Kinesis Form keyboard's touchpad Mac trackpad gestures.

Out of the box macOS treats the Form's touchpad as a mouse: point, scroll, tap. The pad can
report every finger, though; it just has to be asked (this is how Windows drives it). Form
Trackpad asks, reads the fingers, and posts the same events a Magic Trackpad produces.

There is no driver or system extension. It is an ordinary app that needs Accessibility
permission to post events. It makes no network connections. Quitting it hands the pad back to
macOS unchanged.

## Who wrote this

This project was written primarily by Claude Fable 5.2, an AI model made by Anthropic, working
in Claude Code. That covers the reverse engineering of the pad's reports, the gesture engine,
the event synthesis, the tests and this README. Michael Wang owns the keyboard, directed the
work and tested it by hand.

Read the code before you trust it, as you should with anything that asks for Accessibility
permission. It is about 1,500 lines of Swift.

## Status

It works well on the one setup it was built on: a Kinesis Form (USB ID `29ea:1000`) on
macOS 27. It has not been tried on other macOS versions or other Form hardware revisions.

Known gaps:

- The direction of the three- and four-finger swipes and the four-finger spread has not been
  confirmed and may be reversed. The signs are two constants at the top of `EventSynth.swift`.
- Notification Center (two fingers in from the right edge) is not implemented.
- There is no three-finger drag. Tap, then touch and move, drags instead.
- Force click and haptics are impossible; the pad has no pressure sensor.

## Gestures

| Fingers | Gesture | Result |
| --- | --- | --- |
| 1 | Move | Pointer |
| 1 | Tap | Click |
| 1 | Tap, then touch and move | Drag (lift briefly to reposition; the drag ends a quarter second after letting go) |
| 2 | Tap | Right click |
| 2 | Double tap | Smart zoom |
| 2 | Move | Scroll, with momentum; swipes between pages in Safari |
| 2 | Pinch, twist | Zoom and rotate, together with scrolling if the fingers also travel |
| 3 | Tap | Look up |
| 3 or 4 | Swipe sideways | Switch Spaces and full-screen apps |
| 3 or 4 | Swipe up or down | Mission Control, App Exposé |
| 4 | Spread or pinch | Show Desktop, Apps |

Touches that land within a third of a second of a keystroke are ignored, so palms don't click.
Scrolling follows the system's natural scrolling setting. Tracking and scrolling speed are in
the app's menu.

## Install

There is no prebuilt download. Build it yourself with Xcode's command line tools installed:

    git clone https://github.com/mkwng/form-trackpad.git
    cd form-trackpad
    ./scripts/build-app.sh --install

Open Form Trackpad from Applications and grant it Accessibility permission when asked. The pad
stays in its normal mouse mode until you do.

The script signs with a Developer ID identity if your keychain has one. Otherwise it signs ad
hoc, and macOS will ask for Accessibility permission again after each rebuild.

`swift test` runs the gesture tests.

## How it works

The Form's touchpad is a Windows Precision Touchpad. Writing 3 to its Input Mode feature report
switches it from mouse reports to raw finger reports: up to four contacts, each with a position
in tenths of a millimetre, about every 7 ms. Writing 0 switches it back, which the app does on
quit and on a crash.

- `Sources/TouchCore` turns finger reports into actions (move, click, scroll, magnify and so
  on). It makes no system calls and is covered by the tests.
- `Sources/FormTrackpad/TouchpadDevice.swift` finds the pad, switches its mode and reads it.
- `Sources/FormTrackpad/EventSynth.swift` posts the events. Pointer and scroll events use public
  APIs. Pinch, rotate, smart zoom and the Dock swipes use macOS's undocumented event layout and
  one private function, so they can break in a future macOS release.
- `probe/` holds the small programs used to work out the report format.

## Troubleshooting

The log is at `~/Library/Logs/FormTrackpad.log`. To record every finger report and action:

    defaults write com.mkwng.FormTrackpad logFrames -bool YES

then quit and reopen the app.

If the pointer stops responding, open Form Trackpad again from Spotlight; its menu opens and
Quit can be chosen with the arrow keys.

## Credits

The layout of the undocumented gesture events was learned from reading
[Mac Mouse Fix](https://github.com/noah-nuebling/mac-mouse-fix). No code was copied from it.

Not affiliated with Kinesis or Apple.

## License

MIT. See `LICENSE`.
