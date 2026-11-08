import AppKit
import SwipeTap

/// Swipe tuning for three-finger Space swipes. Experimental (private trackpad event fields).
/// - **Distance:** the slide moves further per finger distance while you swipe, so there's
///   less left for the Dock to coast after you lift off.
/// - **Release speed:** multiplies the speed at which your fingers leave the trackpad.
/// The slide still follows your fingers either way.
final class SwipeBoost: NSObject {
    static let gainChoices: [Double] = [1, 1.5, 2, 3]
    static let boostChoices: [Double] = [1, 2, 3, 5]
    /// How far towards the next Space the slide jumps at lift-off (0 = off).
    static let snapChoices: [(title: String, value: Double)] = [
        ("Normal", 0), ("Snappy", 0.6), ("Snappier", 0.8), ("Snappiest", 0.9),
    ]
    private let gainKey = "swipeGain"
    private let boostKey = "swipeBoost"
    private let snapKey = "swipeSnap"
    private var permissionTimer: Timer?

    private(set) var gain: Double = 1
    private(set) var boost: Double = 1
    private(set) var snap: Double = 0
    var isWaitingForPermission: Bool { permissionTimer != nil }

    override init() {
        super.init()
        let logs = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/SpaceApps")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        swipetap_set_log_path(logs.appending(path: "swipes.log").path)
        gain = max(1, UserDefaults.standard.double(forKey: gainKey))
        boost = max(1, UserDefaults.standard.double(forKey: boostKey))
        snap = max(0, UserDefaults.standard.double(forKey: snapKey))
        apply()
    }

    func setSnap(_ value: Double) {
        snap = value
        UserDefaults.standard.set(value, forKey: snapKey)
        apply()
    }

    func setGain(_ value: Double) {
        gain = value
        UserDefaults.standard.set(value, forKey: gainKey)
        apply()
    }

    func setBoost(_ value: Double) {
        boost = value
        UserDefaults.standard.set(value, forKey: boostKey)
        apply()
    }

    private func apply() {
        swipetap_set_gain(gain)
        swipetap_set_boost(boost)
        swipetap_set_snap(snap)
        guard gain > 1 || boost > 1 || snap > 0 else {
            swipetap_stop()
            stopWaiting()
            return
        }
        if swipetap_is_trusted(false) {
            _ = swipetap_start()
            return
        }
        // Ask macOS for Accessibility permission, then start as soon as it's granted.
        _ = swipetap_is_trusted(true)
        stopWaiting()
        permissionTimer = Timer.scheduledTimer(timeInterval: 1, target: self,
                                               selector: #selector(checkPermission), userInfo: nil, repeats: true)
    }

    @objc private func checkPermission() {
        guard swipetap_is_trusted(false) else { return }
        stopWaiting()
        _ = swipetap_start()
    }

    private func stopWaiting() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }
}
