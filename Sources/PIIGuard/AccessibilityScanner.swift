import AppKit
import ApplicationServices
import PIIGuardCore

struct ScreenDetection: Sendable {
    let kind: SensitiveKind
}

enum ScanResult: Sendable {
    case clean(app: String)
    case detected([ScreenDetection], app: String)
    case inconclusive(String)
}

final class AccessibilityScanner: @unchecked Sendable {
    private struct Request {
        let generation: UInt64
        let options: DetectionOptions
        let captureBounds: CGRect?
        let count: Int
        let completion: (ScanResult) -> Void
    }

    private let engine = DetectionEngine()
    private let maxElements = 1_500
    private let maxWindowsPerApp = 4
    private let scanTimeout: TimeInterval = 0.15
    private let scanQueue = DispatchQueue(label: "dev.pcstyle.piiguard.accessibility-scan", qos: .userInitiated)
    private let stateLock = NSLock()
    private var generation: UInt64 = 0
    private var scanInFlight = false
    private var pendingRequest: Request?

    var isTrusted: Bool { AXIsProcessTrusted() }

    func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func requestBurst(
        options: DetectionOptions,
        captureBounds: CGRect?,
        count: Int,
        completion: @escaping (ScanResult) -> Void
    ) {
        stateLock.lock()
        let request = Request(
            generation: generation,
            options: options,
            captureBounds: captureBounds,
            count: max(1, count),
            completion: completion
        )
        if scanInFlight {
            pendingRequest = request
            stateLock.unlock()
            return
        }
        scanInFlight = true
        stateLock.unlock()
        execute(request)
    }

    func cancelPendingScans() {
        stateLock.lock()
        generation &+= 1
        pendingRequest = nil
        stateLock.unlock()
    }

    private func execute(_ request: Request) {
        scanQueue.async { [weak self] in
            guard let self else { return }
            let result = performBurst(request)

            stateLock.lock()
            let shouldDeliver = request.generation == generation
            let next = pendingRequest
            pendingRequest = nil
            if next == nil { scanInFlight = false }
            stateLock.unlock()

            if shouldDeliver {
                DispatchQueue.main.async { request.completion(result) }
            }
            if let next { execute(next) }
        }
    }

    private func performBurst(_ request: Request) -> ScanResult {
        var lastClean: ScanResult = .clean(app: "captured display")
        for _ in 0..<request.count {
            let result = scan(options: request.options, captureBounds: request.captureBounds)
            switch result {
            case .clean:
                lastClean = result
            case .detected, .inconclusive:
                return result
            }
        }
        return lastClean
    }

    private func scan(options: DetectionOptions, captureBounds: CGRect?) -> ScanResult {
        guard isTrusted else { return .inconclusive("Accessibility permission required") }
        guard let captureBounds else { return .inconclusive("Capture target unavailable") }
        guard let apps = capturedApplications(in: captureBounds), !apps.isEmpty else {
            return .inconclusive("No supported app window on the captured display")
        }

        // Apps that cannot be covered by the Accessibility scan are skipped
        // (recording the first failure) instead of aborting the burst, so a
        // single unsupported app cannot mask detections in the remaining
        // apps. The result stays fail-closed: any coverage failure still
        // yields .inconclusive after every app has been given a chance to
        // produce a detection.
        let deadline = ProcessInfo.processInfo.systemUptime + scanTimeout
        var coverageFailure: String?
        var scannedApps: [String] = []
        for app in apps {
            let appName = app.localizedName ?? "Captured app"
            let root = AXUIElementCreateApplication(app.processIdentifier)
            var windowsValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windowsValue) == .success,
                  let allWindows = windowsValue as? [AXUIElement], !allWindows.isEmpty else {
                if coverageFailure == nil { coverageFailure = "Accessibility unsupported in \(appName)" }
                continue
            }
            // Only windows on the captured display count toward the window
            // limit or need scanning; include windows with unreadable frames
            // conservatively.
            let windows = allWindows.filter { window in
                guard let frame = frame(of: window) else { return true }
                return captureBounds.intersects(frame)
            }
            guard !windows.isEmpty else {
                if coverageFailure == nil { coverageFailure = "Unable to match \(appName) windows to the captured display" }
                continue
            }
            guard windows.count <= maxWindowsPerApp else {
                if coverageFailure == nil { coverageFailure = "Accessibility window limit exceeded in \(appName)" }
                continue
            }

            var output: [ScreenDetection] = []
            var visited = 0
            var complete = true
            var foundReadableText = false
            for window in windows {
                walk(
                    window,
                    options: options,
                    output: &output,
                    visited: &visited,
                    complete: &complete,
                    foundReadableText: &foundReadableText,
                    deadline: deadline
                )
                if !complete { break }
            }
            guard complete else {
                let reason = ProcessInfo.processInfo.systemUptime >= deadline
                    ? "Accessibility scan timed out in \(appName)"
                    : "Accessibility scan incomplete in \(appName)"
                return .inconclusive(reason)
            }
            if !output.isEmpty { return .detected(output, app: appName) }
            guard foundReadableText else {
                if coverageFailure == nil { coverageFailure = "No readable Accessibility text in \(appName)" }
                continue
            }
            scannedApps.append(appName)
        }

        if let coverageFailure { return .inconclusive(coverageFailure) }
        guard let firstApp = scannedApps.first else {
            return .inconclusive("No supported app window on the captured display")
        }
        return .clean(app: scannedApps.count == 1 ? firstApp : "captured display")
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue, CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func capturedApplications(in captureBounds: CGRect) -> [NSRunningApplication]? {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var seen: Set<pid_t> = []
        var apps: [NSRunningApplication] = []
        for info in windowInfo {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  !seen.contains(pid),
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 1, frame.height > 1, captureBounds.intersects(frame),
                  let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy != .prohibited, !app.isHidden else { continue }
            seen.insert(pid)
            apps.append(app)
        }
        return apps
    }

    private func walk(
        _ element: AXUIElement,
        options: DetectionOptions,
        output: inout [ScreenDetection],
        visited: inout Int,
        complete: inout Bool,
        foundReadableText: inout Bool,
        deadline: TimeInterval
    ) {
        guard complete else { return }
        guard ProcessInfo.processInfo.systemUptime < deadline else { complete = false; return }
        guard visited < maxElements else { complete = false; return }
        visited += 1

        var visibleValue: CFTypeRef?
        let visibleResult = AXUIElementCopyAttributeValue(element, "AXVisible" as CFString, &visibleValue)
        if visibleResult == .success, let visible = visibleValue as? Bool, !visible { return }
        if visibleResult != .success && visibleResult != .noValue && visibleResult != .attributeUnsupported {
            complete = false
            return
        }

        var textValue: CFTypeRef?
        let textResult = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &textValue)
        if textResult == .success {
            if let text = textValue as? String {
                guard text.count <= 20_000 else { complete = false; return }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    foundReadableText = true
                }
                output.append(contentsOf: engine.detect(in: text, options: options).map { ScreenDetection(kind: $0.kind) })
            }
        } else if textResult != .noValue && textResult != .attributeUnsupported {
            complete = false
            return
        }

        var childrenValue: CFTypeRef?
        let childrenResult = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
        if childrenResult == .success, let children = childrenValue as? [AXUIElement] {
            guard children.count <= 300 else { complete = false; return }
            for child in children {
                walk(
                    child,
                    options: options,
                    output: &output,
                    visited: &visited,
                    complete: &complete,
                    foundReadableText: &foundReadableText,
                    deadline: deadline
                )
                if !complete { break }
            }
        } else if childrenResult != .noValue && childrenResult != .attributeUnsupported {
            complete = false
        }
    }
}
