import ApplicationServices
import CoreGraphics

/// Small helpers for reading other apps' accessibility trees.
enum AX {
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, "AXChildren") as? [AXUIElement]) ?? []
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let s = attribute(element, name) as? String, !s.isEmpty else { return nil }
        return s
    }

    static func identifier(_ element: AXUIElement) -> String? { string(element, "AXIdentifier") }

    /// Frame in screen coordinates with the origin at the top left of the main display.
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = attribute(element, "AXPosition"), let s = attribute(element, "AXSize"),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    static func press(_ element: AXUIElement) {
        AXUIElementPerformAction(element, "AXPress" as CFString)
    }

    /// The first descendant (breadth-first, a few levels deep) with this identifier.
    static func find(_ root: AXUIElement, id: String, depth: Int = 4) -> AXUIElement? {
        var level = [root]
        for _ in 0..<depth {
            var next: [AXUIElement] = []
            for element in level {
                for child in children(element) {
                    if identifier(child) == id { return child }
                    next.append(child)
                }
            }
            level = next
        }
        return nil
    }
}
