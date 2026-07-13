import AppKit
import CoreGraphics
import PIIGuardCore
import UserNotifications
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let settings = Settings()
    private let scanner = AccessibilityScanner()
    private let capture = DelayedCapture()
    private let gate = PrivacyGate()
    private let recorder = FrameRecorder()
    private let snapshots = SnapshotStore()
    private var configuration: ConfigurationWindowController!
    private var preview: PreviewWindowController!
    private var statusItem: NSStatusItem!
    private var scanTimer: Timer?
    private var clearTimer: Timer?
    private let burstsPerSecond = 5.0
    private let scansPerBurst = 3
    private var approvalPromptPresented = false
    private var previewRequested = false
    private var previewRequiresFullBlock = true
    private var lifecycleGeneration: UInt64 = 0
    private var clearanceGeneration: UInt64 = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildWindows()
        buildStatusItem()
        wireCapture()
        scanner.onInvalidated = { [weak self] in
            guard let self, self.previewRequested else { return }
            self.snapshots.replace(nil)
            self.previewRequiresFullBlock = true
            self.updatePreviewState()
            self.performPrivacyBurst(generation: self.lifecycleGeneration)
        }
        updatePreviewState()
        requestAccessibilityIfNeeded()
        UNUserNotificationCenter.current().delegate = self
        configuration.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        previewRequested = false
        lifecycleGeneration &+= 1
        scanner.cancelPendingScans()
        scanner.stopObserving()
        snapshots.replace(nil)
        scanTimer?.invalidate()
        clearTimer?.invalidate()
        Task { await capture.stop() }
    }

    private func buildWindows() {
        configuration = ConfigurationWindowController(settings: settings)
        preview = PreviewWindowController()
        configuration.onStart = { [weak self] in self?.startPreview() }
        configuration.onStop = { [weak self] in self?.stopPreview() }
        configuration.onOpenPreview = { [weak self] in self?.showPreview() }
        configuration.onOpenPermissions = { [weak self] in self?.openRequiredPrivacySettings() }
        configuration.onSettingsChanged = { [weak self] in self?.settingsChanged() }
        configuration.onManualClear = { [weak self] in self?.approveSafeState() }
        configuration.onToggleRecording = { [weak self] in self?.toggleRecording() }
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: "PII Guard")
        statusItem.button?.title = " PII"
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open PII Guard", action: #selector(openConfiguration), keyEquivalent: "")
        open.target = self; menu.addItem(open)
        let preview = NSMenuItem(title: "Open Preview", action: #selector(openPreview), keyEquivalent: "")
        preview.target = self; menu.addItem(preview)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit PII Guard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func wireCapture() {
        capture.protectionDecision = { [weak self] time in
            guard let self else { return nil }
            return self.snapshots.decision(at: time, maximumAge: self.settings.protectionPreset.reconciliationInterval * 2, expectedGeneration: self.lifecycleGeneration)
        }
        capture.onFrame = { [weak self] image in
            guard let self else { return }
            self.preview.showFrame(image)
            // DelayedCapture has already applied the frame's capture-time
            // decision. Fan out that single protected render unchanged.
            self.recorder.append(image, blockedReason: nil)
        }
        capture.onError = { [weak self] error in
            guard let self else { return }
            self.previewRequested = false
            self.lifecycleGeneration &+= 1
            self.scanner.cancelPendingScans()
            self.scanner.stopObserving()
            self.snapshots.replace(nil)
            self.scanTimer?.invalidate(); self.scanTimer = nil
            self.clearTimer?.invalidate(); self.clearTimer = nil
            self.gate.reset("Capture stopped")
            self.previewRequiresFullBlock = true
            self.approvalPromptPresented = false
            if self.recorder.isRecording { self.stopRecording() }
            self.configuration.setRunning(false, status: error)
            self.updatePreviewState()
        }
        recorder.onError = { [weak self] error in
            guard let self else { return }
            self.configuration.setRecording(false)
            self.configuration.setRunning(self.capture.isRunning, status: error)
        }
    }

    private func requestAccessibilityIfNeeded() {
        if !scanner.isTrusted { scanner.requestPermission() }
        configuration.refreshPermissions()
    }

    private func startPreview() {
        previewRequested = true
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        scanner.cancelPendingScans()
        scanner.stopObserving()
        snapshots.replace(nil)
        scanner.startObserving()
        scanTimer?.invalidate(); scanTimer = nil
        clearTimer?.invalidate(); clearTimer = nil
        gate.requiredCleanChecks = settings.clearMode.requiredChecks(checksPerSecond: burstsPerSecond)
        gate.requiresManualApproval = settings.clearMode.requiresManualApproval
        gate.requiresClearanceDelay = true
        gate.reset(scanner.isTrusted ? "Filling delayed stream buffer" : "Accessibility permission required")
        previewRequiresFullBlock = true
        approvalPromptPresented = false
        configuration.setRunning(true, status: "Requesting Screen Recording access…")
        showPreview()
        updatePreviewState()

        let size = settings.captureResolution.size
        let delay = settings.delaySeconds
        let fps = settings.captureFPS
        let showsCursor = settings.showsCursor
        Task { [weak self] in
            guard let self else { return }
            do {
                try await capture.start(
                    delaySeconds: delay,
                    fps: fps,
                    width: size.width,
                    height: size.height,
                    showsCursor: showsCursor
                )
                guard previewRequested, lifecycleGeneration == generation else { return }
                configuration.setRunning(true, status: "Buffering for \(Int(delay)) seconds before checks begin")
                configuration.refreshPermissions()
                scheduleScanning(after: delay, generation: generation)
            } catch CaptureError.cancelled {
                return
            } catch {
                guard previewRequested, lifecycleGeneration == generation else { return }
                previewRequested = false
                scanner.cancelPendingScans()
                scanner.stopObserving()
                snapshots.replace(nil)
                scanTimer?.invalidate(); scanTimer = nil
                gate.reset("Screen Recording permission required")
                updatePreviewState()
                configuration.setRunning(false, status: "Screen Recording access is required. Grant it in System Settings, then start again.")
                configuration.refreshPermissions()
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func stopPreview() {
        previewRequested = false
        lifecycleGeneration &+= 1
        scanner.cancelPendingScans()
        scanner.stopObserving()
        snapshots.replace(nil)
        if recorder.isRecording { stopRecording() }
        scanTimer?.invalidate(); scanTimer = nil
        clearTimer?.invalidate(); clearTimer = nil
        gate.reset("Preview stopped")
        previewRequiresFullBlock = true
        approvalPromptPresented = false
        updatePreviewState()
        configuration.setRunning(false, status: "Preview stopped")
        Task { await capture.stop() }
    }

    private func scheduleScanning(after delay: Double, generation: UInt64) {
        scanTimer?.invalidate()
        gate.reset("Filling \(Int(delay))-second buffer")
        updatePreviewState()
        scanTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.previewRequested, self.lifecycleGeneration == generation else { return }
                self.startScanning(generation: generation)
            }
        }
        if let scanTimer { RunLoop.main.add(scanTimer, forMode: .common) }
    }

    private func startScanning(generation: UInt64) {
        guard previewRequested, lifecycleGeneration == generation else { return }
        scanTimer?.invalidate()
        let interval = settings.protectionPreset.reconciliationInterval
        configuration.setRunning(true, status: "Preview running · \(settings.protectionPreset.title)")
        scanTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.previewRequested, self.lifecycleGeneration == generation else { return }
                self.performPrivacyBurst(generation: generation)
            }
        }
        if let scanTimer { RunLoop.main.add(scanTimer, forMode: .common) }
        performPrivacyBurst(generation: generation)
    }

    private func performPrivacyBurst(generation: UInt64) {
        guard previewRequested, lifecycleGeneration == generation else { return }
        gate.requiredCleanChecks = settings.clearMode.requiredChecks(checksPerSecond: burstsPerSecond)
        gate.requiresManualApproval = settings.clearMode.requiresManualApproval
        gate.requiresClearanceDelay = true

        scanner.requestBurst(
            options: settings.detectionOptions,
            captureBounds: capture.targetBounds,
            count: scansPerBurst
        ) { [weak self] result in
            guard let self, self.previewRequested, self.lifecycleGeneration == generation else { return }
            switch result {
            case .inconclusive(let reason, let detections, let gaps, let requiresFullBlock, _):
                let bounds = self.capture.targetBounds
                let blocksFrame = requiresFullBlock || bounds == nil
                self.snapshots.replace(ProtectionSnapshot(generation: generation, capturedAt: ProcessInfo.processInfo.systemUptime, maskRects: detections.map(\.bounds), gapRects: gaps, captureBounds: bounds, usesOCR: self.settings.protectionPreset.usesOCR, detectionOptions: self.settings.detectionOptions, blocksFrame: blocksFrame, reason: reason))
                self.previewRequiresFullBlock = blocksFrame
                self.invalidateClearance(with: .inconclusive(reason))
            case .detected(let detections, let app):
                let masks = detections.map(\.bounds)
                let blocksFrame = masks.isEmpty || self.capture.targetBounds == nil
                self.snapshots.replace(ProtectionSnapshot(generation: generation, capturedAt: ProcessInfo.processInfo.systemUptime, maskRects: masks, captureBounds: self.capture.targetBounds, detectionOptions: self.settings.detectionOptions, blocksFrame: blocksFrame, reason: "PII detected"))
                self.previewRequiresFullBlock = blocksFrame
                let kinds = Set(detections.map { $0.kind.rawValue }).sorted().joined(separator: ", ")
                self.invalidateClearance(with: .detected("PII detected in \(app) · \(kinds)"))
            case .clean:
                self.snapshots.replace(ProtectionSnapshot(generation: generation, capturedAt: ProcessInfo.processInfo.systemUptime, maskRects: [], captureBounds: self.capture.targetBounds, detectionOptions: self.settings.detectionOptions, blocksFrame: false, reason: "Protected"))
                self.previewRequiresFullBlock = false
                let wasWaitingForDelay = self.gate.pendingClearanceDelay
                self.gate.update(.clean)
                self.updatePreviewState()
                if self.gate.pendingClearanceDelay && !wasWaitingForDelay {
                    self.scheduleClearanceDelay(generation: generation)
                }
            }
        }
    }

    private func invalidateClearance(with result: PrivacyScanResult) {
        clearTimer?.invalidate(); clearTimer = nil
        clearanceGeneration &+= 1
        gate.update(result)
        updatePreviewState()
    }

    private func updatePreviewState() {
        preview.setBlocked(previewRequiresFullBlock, reason: gate.reason, delay: settings.delaySeconds)
        configuration.setProtectionState(blocked: previewRequiresFullBlock, reason: gate.reason)
        configuration.setManualClearanceRequired(gate.pendingManualApproval)
    }

    private func settingsChanged() {
        snapshots.replace(nil)
        previewRequiresFullBlock = true
        gate.requiredCleanChecks = settings.clearMode.requiredChecks(checksPerSecond: burstsPerSecond)
        gate.requiresManualApproval = settings.clearMode.requiresManualApproval
        gate.requiresClearanceDelay = true
        gate.reset("Settings changed · checking again")
        scanner.cancelPendingScans()
        clearTimer?.invalidate(); clearTimer = nil
        approvalPromptPresented = false
        updatePreviewState()
        if settings.clearMode == .safe {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        if previewRequested { startPreview() }
    }

    private func scheduleClearanceDelay(generation: UInt64) {
        clearTimer?.invalidate()
        clearTimer = Timer.scheduledTimer(withTimeInterval: settings.delaySeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.previewRequested, self.lifecycleGeneration == generation else { return }
                self.gate.completeClearanceDelay()
                self.updatePreviewState()
                if self.gate.pendingManualApproval && !self.approvalPromptPresented {
                    self.requestSafeConfirmation()
                }
            }
        }
        if let clearTimer { RunLoop.main.add(clearTimer, forMode: .common) }
    }

    private func requestSafeConfirmation() {
        approvalPromptPresented = true
        let promptLifecycleGeneration = lifecycleGeneration
        let promptClearanceGeneration = clearanceGeneration
        let content = UNMutableNotificationContent()
        content.title = "PII Guard"
        content.body = "The clean-check threshold passed. Is it safe now?"
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "safe-now", content: content, trigger: nil))

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Is it safe now?"
        alert.informativeText = "PII Guard found no sensitive text during the required clean bursts. The preview stays black until you approve it."
        alert.addButton(withTitle: "Yes, unblock preview")
        alert.addButton(withTitle: "No, keep blocked")
        let response = alert.runModal()
        let responseIsCurrent = previewRequested
            && lifecycleGeneration == promptLifecycleGeneration
            && clearanceGeneration == promptClearanceGeneration
            && gate.pendingManualApproval
        approvalPromptPresented = false

        guard responseIsCurrent else {
            updatePreviewState()
            if gate.pendingManualApproval { requestSafeConfirmation() }
            return
        }
        if response == .alertFirstButtonReturn {
            approveSafeState()
        } else {
            gate.requireManualClearance()
            updatePreviewState()
        }
    }

    private func approveSafeState() {
        gate.approveManualClearance()
        approvalPromptPresented = false
        updatePreviewState()
    }

    private func toggleRecording() {
        if recorder.isRecording {
            stopRecording()
            return
        }
        guard capture.isRunning else {
            configuration.setRunning(false, status: "Start the preview before recording.")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save protected recording"
        panel.nameFieldStringValue = "PII Guard Recording.mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        recorder.start(url: url, fps: settings.captureFPS)
        configuration.setRecording(true)
    }

    private func stopRecording() {
        configuration.setRecording(false)
        recorder.stop { [weak self] url, failure in
            guard let self else { return }
            if let failure {
                self.configuration.setRunning(self.capture.isRunning, status: failure)
            } else if let url {
                self.configuration.setRunning(self.capture.isRunning, status: "Recording saved to \(url.lastPathComponent)")
            } else {
                self.configuration.setRunning(self.capture.isRunning, status: "Recording stopped before any frames were written.")
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    private func showPreview() {
        preview.showWindow(nil)
        preview.window?.orderFrontRegardless()
    }

    private func openRequiredPrivacySettings() {
        let pane = scanner.isTrusted ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openConfiguration() {
        configuration.showWindow(nil)
        configuration.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func openPreview() { showPreview() }
}
