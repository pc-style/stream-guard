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
    private var configuration: ConfigurationWindowController!
    private var preview: PreviewWindowController!
    private var statusItem: NSStatusItem!
    private var scanTimer: Timer?
    private var clearTimer: Timer?
    private let burstsPerSecond = 5.0
    private let scansPerBurst = 3
    private var approvalPromptPresented = false
    private var previewRequested = false
    private var lifecycleGeneration: UInt64 = 0
    private var clearanceGeneration: UInt64 = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildWindows()
        buildStatusItem()
        wireCapture()
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
        stopScanTimer()
        stopClearTimer()
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
        capture.onFrame = { [weak self] image in
            guard let self else { return }
            self.preview.showFrame(image)
            self.recorder.append(image, blockedReason: self.gate.isBlocked ? self.gate.reason : nil)
        }
        capture.onError = { [weak self] error in
            guard let self else { return }
            self.previewRequested = false
            self.lifecycleGeneration &+= 1
            self.scanner.cancelPendingScans()
            self.stopScanTimer()
            self.stopClearTimer()
            self.gate.reset("Capture stopped")
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
        stopScanTimer()
        stopClearTimer()
        gate.requiredCleanChecks = settings.clearMode.requiredChecks(checksPerSecond: burstsPerSecond)
        gate.requiresManualApproval = settings.clearMode.requiresManualApproval
        gate.requiresClearanceDelay = true
        gate.reset(scanner.isTrusted ? "Filling delayed stream buffer" : "Accessibility permission required")
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
                guard isCurrent(generation) else { return }
                configuration.setRunning(true, status: "Buffering for \(Int(delay)) seconds before checks begin")
                configuration.refreshPermissions()
                scheduleScanning(after: delay, generation: generation)
            } catch CaptureError.cancelled {
                return
            } catch {
                guard isCurrent(generation) else { return }
                previewRequested = false
                scanner.cancelPendingScans()
                stopScanTimer()
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
        if recorder.isRecording { stopRecording() }
        stopScanTimer()
        stopClearTimer()
        gate.reset("Preview stopped")
        approvalPromptPresented = false
        updatePreviewState()
        configuration.setRunning(false, status: "Preview stopped")
        Task { await capture.stop() }
    }

    private func scheduleScanning(after delay: Double, generation: UInt64) {
        stopScanTimer()
        gate.reset("Filling \(Int(delay))-second buffer")
        updatePreviewState()
        scanTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isCurrent(generation) else { return }
                self.startScanning(generation: generation)
            }
        }
        if let scanTimer { RunLoop.main.add(scanTimer, forMode: .common) }
    }

    private func startScanning(generation: UInt64) {
        guard isCurrent(generation) else { return }
        stopScanTimer()
        configuration.setRunning(true, status: "Preview running · 3 coalesced scans every 200 ms")
        scanTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / burstsPerSecond, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isCurrent(generation) else { return }
                self.performPrivacyBurst(generation: generation)
            }
        }
        if let scanTimer { RunLoop.main.add(scanTimer, forMode: .common) }
        performPrivacyBurst(generation: generation)
    }

    private func performPrivacyBurst(generation: UInt64) {
        guard isCurrent(generation) else { return }
        gate.requiredCleanChecks = settings.clearMode.requiredChecks(checksPerSecond: burstsPerSecond)
        gate.requiresManualApproval = settings.clearMode.requiresManualApproval
        gate.requiresClearanceDelay = true

        scanner.requestBurst(
            options: settings.detectionOptions,
            captureBounds: capture.targetBounds,
            count: scansPerBurst
        ) { [weak self] result in
            guard let self, self.isCurrent(generation) else { return }
            switch result {
            case .inconclusive(let reason):
                self.invalidateClearance(with: .inconclusive(reason))
            case .detected(let detections, let app):
                let kinds = Set(detections.map { $0.kind.rawValue }).sorted().joined(separator: ", ")
                self.invalidateClearance(with: .detected("PII detected in \(app) · \(kinds)"))
            case .clean:
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
        stopClearTimer()
        clearanceGeneration &+= 1
        gate.update(result)
        updatePreviewState()
    }

    private func updatePreviewState() {
        preview.setBlocked(gate.isBlocked, reason: gate.reason, delay: settings.delaySeconds)
        configuration.setProtectionState(blocked: gate.isBlocked, reason: gate.reason)
        configuration.setManualClearanceRequired(gate.pendingManualApproval)
    }

    private func settingsChanged() {
        gate.requiredCleanChecks = settings.clearMode.requiredChecks(checksPerSecond: burstsPerSecond)
        gate.requiresManualApproval = settings.clearMode.requiresManualApproval
        gate.requiresClearanceDelay = true
        gate.reset("Settings changed · checking again")
        scanner.cancelPendingScans()
        stopClearTimer()
        approvalPromptPresented = false
        updatePreviewState()
        if settings.clearMode == .safe {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        if previewRequested { startPreview() }
    }

    private func scheduleClearanceDelay(generation: UInt64) {
        stopClearTimer()
        clearTimer = Timer.scheduledTimer(withTimeInterval: settings.delaySeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isCurrent(generation) else { return }
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

    private func isCurrent(_ generation: UInt64) -> Bool {
        previewRequested && lifecycleGeneration == generation
    }

    private func stopScanTimer() {
        scanTimer?.invalidate()
        scanTimer = nil
    }

    private func stopClearTimer() {
        clearTimer?.invalidate()
        clearTimer = nil
    }
}
