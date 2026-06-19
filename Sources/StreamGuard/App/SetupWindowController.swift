import AppKit
import StreamGuardCore

@MainActor
final class SetupWindowController: NSWindowController {
    private let coordinator: AppCoordinator
    private let statusLabel = NSTextField(labelWithString: "")
    private let checklistStack = NSStackView()
    private let startButton = NSButton(title: "Start Protection", target: nil, action: nil)
    private let obsPasswordField = NSSecureTextField(string: "")
    private let protectionModePopup = NSPopUpButton()
    private let sensitivityPopup = NSPopUpButton()
    private let sensitiveTextView = NSTextView()
    private let safeTextView = NSTextView()
    private let launchAtLogin = NSButton(checkboxWithTitle: "Launch at Login", target: nil, action: nil)
    private var checklistLabels: [NSTextField] = []

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 640), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Stream Guard Setup"
        window.center()
        super.init(window: window)
        buildUI()
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let scroll = NSScrollView(frame: content.bounds)
        scroll.autoresizingMask = [.width, .height]
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 880))
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        content.addSubview(scroll)

        let stack = NSStackView(frame: NSRect(x: 24, y: 20, width: 652, height: 840))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        document.addSubview(stack)

        let title = NSTextField(labelWithString: "One-button streamer protection")
        title.font = .boldSystemFont(ofSize: 24)
        stack.addArrangedSubview(title)
        let intro = NSTextField(wrappingLabelWithString: "Start Protection stays disabled until Screen Recording is granted and OBS viewer protection is proven safe. OBS password is stored only in macOS Keychain.")
        intro.textColor = .secondaryLabelColor
        intro.frame.size.width = 640
        stack.addArrangedSubview(intro)

        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(statusLabel)

        checklistStack.orientation = .vertical
        checklistStack.spacing = 6
        stack.addArrangedSubview(checklistStack)
        for _ in 0..<7 {
            let label = NSTextField(labelWithString: "")
            checklistLabels.append(label)
            checklistStack.addArrangedSubview(label)
        }

        let modeRow = row(label: "Protection", control: protectionModePopup)
        protectionModePopup.addItems(withTitles: ["OBS + Local Overlay", "Local Overlay Only", "OBS Only"])
        protectionModePopup.target = self
        protectionModePopup.action = #selector(saveSettings)
        stack.addArrangedSubview(modeRow)

        let sensitivityRow = row(label: "Sensitivity", control: sensitivityPopup)
        sensitivityPopup.addItems(withTitles: ["Safe", "Balanced"])
        sensitivityPopup.target = self
        sensitivityPopup.action = #selector(saveSettings)
        stack.addArrangedSubview(sensitivityRow)

        stack.addArrangedSubview(label("Built-in detectors: email, phone, and secrets are on by default. SSN/cards/national IDs remain off unless configured in advanced JSON."))

        stack.addArrangedSubview(label("Sensitive text list (one per line)"))
        configureTextView(sensitiveTextView)
        stack.addArrangedSubview(scrollView(for: sensitiveTextView, height: 90))

        stack.addArrangedSubview(label("Safe text list (one per line)"))
        configureTextView(safeTextView)
        stack.addArrangedSubview(scrollView(for: safeTextView, height: 90))

        let saveButton = NSButton(title: "Save Detector Settings", target: self, action: #selector(saveSettings))
        stack.addArrangedSubview(saveButton)

        stack.addArrangedSubview(label("OBS websocket password"))
        obsPasswordField.placeholderString = "Leave blank to keep existing Keychain password"
        obsPasswordField.frame.size.width = 360
        stack.addArrangedSubview(obsPasswordField)
        let obsButtons = NSStackView()
        obsButtons.orientation = .horizontal
        obsButtons.spacing = 8
        obsButtons.addArrangedSubview(NSButton(title: "Save Password to Keychain", target: self, action: #selector(savePassword)))
        obsButtons.addArrangedSubview(NSButton(title: "Test Blackout", target: self, action: #selector(testBlackout)))
        stack.addArrangedSubview(obsButtons)

        if let lua = coordinator.obsLuaScriptURL() {
            stack.addArrangedSubview(label("OBS Lua script bundled at: \(lua.path)"))
        }

        launchAtLogin.target = self
        launchAtLogin.action = #selector(toggleLaunchAtLogin)
        stack.addArrangedSubview(launchAtLogin)

        startButton.target = self
        startButton.action = #selector(startProtection)
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        stack.addArrangedSubview(startButton)
    }

    private func refresh() {
        let config = coordinator.currentConfig
        let readiness = coordinator.currentSetupReadiness
        statusLabel.stringValue = readiness.canStartProtection ? "Ready to start protection" : "Setup incomplete"
        set(check: 0, ok: readiness.screenRecordingGranted, text: "Screen Recording permission")
        set(check: 1, ok: readiness.obs.state != .disconnected && readiness.obs.state != .passwordRequired, text: "OBS websocket connection")
        set(check: 2, ok: readiness.obs.state != .passwordRequired, text: "OBS password/auth status")
        set(check: 3, ok: ![.protectedSceneMissing, .disconnected, .passwordRequired].contains(readiness.obs.state), text: "Protected delayed scene exists")
        set(check: 4, ok: ![.blackoutSourceMissing, .protectedSceneMissing, .disconnected, .passwordRequired].contains(readiness.obs.state), text: "Blackout source exists")
        set(check: 5, ok: readiness.obs.isReady, text: "Test blackout succeeds")
        set(check: 6, ok: readiness.detectorSettingsComplete, text: "Detector settings complete")
        startButton.isEnabled = readiness.canStartProtection
        launchAtLogin.state = coordinator.launchAtLoginEnabled() ? .on : .off
        protectionModePopup.selectItem(at: config.userSettings.protectionMode == .both ? 0 : (config.userSettings.protectionMode == .localOverlay ? 1 : 2))
        sensitivityPopup.selectItem(at: config.userSettings.sensitivity == .safe ? 0 : 1)
        sensitiveTextView.string = config.userSettings.sensitiveText.joined(separator: "\n")
        safeTextView.string = config.userSettings.safeText.joined(separator: "\n")
    }

    private func set(check index: Int, ok: Bool, text: String) {
        checklistLabels[index].stringValue = "\(ok ? "✓" : "○") \(text)"
        checklistLabels[index].textColor = ok ? .systemGreen : .secondaryLabelColor
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.frame.size.width = 640
        return field
    }

    private func row(label text: String, control: NSView) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 12
        let label = NSTextField(labelWithString: text)
        label.frame.size.width = 120
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(control)
        return stack
    }

    private func configureTextView(_ view: NSTextView) {
        view.font = .systemFont(ofSize: 13)
        view.isRichText = false
    }

    private func scrollView(for textView: NSTextView, height: CGFloat) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: height))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView
        return scroll
    }

    @objc private func saveSettings() {
        var settings = coordinator.currentConfig.userSettings
        settings.protectionMode = [.both, .localOverlay, .obs][max(0, protectionModePopup.indexOfSelectedItem)]
        settings.sensitivity = sensitivityPopup.indexOfSelectedItem == 0 ? .safe : .balanced
        settings.sensitiveText = lines(sensitiveTextView.string)
        settings.safeText = lines(safeTextView.string)
        coordinator.updateUserSettings(settings)
        refresh()
    }

    @objc private func savePassword() {
        guard !obsPasswordField.stringValue.isEmpty else { return }
        do {
            try coordinator.saveOBSPassword(obsPasswordField.stringValue)
            obsPasswordField.stringValue = ""
            refresh()
        } catch {
            statusLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func testBlackout() {
        statusLabel.stringValue = "Testing OBS blackout…"
        coordinator.testOBSReadiness { [weak self] _ in self?.refresh() }
    }

    @objc private func toggleLaunchAtLogin() {
        do { try coordinator.setLaunchAtLogin(launchAtLogin.state == .on) } catch { statusLabel.stringValue = error.localizedDescription }
        refresh()
    }

    @objc private func startProtection() {
        saveSettings()
        coordinator.startMonitoring()
        refresh()
    }

    private func lines(_ value: String) -> [String] {
        value.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
