# Experiments (not built)

Kept for reference; none of this is compiled into SpaceApps.

- `SwipeTap/` + `SwipeBoost.swift`: an event tap that changed three-finger Space swipes
  (release speed, swipe distance, "snap" at lift-off) using private trackpad event fields.
  It worked technically on macOS 27.2, but the Dock's finish animation felt the same.
- `MissionControlOverlay.swift` + `AX.swift`: app icons under each "Desktop N" label in
  Mission Control. On macOS 27 Mission Control is drawn by WindowManager; its accessibility
  tree is `mc.display` → `mc.spaces` → `mc.spaces.list` (one button per desktop, with an
  "Exit To Desktop N" press action), and window thumbnails are tagged `<bundle id>.space.<id>`.
  Dropped in favour of the desktops menu.

Both need Accessibility permission, which ad-hoc signed rebuilds reset every time.

## Credits

The swipe event tap is based on [iss](https://github.com/joshuarli/iss) by joshuarli
(0BSD license): the private trackpad event fields, and the macOS 27 raw IOHID payload layout
that `SwipeTap.c` reads and patches, come from its reverse engineering.
