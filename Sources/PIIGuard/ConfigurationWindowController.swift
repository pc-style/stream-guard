import AppKit
import CoreGraphics
import PIIGuardCore

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

final class ConfigurationWindowController: NSWindowController, NSWindowDelegate {
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onSettingsChanged: (() -> Void)?
    var onOpenPreview: (() -> Void)?
    var onOpenPermissions: (() -> Void)?
    var onManualClear: (() -> Void)?
    var onToggleRecording: (() -> Void)?

    private let settings: Settings
    private let protectionLabel = NSTextField(labelWithString: "Protection: stopped")
    private let statusLabel = NSTextField(labelWithString: "Grant permissions, then start the protected preview.")
    private let startButton = NSButton(title: "Start protected preview", target: nil, action: nil)
    private let permissionLabel = NSTextField(labelWithString: "")
    private let advancedButton = NSButton(title: "Show advanced settings", target: nil, action: nil)
    private let advancedStack = NSStackView()
    private let delayPopup = NSPopUpButton()
    private let modePopup = NSPopUpButton()
    private let resolutionPopup = NSPopUpButton()
    private let fpsPopup = NSPopUpButton()
    private let cursorCheckbox = NSButton(checkboxWithTitle: "Include cursor", target: nil, action: nil)
    private let phraseField = NSTextField()
    private let phrasePopup = NSPopUpButton()
    private let savePhraseButton = NSButton(title: "Add", target: nil, action: nil)
    private let removePhraseButton = NSButton(title: "Remove", target: nil, action: nil)
    private let safeButton = NSButton(title: "It's safe now", target: nil, action: nil)
    private let recordButton = NSButton(title: "Record", target: nil, action: nil)

    init(settings: Settings) {
        self.settings = settings
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PII Guard"
        super.init(window: window)
        window.delegate = self
        buildUI()
        refreshPermissions()
    }

    required init?(coder: NSCoder) { nil }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: "Protected screen-sharing preview")
        title.font = .systemFont(ofSize: 28, weight: .bold)
        let subtitle = wrappingLabel("Share only the PII Guard Preview window. The preview stays black until capture is delayed and visible text passes the privacy checks.")

        let permissionButton = NSButton(title: "Open Privacy Settings", target: self, action: #selector(openPermissions))
        let permissionRow = NSStackView(views: [permissionLabel, permissionButton])
        permissionRow.orientation = .horizontal
        permissionRow.spacing = 10

        startButton.target = self
        startButton.action = #selector(toggleCapture)
        startButton.keyEquivalent = "\r"
        startButton.bezelStyle = .rounded
        let previewButton = NSButton(title: "Open preview", target: self, action: #selector(openPreview))
        let primaryActions = NSStackView(views: [startButton, previewButton])
        primaryActions.orientation = .horizontal
        primaryActions.spacing = 10

        protectionLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 13, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor

        delayPopup.addItems(withTitles: ["1 second", "2 seconds", "3 seconds", "5 seconds", "10 seconds"])
        delayPopup.selectItem(at: [1.0, 2.0, 3.0, 5.0, 10.0].firstIndex(of: settings.delaySeconds) ?? 1)
        delayPopup.target = self; delayPopup.action = #selector(delayChanged)

        CaptureResolution.allCases.forEach { resolutionPopup.addItem(withTitle: $0.title) }
        resolutionPopup.selectItem(at: CaptureResolution.allCases.firstIndex(of: settings.captureResolution) ?? 0)
        resolutionPopup.target = self; resolutionPopup.action = #selector(resolutionChanged)

        [5, 10, 15, 30].forEach { fpsPopup.addItem(withTitle: "\($0) fps") }
        fpsPopup.selectItem(at: [5, 10, 15, 30].firstIndex(of: settings.captureFPS) ?? 1)
        fpsPopup.target = self; fpsPopup.action = #selector(fpsChanged)

        cursorCheckbox.state = settings.showsCursor ? .on : .off
        cursorCheckbox.target = self; cursorCheckbox.action = #selector(cursorChanged)

        ClearMode.allCases.forEach { modePopup.addItem(withTitle: $0.title) }
        modePopup.selectItem(at: ClearMode.allCases.firstIndex(of: settings.clearMode) ?? 1)
        modePopup.target = self; modePopup.action = #selector(modeChanged)

        let detectionGrid = NSGridView(views: SensitiveKind.allCases.map { kind in
            let checkbox = NSButton(checkboxWithTitle: kind.rawValue, target: self, action: #selector(kindChanged(_:)))
            checkbox.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
            checkbox.state = settings.isKindEnabled(kind) ? .on : .off
            return [checkbox]
        })
        detectionGrid.rowSpacing = 6

        phraseField.placeholderString = "Add or edit a sensitive phrase"
        phrasePopup.target = self; phrasePopup.action = #selector(selectPhrase)
        savePhraseButton.target = self; savePhraseButton.action = #selector(savePhrase)
        removePhraseButton.target = self; removePhraseButton.action = #selector(removePhrase)
        let phrasePickerRow = NSStackView(views: [phrasePopup, removePhraseButton])
        phrasePickerRow.orientation = .horizontal; phrasePickerRow.spacing = 8
        let phraseEditRow = NSStackView(views: [phraseField, savePhraseButton])
        phraseEditRow.orientation = .horizontal; phraseEditRow.spacing = 8
        phraseField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        updatePhraseControls()

        safeButton.target = self; safeButton.action = #selector(manualClear)
        safeButton.isHidden = true
        recordButton.target = self; recordButton.action = #selector(toggleRecording)
        let secondaryActions = NSStackView(views: [recordButton, safeButton])
        secondaryActions.orientation = .horizontal; secondaryActions.spacing = 10

        advancedStack.orientation = .vertical
        advancedStack.alignment = .leading
        advancedStack.spacing = 10
        [
            labeledRow("Delay", delayPopup), labeledRow("Resolution", resolutionPopup),
            labeledRow("Frame rate", fpsPopup), cursorCheckbox, labeledRow("Clear policy", modePopup),
            sectionTitle("Detection"), detectionGrid, phrasePickerRow, phraseEditRow, secondaryActions
        ].forEach(advancedStack.addArrangedSubview)
        advancedStack.isHidden = true

        advancedButton.bezelStyle = .inline
        advancedButton.target = self
        advancedButton.action = #selector(toggleAdvanced)

        permissionLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [
            title, subtitle, separator(), sectionTitle("1. Grant permissions"), permissionRow,
            sectionTitle("2. Start and share the preview"), primaryActions,
            protectionLabel, statusLabel, separator(), advancedButton, advancedStack
        ])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let documentView = FlippedDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)
        scrollView.documentView = documentView
        content.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -24)
        ])
        subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        permissionRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        phraseEditRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        window?.center()
    }

    func setRunning(_ running: Bool, status: String) {
        startButton.title = running ? "Stop protected preview" : "Start protected preview"
        statusLabel.stringValue = status
    }

    func setProtectionState(blocked: Bool, reason: String) {
        protectionLabel.stringValue = blocked ? "Protection: preview blocked — \(reason)" : "Protection: preview safe to share"
        protectionLabel.textColor = blocked ? .systemOrange : .systemGreen
    }

    func refreshPermissions() {
        let screen = CGPreflightScreenCaptureAccess() ? "Screen Recording allowed" : "Screen Recording needed"
        let accessibility = AXIsProcessTrusted() ? "Accessibility allowed" : "Accessibility needed"
        permissionLabel.stringValue = "\(screen)  ·  \(accessibility)"
    }

    func setManualClearanceRequired(_ required: Bool) {
        safeButton.isHidden = !required
        safeButton.isEnabled = required
    }

    func setRecording(_ recording: Bool) {
        recordButton.title = recording ? "Stop recording" : "Record"
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    @objc private func toggleCapture() { startButton.title.hasPrefix("Stop") ? onStop?() : onStart?() }
    @objc private func openPreview() { onOpenPreview?() }
    @objc private func openPermissions() { onOpenPermissions?() }
    @objc private func manualClear() { onManualClear?() }
    @objc private func toggleRecording() { onToggleRecording?() }
    @objc private func toggleAdvanced() {
        advancedStack.isHidden.toggle()
        advancedButton.title = advancedStack.isHidden ? "Show advanced settings" : "Hide advanced settings"
    }
    @objc private func delayChanged() {
        settings.delaySeconds = [1.0, 2.0, 3.0, 5.0, 10.0][delayPopup.indexOfSelectedItem]
        onSettingsChanged?()
    }
    @objc private func modeChanged() {
        settings.clearMode = ClearMode.allCases[modePopup.indexOfSelectedItem]
        onSettingsChanged?()
    }
    @objc private func resolutionChanged() {
        settings.captureResolution = CaptureResolution.allCases[resolutionPopup.indexOfSelectedItem]
        onSettingsChanged?()
    }
    @objc private func fpsChanged() {
        settings.captureFPS = [5, 10, 15, 30][fpsPopup.indexOfSelectedItem]
        onSettingsChanged?()
    }
    @objc private func cursorChanged() {
        settings.showsCursor = cursorCheckbox.state == .on
        onSettingsChanged?()
    }
    @objc private func kindChanged(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let kind = SensitiveKind(rawValue: raw) else { return }
        settings.setKind(kind, enabled: sender.state == .on); onSettingsChanged?()
    }
    @objc private func selectPhrase() {
        guard phrasePopup.indexOfSelectedItem >= 0, phrasePopup.indexOfSelectedItem < settings.customPhrases.count else { return }
        phraseField.stringValue = settings.customPhrases[phrasePopup.indexOfSelectedItem]
        savePhraseButton.title = "Save"
    }
    @objc private func savePhrase() {
        let phrase = phraseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return }
        var phrases = settings.customPhrases
        if savePhraseButton.title == "Save", phrasePopup.indexOfSelectedItem >= 0, phrasePopup.indexOfSelectedItem < phrases.count {
            phrases[phrasePopup.indexOfSelectedItem] = phrase
        } else if !phrases.contains(phrase) {
            phrases.append(phrase)
        }
        settings.customPhrases = phrases
        phraseField.stringValue = ""
        updatePhraseControls()
        onSettingsChanged?()
    }
    @objc private func removePhrase() {
        let index = phrasePopup.indexOfSelectedItem
        guard index >= 0, index < settings.customPhrases.count else { return }
        var phrases = settings.customPhrases
        phrases.remove(at: index)
        settings.customPhrases = phrases
        phraseField.stringValue = ""
        updatePhraseControls()
        onSettingsChanged?()
    }

    private func updatePhraseControls() {
        phrasePopup.removeAllItems()
        phrasePopup.addItems(withTitles: settings.customPhrases)
        phrasePopup.isEnabled = !settings.customPhrases.isEmpty
        removePhraseButton.isEnabled = !settings.customPhrases.isEmpty
        savePhraseButton.title = "Add"
    }
    private func wrappingLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text); label.textColor = .secondaryLabelColor; return label
    }
    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: 15, weight: .semibold); return label
    }
    private func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
    private func labeledRow(_ label: String, _ control: NSView) -> NSStackView {
        let title = NSTextField(labelWithString: label); title.widthAnchor.constraint(equalToConstant: 100).isActive = true
        let row = NSStackView(views: [title, control]); row.orientation = .horizontal; row.spacing = 12; return row
    }
}
