import AppKit
import CoreGraphics
import PIIGuardCore
import UserNotifications
import UniformTypeIdentifiers

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildWindows()
        buildStatusItem()
        wireCapture()
        requestAccessibilityIfNeeded()
        UNUserNotificationCenter.current().delegate = self
        configuration.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
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
            self?.gate.reset("Capture stopped")
            self?.configuration.setRunning(false, status: error)
            self?.updatePreviewState()
        }
    }

    private func requestAccessibilityIfNeeded() {
        if !scanner.isTrusted { scanner.requestPermission() }
        configuration.refreshPermissions()
    }

    private func startPreview() {
        scanTimer?.invalidate(); scanTimer = nil
        gate.requiredCleanChecks = settings.clearMode.requiredChecks(checksPerSecond: burstsPerSecond)
        gate.requiresManualApproval = settings.clearMode.requiresManualApproval
        gate.requiresClearanceDelay = true
        gate.reset(scanner.isTrusted ? "Filling delayed stream buffer" : "Accessibility permission required")
        approvalPromptPresented = false
        configuration.setRunning(true, status: "Requesting Screen Recording access…")
        showPreview()
        updatePreviewState()

        Task { [weak self] in
            guard let self else { return }
            do {
                let size = settings.captureResolution.size
                try await capture.start(
                    delaySeconds: settings.delaySeconds,
                    fps: settings.captureFPS,
                    width: size.width,
                    height: size.height,
                    showsCursor: settings.showsCursor
                )
                await MainActor.run {
                    self.configuration.setRunning(true, status: "Buffering for \(Int(self.settings.delaySeconds)) seconds before checks begin")
                    self.configuration.refreshPermissions()
                    self.scheduleScanning(after: self.settings.delaySeconds)
                }
            } catch {
                await MainActor.run {
                    self.scanTimer?.invalidate()
                    self.configuration.setRunning(false, status: "Screen Recording access is required. Grant it in System Settings, then start again.")
                    self.configuration.refreshPermissions()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private func stopPreview() {
        if recorder.isRecording { stopRecording() }
        scanTimer?.invalidate(); scanTimer = nil
        clearTimer?.invalidate(); clearTimer = nil
        gate.reset("Preview stopped")
        approvalPromptPresented = false
        updatePreviewState()
        configuration.setRunning(false, status: "Preview stopped")
        Task { await capture.stop() }
    }

    private func scheduleScanning(after delay: Double) {
        scanTimer?.invalidate()
        gate.reset("Filling \(Int(delay))-second buffer")
        updatePreviewState()
        scanTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.startScanning()
        }
        RunLoop.main.add(scanTimer!, forMode: .common)
    }

    private func startScanning() {
        scanTimer?.invalidate()
        configuration.setRunning(true, status: "Preview running · 3 scans every 200 ms")
        scanTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / burstsPerSecond, repeats: true) { [weak self] _ in
            self?.performPrivacyBurst()
        }
        RunLoop.main.add(scanTimer!, forMode: .common)
        performPrivacyBurst()
    }

    private func performPrivacyBurst() {
        gate.requiredCleanChecks = settings.clearMode.requiredChecks(checksPerSecond: burstsPerSecond)
        gate.requiresManualApproval = settings.clearMode.requiresManualApproval
        gate.requiresClearanceDelay = true

        for _ in 0..<scansPerBurst {
            switch scanner.scan(options: settings.detectionOptions) {
            case .unavailable:
                gate.update(hasPII: false, unavailableReason: "Accessibility permission required")
                updatePreviewState()
                return
            case .unsupported:
                continue
            case .detections(let detections, let app):
                if !detections.isEmpty {
                    clearTimer?.invalidate(); clearTimer = nil
                    let kinds = Set(detections.map { $0.kind.rawValue }).sorted().joined(separator: ", ")
                    gate.update(hasPII: true, detectionReason: "PII detected in \(app) · \(kinds)")
                    approvalPromptPresented = false
                    updatePreviewState()
                    return
                }
            }
        }
        let wasWaitingForDelay = gate.pendingClearanceDelay
        gate.update(hasPII: false)
        updatePreviewState()
        if gate.pendingClearanceDelay && !wasWaitingForDelay {
            scheduleClearanceDelay()
        }
    }

    private func updatePreviewState() {
        preview.setBlocked(gate.isBlocked, reason: gate.reason, delay: settings.delaySeconds)
        configuration.setManualClearanceRequired(gate.pendingManualApproval)
    }

    private func settingsChanged() {
        gate.requiredCleanChecks = settings.clearMode.requiredChecks(checksPerSecond: burstsPerSecond)
        gate.requiresManualApproval = settings.clearMode.requiresManualApproval
        gate.requiresClearanceDelay = true
        capture.updateDelay(settings.delaySeconds)
        gate.reset("Settings changed · checking again")
        clearTimer?.invalidate(); clearTimer = nil
        approvalPromptPresented = false
        updatePreviewState()
        if settings.clearMode == .safe {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        if capture.isRunning {
            Task { [weak self] in
                guard let self else { return }
                await capture.stop()
                await MainActor.run { self.startPreview() }
            }
        }
    }

    private func scheduleClearanceDelay() {
        clearTimer?.invalidate()
        clearTimer = Timer.scheduledTimer(withTimeInterval: settings.delaySeconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.gate.completeClearanceDelay()
            self.updatePreviewState()
            if self.gate.pendingManualApproval && !self.approvalPromptPresented {
                self.requestSafeConfirmation()
            }
        }
        RunLoop.main.add(clearTimer!, forMode: .common)
    }

    private func requestSafeConfirmation() {
        approvalPromptPresented = true
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
        if alert.runModal() == .alertFirstButtonReturn {
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
        recorder.stop { [weak self] url in
            guard let self else { return }
            if let url {
                self.configuration.setRunning(self.capture.isRunning, status: "Recording saved to \(url.lastPathComponent)")
            } else {
                self.configuration.setRunning(self.capture.isRunning, status: "Recording stopped before any frames were written.")
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    private func showPreview() {
        preview.showWindow(nil)
        preview.window?.orderFrontRegardless()
    }

    @objc private func openConfiguration() {
        configuration.showWindow(nil)
        configuration.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func openPreview() { showPreview() }
}
