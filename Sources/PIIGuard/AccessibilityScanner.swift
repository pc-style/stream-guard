import AppKit
import ApplicationServices
import PIIGuardCore

struct ScreenDetection {
    let rect: CGRect
    let kind: SensitiveKind
}

enum ScanResult {
    case detections([ScreenDetection], app: String)
    case unsupported(String)
    case unavailable
}

final class AccessibilityScanner {
    private let engine = DetectionEngine()
    private let maxElements = 1_500

    var isTrusted: Bool { AXIsProcessTrusted() }

    func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func scan(options: DetectionOptions) -> ScanResult {
        guard isTrusted else { return .unavailable }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return .detections([], app: "PII Guard")
        }

        let root = AXUIElementCreateApplication(app.processIdentifier)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement], !windows.isEmpty else {
            return .unsupported(app.localizedName ?? "This app")
        }

        var output: [ScreenDetection] = []
        var visited = 0
        for window in windows.prefix(4) {
            walk(window, options: options, output: &output, visited: &visited)
            if visited >= maxElements { break }
        }
        return .detections(output, app: app.localizedName ?? "Current app")
    }

    private func walk(_ element: AXUIElement, options: DetectionOptions, output: inout [ScreenDetection], visited: inout Int) {
        guard visited < maxElements else { return }
        visited += 1

        if let visible = booleanAttribute(element, "AXVisible"), !visible { return }

        if let text = stringAttribute(element, kAXValueAttribute), text.count <= 20_000 {
            for detection in engine.detect(in: text, options: options) {
                let preciseBounds = bounds(for: detection.range, in: element)
                let conservativeFrame = text.count <= 500 ? frame(of: element) : nil
                if let rect = preciseBounds ?? conservativeFrame,
                   rect.width > 1, rect.height > 1, isOnScreen(rect) {
                    output.append(ScreenDetection(rect: rect.insetBy(dx: -2, dy: -1), kind: detection.kind))
                }
            }
        }

        var childrenValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
           let children = childrenValue as? [AXUIElement] {
            for child in children.prefix(300) {
                walk(child, options: options, output: &output, visited: &visited)
                if visited >= maxElements { break }
            }
        }
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func booleanAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    private func isOnScreen(_ rect: CGRect) -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { CGDisplayBounds($0).intersects(rect) }
    }

    private func bounds(for range: NSRange, in element: AXUIElement) -> CGRect? {
        var range = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &result
        ) == .success, let axValue = result, CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(axValue as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}
