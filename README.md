# SpaceApps

A tiny macOS menu bar app that shows which apps are on your current desktop (Space),
and lets you jump to, move or quit any app on any desktop, and reorder your desktops.

<img src="docs/screenshot.png" alt="SpaceApps: the menu bar strip with the current desktop's app icons, and its menu listing each desktop's apps with quit buttons" width="262">

## What it does

- **Menu bar strip:** icons of the apps with windows on the desktop you're on. It updates the
  moment you swipe to another desktop. Up to 8 icons, then `+N`.
- **Click it** for a menu grouped by desktop:
  - **Click an app** to switch to it. If it's on another desktop, macOS takes you there.
  - **Click the lock** to make that app always open on that desktop. Click it again to unlock.
    It's macOS's own "Assign To: This Desktop" (Dock icon → Options), just quicker. The Dock
    restarts for a second to pick up the change.
  - **Click the ⊗** on the right of a row to quit that app.
  - **Hold and drag an app** onto another desktop to move its windows there. While you drag,
    a **New Desktop** row appears: drop it there to give the app a desktop of its own. If the app
    was locked to the desktop it left, the lock moves with it.
  - **Hold and drag a desktop's name** up or down to reorder your desktops.
  - **Pause Locks with a Monitor** (on by default): while an external display is connected, locks are
    put aside so apps open wherever you are. They come back when you unplug. Locking or unlocking
    while paused takes effect after you unplug.
  - Also: Launch at Login, Quit.
- Only windows you can actually see count: hidden, minimized and closed-in-the-background windows
  don't show up.

Showing, switching, locking and quitting need **no permissions**: no Accessibility, no Screen
Recording. It reads only which app owns each window, never window titles or contents. It uses
about 0.2% CPU.

**Moving apps and desktops needs Accessibility.** macOS only lets Mission Control move another
app's windows, add desktops or reorder them, so SpaceApps opens Mission Control and does the drag
for you. You'll see it for a second or two (a bit longer when the app is on another desktop:
Mission Control only shows the current desktop's windows, so SpaceApps goes there first and then
brings you back). It asks for Accessibility the first time you drop something.

## Requirements

- macOS 26 or later
- Xcode 26 or later (for the Swift 6.2 toolchain), only to build it

## Install

There's no prebuilt download yet (an unsigned app would be blocked by Gatekeeper), so build it:

```bash
git clone https://github.com/artemzhivilo/SpaceApps.git
cd SpaceApps
scripts/build.sh
```

`scripts/build.sh` builds a release version, bundles `SpaceApps.app`, installs it to
`~/Applications` and starts it. Run it again after pulling changes. If you have an Apple
Development certificate (any Apple ID signed in under Xcode → Settings → Accounts), it signs with
that, so macOS keeps the Accessibility permission across rebuilds. Otherwise it signs ad hoc, and
you need to turn SpaceApps off and on again in Accessibility after each rebuild. To start SpaceApps with your
Mac, click it and choose **Launch at Login**.

Checks from the terminal:

```bash
swift run SpaceApps --print    # apps on the current desktop
swift run SpaceApps --spaces   # every desktop's apps, in Mission Control order
swift run SpaceApps --bench    # time per scan (about 2 ms)
swift run SpaceApps --locks    # which apps are locked to which desktop, and whether locks are paused
swift run SpaceApps --toggle-lock com.apple.Safari 2   # lock or unlock an app on Desktop 2
swift run SpaceApps --update-locks   # pause or resume locks for the connected displays
swift run SpaceApps --move-app com.apple.Safari 3   # move Safari's windows to Desktop 3 ("new" for a new desktop)
swift run SpaceApps --move-desktop 3 1   # move Desktop 3 to the front
```

The two `--move` commands work Mission Control like the menu does, so the app running them
(your terminal) needs Accessibility.

To test pausing without a monitor, prefix a command with `SPACEAPPS_FAKE_MONITOR=1` (plugged in) or
`SPACEAPPS_FAKE_MONITOR=0` (unplugged).

Locks are stored where macOS keeps them (`app-bindings` in `com.apple.spaces`). While paused, they
wait in `~/Library/Application Support/SpaceApps/paused-locks.plist`.

## How it works

Public macOS APIs can't tell which desktop a window is on, so SpaceApps uses a few private
SkyLight calls, the same family [yabai](https://github.com/koekeishiya/yabai) and
[AltTab](https://github.com/lwouis/alt-tab-macos) rely on:

- `CGSGetActiveSpace` and `CGSCopyManagedDisplaySpaces`: the current desktop and the desktop order.
- `CGSCopySpacesForWindows`: which desktop each window is on.
- `SLSWindowIsOrderedIn`: whether a window is actually shown (minimized and closed windows aren't).

Moving apps and desktops drives Mission Control through its accessibility tree: each window on
the current desktop is a button tagged `<bundle id>.space.<space id>`, and the Spaces bar has a
button per desktop plus "Add Desktop". SpaceApps presses "Add Desktop" and "Exit To Desktop N"
directly, and posts mouse drags for the rest, putting your pointer back afterwards. The private
calls that once moved windows directly (`SLSMoveWindowsToManagedSpace`, and yabai's
`SLSSpaceSetCompatID` workaround) no longer work on macOS 27.

It redraws on macOS's "active Space changed" and app launch/quit/activate notifications, plus a
cheap once-a-second check for windows opening and closing.

Because of the private calls, SpaceApps can't go on the Mac App Store, and a future macOS could
change them. If a call disappears, SpaceApps falls back to "windows on screen" instead of breaking.

## Known limits

- If an app has windows on both your current desktop and another one, clicking it under the other
  desktop keeps you where you are. That's how macOS switches to apps.
- The icons update when macOS announces the desktop switch, at the end of the slide animation.
- Main display only.
- While a move runs, leave the mouse alone for a moment: it's a real drag in Mission Control.

## License

[MIT](LICENSE)
