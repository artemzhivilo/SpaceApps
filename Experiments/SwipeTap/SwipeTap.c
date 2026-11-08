#include "SwipeTap.h"

#include <ApplicationServices/ApplicationServices.h>
#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>

// Private CGEvent fields used for trackpad gestures (reverse-engineered; see iss).
static const CGEventField kFieldType     = 55;   // real event type
static const CGEventField kFieldHIDType  = 110;  // IOHIDEventType
static const CGEventField kFieldMotion   = 123;  // horizontal vs vertical
static const CGEventField kFieldProgress = 124;  // cumulative swipe distance
static const CGEventField kFieldVelX     = 129;
static const CGEventField kFieldVelY     = 130;
static const CGEventField kFieldPhase    = 132;  // began / changed / ended

enum { kTypeGesture = 29, kTypeDockControl = 30 };
enum { kHIDDockSwipe = 23, kMotionHorizontal = 1 };
enum { kPhaseBegan = 1, kPhaseChanged = 2, kPhaseEnded = 4, kPhaseCancelled = 8 };
// On macOS 27 a raw IOHID queue payload rides along in serialized field 4205.
enum { kPayloadTag = 4205, kIOHIDTypeVelocity = 9 };

static CFMachPortRef gTap;
static CFRunLoopSourceRef gSource;
static double gBoost = 1.0;
static double gGain = 1.0;
static double gSnap = 0.0;
static const double kMaxProgress = 0.95;  // never claim a full swipe; the Dock finishes it
static FILE *gLog;
static int gChangedLogged;

static void tap_log(const char *fmt, ...) {
    if (!gLog) return;
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tm;
    localtime_r(&tv.tv_sec, &tm);
    fprintf(gLog, "%02d:%02d:%02d.%03d  ", tm.tm_hour, tm.tm_min, tm.tm_sec, (int)(tv.tv_usec / 1000));
    va_list ap;
    va_start(ap, fmt);
    vfprintf(gLog, fmt, ap);
    va_end(ap);
    fputc('\n', gLog);
    fflush(gLog);
}

static int32_t rd32(const uint8_t *p) { int32_t v; memcpy(&v, p, 4); return v; }
static void wr32(uint8_t *p, int32_t v) { memcpy(p, &v, 4); }

// Serialized events store extra fields as [length: 2 bytes BE][tag: 2 bytes BE][bytes].
// Finds the raw IOHID payload (tag 4205) and checks it looks like a queue element.
static bool find_payload(const uint8_t *b, size_t n, size_t *off, size_t *len) {
    for (size_t i = 4; i + 4 <= n; i++) {
        if (b[i + 2] != (kPayloadTag >> 8) || b[i + 3] != (kPayloadTag & 0xFF)) continue;
        size_t l = ((size_t)b[i] << 8) | b[i + 1];
        if (l < 28 || i + 4 + l > n) continue;
        uint32_t count = (uint32_t)rd32(b + i + 4 + 24);
        if (count == 0 || count > 16) continue;
        *off = i + 4;
        *len = l;
        return true;
    }
    return false;
}

// Inside the payload: a 28-byte header (…, attribute length at 20, event count at 24),
// attributes, then events that each start with {size, type, options, depth}.
// Returns the offset of the given event type plus `field`, or -1.
static long find_in_payload(const uint8_t *p, size_t len, uint32_t wantType, size_t minSize, size_t field) {
    uint32_t attributes = (uint32_t)rd32(p + 20);
    uint32_t count = (uint32_t)rd32(p + 24);
    size_t o = 28 + (size_t)attributes;
    for (uint32_t k = 0; k < count && o + 16 <= len; k++) {
        uint32_t size = (uint32_t)rd32(p + o);
        uint32_t type = (uint32_t)rd32(p + o + 4);
        if (size < 16 || o + size > len) return -1;
        if (type == wantType && size >= minSize) return (long)(o + field);
        o += size;
    }
    return -1;
}

// Velocity event: base (16 bytes), then velocity x, y, z.
static long find_velocity(const uint8_t *p, size_t len) {
    return find_in_payload(p, len, kIOHIDTypeVelocity, 28, 16);
}

// Fluid touch gesture event: base (16), position x/y/z (12), swipe mask (4),
// motion (2), flavor (2), then swipe progress at offset 36.
enum { kIOHIDTypeFluidTouchGesture = 23 };
static long find_progress(const uint8_t *p, size_t len) {
    return find_in_payload(p, len, kIOHIDTypeFluidTouchGesture, 40, 36);
}

static double clamp_progress(double v) {
    if (v > kMaxProgress) return kMaxProgress;
    if (v < -kMaxProgress) return -kMaxProgress;
    return v;
}

// At lift-off: at least `gSnap` of the way, in the swipe's own direction.
static double snap_progress(double value) {
    if (gSnap <= 0.0 || value == 0.0) return value;
    double magnitude = fabs(value) > gSnap ? fabs(value) : gSnap;
    return clamp_progress(copysign(magnitude, value));
}

static CGEventRef callback(CGEventTapProxy proxy, CGEventType type, CGEventRef ev, void *ctx) {
    (void)proxy; (void)ctx;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (gTap && AXIsProcessTrusted()) CGEventTapEnable(gTap, true);
        tap_log("tap re-enabled (reason %d)", (int)type);
        return ev;
    }
    if (CGEventGetIntegerValueField(ev, kFieldType) != kTypeDockControl) return ev;
    if (CGEventGetIntegerValueField(ev, kFieldHIDType) != kHIDDockSwipe) return ev;
    if (CGEventGetIntegerValueField(ev, kFieldMotion) != kMotionHorizontal) return ev;

    int phase = (int)CGEventGetIntegerValueField(ev, kFieldPhase);
    double progress = CGEventGetDoubleValueField(ev, kFieldProgress);
    double vx = CGEventGetDoubleValueField(ev, kFieldVelX);
    double vy = CGEventGetDoubleValueField(ev, kFieldVelY);

    // Look at the hardware payload too, so the log shows where the speed lives.
    bool hasPayload = false;
    double payloadVX = 0;
    CFDataRef data = CGEventCreateData(kCFAllocatorDefault, ev);
    if (data) {
        size_t off = 0, len = 0;
        const uint8_t *b = CFDataGetBytePtr(data);
        if (find_payload(b, (size_t)CFDataGetLength(data), &off, &len)) {
            hasPayload = true;
            long v = find_velocity(b + off, len);
            if (v >= 0) payloadVX = rd32(b + off + v) / 65536.0;
        }
        CFRelease(data);
    }

    if (phase == kPhaseBegan) gChangedLogged = 0;
    bool logThis = phase != kPhaseChanged || gChangedLogged++ < 2;
    if (logThis) {
        tap_log("phase %d  progress %+.3f  vel %+.1f/%+.1f  payload %s vel %+.1f",
                phase, progress, vx, vy, hasPayload ? "yes" : "no", payloadVX);
    }

    bool doGain = gGain > 1.0 && progress != 0.0;
    bool doSnap = phase == kPhaseEnded && gSnap > 0.0 && progress != 0.0;
    bool doBoost = phase == kPhaseEnded && gBoost > 1.0 && (vx != 0 || payloadVX != 0);
    bool changeProgress = doGain || doSnap;
    if (!changeProgress && !doBoost) return ev;

    // Change the event's own fields...
    double newProgress = doGain ? clamp_progress(progress * gGain) : progress;
    if (doSnap) newProgress = snap_progress(newProgress);
    if (changeProgress) CGEventSetDoubleValueField(ev, kFieldProgress, newProgress);
    if (doBoost) {
        CGEventSetDoubleValueField(ev, kFieldVelX, vx * gBoost);
        CGEventSetDoubleValueField(ev, kFieldVelY, vy * gBoost);
    }

    // ...and the hardware payload, which macOS 27 checks too.
    CGEventRef result = ev;
    bool patchedPayload = false;
    if (hasPayload) {
        CFDataRef fresh = CGEventCreateData(kCFAllocatorDefault, ev);
        CFIndex n = fresh ? CFDataGetLength(fresh) : 0;
        uint8_t *bytes = n > 0 ? malloc((size_t)n) : NULL;
        if (bytes) {
            memcpy(bytes, CFDataGetBytePtr(fresh), (size_t)n);
            size_t off = 0, len = 0;
            if (find_payload(bytes, (size_t)n, &off, &len)) {
                long p = changeProgress ? find_progress(bytes + off, len) : -1;
                if (p >= 0) {
                    uint8_t *pp = bytes + off + p;
                    double scaled = rd32(pp) / 65536.0;
                    if (doGain) scaled = clamp_progress(scaled * gGain);
                    if (doSnap) scaled = snap_progress(scaled);
                    wr32(pp, (int32_t)(scaled * 65536.0));
                    patchedPayload = true;
                }
                long v = doBoost ? find_velocity(bytes + off, len) : -1;
                if (v >= 0) {
                    uint8_t *pv = bytes + off + v;
                    wr32(pv,     (int32_t)(rd32(pv)     * gBoost));   // velocity x
                    wr32(pv + 4, (int32_t)(rd32(pv + 4) * gBoost));   // velocity y
                    patchedPayload = true;
                }
            }
            if (patchedPayload) {
                CFDataRef patched = CFDataCreate(kCFAllocatorDefault, bytes, n);
                if (patched) {
                    CGEventRef replacement = CGEventCreateFromData(kCFAllocatorDefault, patched);
                    CFRelease(patched);
                    // The event system releases a returned replacement along with the original.
                    if (replacement) result = replacement;
                }
            }
            free(bytes);
        }
        if (fresh) CFRelease(fresh);
    }

    if (phase == kPhaseEnded) {
        tap_log("  lifted at %+.3f -> %+.3f (distance x%.1f, snap %.2f), speed x%.1f, %s",
                progress, newProgress, gGain, gSnap, doBoost ? gBoost : 1.0,
                result != ev ? "fields + payload" : "fields only");
    }
    return result;
}

bool swipetap_is_trusted(bool prompt) {
    const void *keys[] = { kAXTrustedCheckOptionPrompt };
    const void *values[] = { prompt ? kCFBooleanTrue : kCFBooleanFalse };
    CFDictionaryRef options = CFDictionaryCreate(NULL, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    bool trusted = AXIsProcessTrustedWithOptions(options);
    CFRelease(options);
    return trusted;
}

bool swipetap_start(void) {
    if (gTap) return true;
    if (!AXIsProcessTrusted()) return false;
    CGEventMask mask = (1ULL << kTypeGesture) | (1ULL << kTypeDockControl);
    gTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                            mask, callback, NULL);
    if (!gTap) { tap_log("could not create event tap"); return false; }
    gSource = CFMachPortCreateRunLoopSource(NULL, gTap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), gSource, kCFRunLoopCommonModes);
    CGEventTapEnable(gTap, true);
    tap_log("tap started, boost x%.1f", gBoost);
    return true;
}

void swipetap_stop(void) {
    if (!gTap) return;
    CGEventTapEnable(gTap, false);
    CFRunLoopRemoveSource(CFRunLoopGetMain(), gSource, kCFRunLoopCommonModes);
    CFRelease(gSource);
    CFRelease(gTap);
    gSource = NULL;
    gTap = NULL;
    tap_log("tap stopped");
}

bool swipetap_is_running(void) { return gTap != NULL; }

void swipetap_set_boost(double factor) {
    gBoost = factor < 1.0 ? 1.0 : factor;
    tap_log("boost set to x%.1f", gBoost);
}

void swipetap_set_gain(double factor) {
    gGain = factor < 1.0 ? 1.0 : factor;
    tap_log("distance gain set to x%.1f", gGain);
}

void swipetap_set_snap(double fraction) {
    gSnap = fraction <= 0.0 ? 0.0 : (fraction > kMaxProgress ? kMaxProgress : fraction);
    tap_log("snap set to %.2f", gSnap);
}

void swipetap_set_log_path(const char *path) {
    if (gLog) { fclose(gLog); gLog = NULL; }
    if (path) gLog = fopen(path, "a");
}
