// SwipeTap: makes the end of a three-finger Space swipe finish sooner by multiplying
// the speed at which your fingers leave the trackpad. The slide itself still follows
// your fingers. Experimental: it relies on private trackpad event fields
// (reverse-engineered by iss, https://github.com/joshuarli/iss, 0BSD license).
#pragma once
#include <stdbool.h>

/// Whether this app has Accessibility permission. `prompt` shows macOS's request dialog.
bool swipetap_is_trusted(bool prompt);

/// Starts listening to Space swipes. Returns false without Accessibility permission.
bool swipetap_start(void);
void swipetap_stop(void);
bool swipetap_is_running(void);

/// 1.0 leaves swipes untouched; 3.0 makes the release three times faster.
void swipetap_set_boost(double factor);

/// Multiplies how far the slide moves per finger distance while you swipe, so less is left
/// for the Dock to coast after you lift off. 1.0 = normal, 2.0 = the slide moves twice as far.
void swipetap_set_gain(double factor);

/// At lift-off, moves the slide at least this far towards the next Space (0 = off,
/// 0.8 = 80% of the way), so the Dock only animates a short, quick finish.
void swipetap_set_snap(double fraction);

/// Writes a line per swipe phase to this file (NULL turns logging off).
void swipetap_set_log_path(const char *path);
