import AppKit
import ApplicationServices
import PIIGuardCore

struct ScreenDetection: Sendable {
    let kind: SensitiveKind
    let range: NSRange
    let bounds: CGRect
}

enum ScanResult: Sendable {
    case clean(app: String)
    case detected([ScreenDetection], app: String)
    case inconclusive(String, detections: [ScreenDetection], gaps: [CGRect], requiresFullBlock: Bool, hasUnscopedGap: Bool)
}

final class AccessibilityScanner: @unchecked Sendable {
    private struct Request {
        let generation: UInt64
        let observationRevision: UInt64
        let options: DetectionOptions
        let captureBounds: CGRect?
        let count: Int
        let timeout: TimeInterval
        let completion: (ScanResult) -> Void
    }

    private let engine = DetectionEngine()
    private let maxElements = 1_500
    private let maxWindowsPerApp = 4
    private let scanQueue = DispatchQueue(label: "dev.pcstyle.piiguard.accessibility-scan", qos: .userInitiated)
    private let stateLock = NSLock()
    private var generation: UInt64 = 0
    private var observationRevision: UInt64 = 0
    private var scanInFlight = false
    private var pendingRequest: Request?
    private var observerRecords: [pid_t: ObserverRecord] = [:]
    private var invalidationScheduled = false
    private var observersActive = false
    private var observerGeneration: UInt64 = 0
    var onInvalidated: (() -> Void)?

    private struct ObserverRecord {
        let observer: AXObserver
        let source: CFRunLoopSource
        let registrations: [(AXUIElement, CFString)]
    }

    var isTrusted: Bool { AXIsProcessTrusted() }

    func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func requestBurst(
        options: DetectionOptions,
        captureBounds: CGRect?,
        count: Int,
        timeout: TimeInterval,
        completion: @escaping (ScanResult) -> Void
    ) {
        stateLock.lock()
        let request = Request(
            generation: generation,
            observationRevision: observationRevision,
            options: options,
            captureBounds: captureBounds,
            count: max(1, count),
            timeout: max(0.1, timeout),
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

    func startObserving() {
        dispatchPrecondition(condition: .onQueue(.main))
        observerGeneration &+= 1
        observersActive = true
    }

    /// Must be called on the main thread; observer sources and teardown share that run loop.
    func stopObserving() {
        dispatchPrecondition(condition: .onQueue(.main))
        for record in observerRecords.values {
            for (element, notification) in record.registrations {
                AXObserverRemoveNotification(record.observer, element, notification)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), record.source, .commonModes)
        }
        observerRecords.removeAll()
        invalidationScheduled = false
        observerGeneration &+= 1
        observersActive = false
    }

    private func reconcileObservers(pids: Set<pid_t>) {
        let expectedGeneration = observerGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.observersActive, self.observerGeneration == expectedGeneration else { return }
            self.reconcileObserversOnMain(pids: pids)
        }
    }

    private func reconcileObserversOnMain(pids: Set<pid_t>) {
        for pid in Set(observerRecords.keys).subtracting(pids) {
            guard let record = observerRecords.removeValue(forKey: pid) else { continue }
            for (element, notification) in record.registrations { AXObserverRemoveNotification(record.observer, element, notification) }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), record.source, .commonModes)
        }
        for pid in pids where observerRecords[pid] == nil {
            var observer: AXObserver?
            let callback: AXObserverCallback = { _, _, _, context in
                guard let context else { return }
                let scanner = Unmanaged<AccessibilityScanner>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async { scanner.scheduleInvalidation() }
            }
            guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { continue }
            let root = AXUIElementCreateApplication(pid)
            let rootNotifications = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, "AXUIElementDestroyed"].map { $0 as CFString }
            let context = Unmanaged.passUnretained(self).toOpaque()
            var registrations: [(AXUIElement, CFString)] = []
            for notification in rootNotifications where AXObserverAddNotification(observer, root, notification, context) == .success {
                registrations.append((root, notification))
            }
            var windowsValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windowsValue) == .success,
               let windows = windowsValue as? [AXUIElement] {
                // Window-root value/layout notifications are extremely noisy
                // in Chromium-style apps and do not reliably represent text
                // descendant changes. They can keep protection permanently
                // dirty. Observe stable window geometry/title changes here;
                // periodic reconciliation remains authoritative for body text.
                let windowNotifications = [kAXMovedNotification, kAXResizedNotification, kAXTitleChangedNotification].map { $0 as CFString }
                for window in windows.prefix(maxWindowsPerApp) {
                    for notification in windowNotifications where AXObserverAddNotification(observer, window, notification, context) == .success {
                        registrations.append((window, notification))
                    }
                }
            }
            let source = AXObserverGetRunLoopSource(observer)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            observerRecords[pid] = ObserverRecord(observer: observer, source: source, registrations: registrations)
        }
    }

    private func scheduleInvalidation() {
        stateLock.withLock { observationRevision &+= 1 }
        onInvalidated?() // Dirty immediately; only rescan scheduling is coalesced.
        guard !invalidationScheduled else { return }
        invalidationScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.invalidationScheduled = false
            self.onInvalidated?()
        }
    }

    private func execute(_ request: Request) {
        scanQueue.async { [weak self] in
            guard let self else { return }
            let result = performBurst(request)

            stateLock.lock()
            let shouldDeliver = request.generation == generation && request.observationRevision == observationRevision
            let next = pendingRequest
            pendingRequest = nil
            if next == nil { scanInFlight = false }
            stateLock.unlock()

            if shouldDeliver {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.requestIsCurrent(request) else { return }
                    request.completion(result)
                }
            }
            if let next { execute(next) }
        }
    }

    private func requestIsCurrent(_ request: Request) -> Bool {
        stateLock.withLock {
            request.generation == generation && request.observationRevision == observationRevision
        }
    }

    private func performBurst(_ request: Request) -> ScanResult {
        var lastClean: ScanResult = .clean(app: "captured display")
        for _ in 0..<request.count {
            let result = scan(options: request.options, captureBounds: request.captureBounds, timeout: request.timeout)
            switch result {
            case .clean:
                lastClean = result
            case .detected, .inconclusive:
                return result
            }
        }
        return lastClean
    }

    private func scan(options: DetectionOptions, captureBounds: CGRect?, timeout: TimeInterval) -> ScanResult {
        guard isTrusted else { return .inconclusive("Accessibility permission required", detections: [], gaps: [], requiresFullBlock: true, hasUnscopedGap: true) }
        guard let captureBounds else { return .inconclusive("Capture target unavailable", detections: [], gaps: [], requiresFullBlock: true, hasUnscopedGap: true) }
        guard let inventory = capturedWindowInventory(in: captureBounds) else {
            return .inconclusive("Captured window inventory unavailable", detections: [], gaps: [], requiresFullBlock: true, hasUnscopedGap: true)
        }
        var seenPIDs: Set<pid_t> = []
        let apps = inventory.compactMap(\.app).filter { seenPIDs.insert($0.processIdentifier).inserted }
        reconcileObservers(pids: Set(apps.map(\.processIdentifier)))
        guard !inventory.isEmpty else {
            return .inconclusive("No content window on the captured display", detections: [], gaps: [], requiresFullBlock: false, hasUnscopedGap: false)
        }

        // Apps that cannot be covered by the Accessibility scan are skipped
        // (recording the first failure) instead of aborting the burst, so a
        // single unsupported app cannot mask detections in the remaining
        // apps. The result stays fail-closed: any coverage failure still
        // yields .inconclusive after every app has been given a chance to
        // produce a detection.
        var coverageFailure: String?
        var gaps: [CGRect] = []
        var allDetections: [ScreenDetection] = []
        var hasUnscopedGap = false
        let unmapped = inventory.filter { $0.app == nil }
        if !unmapped.isEmpty {
            coverageFailure = "Some captured windows do not expose an application"
            gaps.append(contentsOf: visibleGapRects(for: unmapped, in: inventory))
        }
        var scannedApps: [String] = []
        for app in apps {
            // Each process gets its own budget. A slow app earlier in the
            // WindowServer order must not consume the time available to a
            // browser or terminal scanned later.
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            let appName = app.localizedName ?? "Captured app"
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, Float(timeout))
            var windowsValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windowsValue) == .success,
                  let allWindows = windowsValue as? [AXUIElement], !allWindows.isEmpty else {
                if coverageFailure == nil { coverageFailure = "Accessibility unsupported in \(appName)" }
                let capturedAppWindows = inventory.filter { $0.pid == app.processIdentifier }
                gaps.append(contentsOf: visibleGapRects(for: capturedAppWindows, in: inventory))
                hasUnscopedGap = hasUnscopedGap || capturedAppWindows.isEmpty
                continue
            }
            // Only AX windows that can be matched to a captured CG window
            // should be traversed. Finder exposes additional desktop and
            // hidden AX windows whose full trees are both irrelevant to this
            // capture and unusually large. Captured windows without usable AX
            // geometry are represented as gaps below instead of traversing an
            // unrelated tree.
            let capturedAppWindows = inventory.filter { $0.pid == app.processIdentifier }
            let windows = allWindows.filter { window in
                guard let axFrame = frame(of: window), captureBounds.intersects(axFrame) else { return false }
                return capturedAppWindows.contains { captured in
                    let overlap = axFrame.intersection(captured.bounds)
                    let smallerArea = min(axFrame.width * axFrame.height, captured.bounds.width * captured.bounds.height)
                    return !overlap.isNull && smallerArea > 0 && overlap.width * overlap.height / smallerArea >= 0.5
                }
            }
            guard !windows.isEmpty else {
                if coverageFailure == nil { coverageFailure = "Unable to match \(appName) windows to the captured display" }
                gaps.append(contentsOf: visibleGapRects(for: capturedAppWindows, in: inventory))
                hasUnscopedGap = hasUnscopedGap || capturedAppWindows.isEmpty
                continue
            }
            guard windows.count <= maxWindowsPerApp else {
                if coverageFailure == nil { coverageFailure = "Accessibility window limit exceeded in \(appName)" }
                gaps.append(contentsOf: visibleGapRects(for: capturedAppWindows, in: inventory))
                hasUnscopedGap = hasUnscopedGap || capturedAppWindows.isEmpty
                continue
            }

            let axFrames = windows.compactMap { frame(of: $0) }
            let unmatchedCapturedWindows = inventory.filter { captured in
                guard captured.pid == app.processIdentifier else { return false }
                return !axFrames.contains { axFrame in
                    let overlap = axFrame.intersection(captured.bounds)
                    let smallerArea = min(axFrame.width * axFrame.height, captured.bounds.width * captured.bounds.height)
                    return !overlap.isNull && smallerArea > 0 && overlap.width * overlap.height / smallerArea >= 0.5
                }
            }
            if !unmatchedCapturedWindows.isEmpty {
                gaps.append(contentsOf: visibleGapRects(for: unmatchedCapturedWindows, in: inventory))
                if coverageFailure == nil { coverageFailure = "A captured window is not represented by Accessibility" }
            }

            var output: [ScreenDetection] = []
            var visited = 0
            var complete = true
            for window in windows {
                var foundReadableText = false
                walk(
                    window,
                    options: options,
                    output: &output,
                    visited: &visited,
                    complete: &complete,
                    foundReadableText: &foundReadableText,
                    captureBounds: captureBounds,
                    deadline: deadline
                )
                if !complete { break }
                if !foundReadableText {
                    if let bounds = frame(of: window)?.intersection(captureBounds), !bounds.isNull { gaps.append(bounds) }
                    else { hasUnscopedGap = true }
                    if coverageFailure == nil { coverageFailure = "A visible window has no readable Accessibility value" }
                }
            }
            guard complete else {
                let reason = ProcessInfo.processInfo.systemUptime >= deadline
                    ? "Accessibility scan timed out in \(appName)"
                    : "Accessibility scan incomplete in \(appName)"
                // The CG inventory is authoritative for captured geometry and
                // remains usable even when an AX call fails mid-traversal.
                gaps.append(contentsOf: visibleGapRects(for: capturedAppWindows, in: inventory))
                hasUnscopedGap = hasUnscopedGap || capturedAppWindows.isEmpty
                allDetections.append(contentsOf: output)
                if coverageFailure == nil { coverageFailure = reason }
                continue
            }
            allDetections.append(contentsOf: output)
            if requiresFrameVerification(app) {
                gaps.append(contentsOf: visibleGapRects(for: capturedAppWindows, in: inventory))
                if coverageFailure == nil {
                    coverageFailure = "Browser coverage cannot be verified completely in \(appName)"
                }
            }
            scannedApps.append(appName)
        }

        if let coverageFailure { return .inconclusive(coverageFailure, detections: allDetections, gaps: gaps, requiresFullBlock: hasUnscopedGap, hasUnscopedGap: hasUnscopedGap) }
        if !allDetections.isEmpty { return .detected(allDetections, app: scannedApps.count == 1 ? scannedApps[0] : "captured display") }
        guard let firstApp = scannedApps.first else {
            return .inconclusive("No supported app window on the captured display", detections: [], gaps: gaps, requiresFullBlock: hasUnscopedGap, hasUnscopedGap: hasUnscopedGap)
        }
        return .clean(app: scannedApps.count == 1 ? firstApp : "captured display")
    }

    private func requiresFrameVerification(_ app: NSRunningApplication) -> Bool {
        let identity = [app.bundleIdentifier, app.localizedName]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return [
            "safari", "chrome", "chromium", "helium", "firefox",
            "arc", "brave", "edge", "opera", "vivaldi"
        ].contains { identity.contains($0) }
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

    private struct CapturedWindow {
        let id: CGWindowID
        let pid: pid_t
        let bounds: CGRect
        let app: NSRunningApplication?
    }

    private func capturedWindowInventory(in captureBounds: CGRect) -> [CapturedWindow]? {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var windows: [CapturedWindow] = []
        for info in windowInfo {
            guard let idValue = info[kCGWindowNumber as String] as? NSNumber,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 1, frame.height > 1, captureBounds.intersects(frame),
                  (info[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            let clipped = frame.intersection(captureBounds)
            let app = NSRunningApplication(processIdentifier: pid)
            windows.append(CapturedWindow(id: CGWindowID(idValue.uint32Value), pid: pid, bounds: clipped, app: app?.isHidden == false ? app : nil))
        }
        return windows
    }

    /// CGWindowList is ordered front-to-back. Remove pixels covered by higher
    /// windows so an inaccessible background app does not black out the
    /// foreground app that is actually visible in the capture.
    private func visibleGapRects(for targets: [CapturedWindow], in inventory: [CapturedWindow]) -> [CGRect] {
        targets.flatMap { target in
            var visible = [target.bounds]
            for occluder in inventory {
                if occluder.id == target.id { break }
                visible = visible.flatMap { subtract(occluder.bounds, from: $0) }
                if visible.isEmpty { break }
            }
            return visible
        }
    }

    private func subtract(_ occluder: CGRect, from source: CGRect) -> [CGRect] {
        let overlap = source.intersection(occluder)
        guard !overlap.isNull, !overlap.isEmpty else { return [source] }
        var pieces: [CGRect] = []
        if overlap.minY > source.minY {
            pieces.append(CGRect(x: source.minX, y: source.minY, width: source.width, height: overlap.minY - source.minY))
        }
        if overlap.maxY < source.maxY {
            pieces.append(CGRect(x: source.minX, y: overlap.maxY, width: source.width, height: source.maxY - overlap.maxY))
        }
        if overlap.minX > source.minX {
            pieces.append(CGRect(x: source.minX, y: overlap.minY, width: overlap.minX - source.minX, height: overlap.height))
        }
        if overlap.maxX < source.maxX {
            pieces.append(CGRect(x: overlap.maxX, y: overlap.minY, width: source.maxX - overlap.maxX, height: overlap.height))
        }
        return pieces.filter { !$0.isEmpty }
    }

    private func walk(
        _ element: AXUIElement,
        options: DetectionOptions,
        output: inout [ScreenDetection],
        visited: inout Int,
        complete: inout Bool,
        foundReadableText: inout Bool,
        captureBounds: CGRect,
        deadline: TimeInterval
    ) {
        guard complete else { return }
        guard ProcessInfo.processInfo.systemUptime < deadline else { complete = false; return }
        guard visited < maxElements else { complete = false; return }
        visited += 1

        let attributes = [
            "AXVisible" as CFString,
            kAXValueAttribute as CFString,
            kAXTitleAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            kAXVisibleChildrenAttribute as CFString
        ] as CFArray
        var attributeValues: CFArray?
        let attributesResult = AXUIElementCopyMultipleAttributeValues(
            element,
            attributes,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &attributeValues
        )
        guard attributesResult == .success,
              let values = attributeValues as? [Any],
              values.count == 5 else {
            complete = false
            return
        }
        if let visible = values[0] as? Bool, !visible { return }

        for (index, attribute) in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].enumerated() {
            if let text = values[index + 1] as? String {
                guard text.count <= 20_000 else { complete = false; return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if attribute == kAXValueAttribute && trimmed.count >= 2 && trimmed.rangeOfCharacter(from: .alphanumerics) != nil {
                    foundReadableText = true
                }
                let detections = engine.detect(in: text, options: options)
                for detection in detections {
                    var detectionBounds: CGRect?
                    // AX range offsets are UTF-16. Only AXValue has a defined
                    // relationship with AXBoundsForRange.
                    if attribute == kAXValueAttribute {
                        var range = CFRange(location: detection.range.location, length: detection.range.length)
                        if let rangeValue = AXValueCreate(.cfRange, &range) {
                            var boundsValue: CFTypeRef?
                            if AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &boundsValue) == .success,
                               let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID() {
                                var rect = CGRect.zero
                                if AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect) { detectionBounds = rect }
                            }
                        }
                    }
                    // Titles/descriptions and unsupported text geometry are
                    // fail-closed at element granularity.
                    if detectionBounds == nil { detectionBounds = frame(of: element) }
                    guard let rect = detectionBounds?.intersection(captureBounds), !rect.isNull, rect.width > 0, rect.height > 0 else {
                        complete = false; return
                    }
                    output.append(ScreenDetection(kind: detection.kind, range: detection.range, bounds: rect))
                }
            }
        }

        // Finder and other collection-heavy apps can expose thousands of
        // off-screen descendants through AXChildren. Prefer AXVisibleChildren
        // when available so the bounded walk covers what is actually present
        // in the captured pixels.
        var childrenValue: CFTypeRef? = values[4] as CFTypeRef
        let visibleChildrenResult: AXError = values[4] is [AXUIElement] ? .success : .attributeUnsupported
        let childrenResult: AXError
        if visibleChildrenResult == .success {
            childrenResult = visibleChildrenResult
        } else {
            childrenValue = nil
            childrenResult = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
        }
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
                    captureBounds: captureBounds,
                    deadline: deadline
                )
                if !complete { break }
            }
        } else if childrenResult != .noValue && childrenResult != .attributeUnsupported {
            complete = false
        }
    }
}
