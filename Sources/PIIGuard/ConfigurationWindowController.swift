import AppKit
import CoreGraphics
import PIIGuardCore

final class ConfigurationWindowController: NSWindowController, NSWindowDelegate {
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onSettingsChanged: (() -> Void)?
    var onOpenPreview: (() -> Void)?
    var onManualClear: (() -> Void)?
    var onToggleRecording: (() -> Void)?

    private let settings: Settings
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let startButton = NSButton(title: "Start delayed preview", target: nil, action: nil)
    private let permissionLabel = NSTextField(labelWithString: "")
    private let delayPopup = NSPopUpButton()
    private let modePopup = NSPopUpButton()
    private let resolutionPopup = NSPopUpButton()
    private let fpsPopup = NSPopUpButton()
    private let cursorCheckbox = NSButton(checkboxWithTitle: "Include cursor", target: nil, action: nil)
    private let phraseField = NSTextField()
    private let phrasesLabel = NSTextField(labelWithString: "")
    private let safeButton = NSButton(title: "It's safe now", target: nil, action: nil)
    private let recordButton = NSButton(title: "Record", target: nil, action: nil)

    init(settings: Settings) {
        self.settings = settings
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 700),
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
        let title = NSTextField(labelWithString: "Delayed screen preview")
        title.font = .systemFont(ofSize: 28, weight: .bold)
        let subtitle = wrappingLabel("Share the preview window instead of your display. PII Guard delays the screen, checks visible Accessibility text, and blacks the preview when sensitive data appears.")

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

        phraseField.placeholderString = "Add a custom sensitive phrase"
        let addPhrase = NSButton(title: "Add", target: self, action: #selector(addPhrase))
        let phraseRow = NSStackView(views: [phraseField, addPhrase])
        phraseRow.orientation = .horizontal; phraseRow.spacing = 8
        phraseField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        updatePhrasesLabel()

        startButton.target = self; startButton.action = #selector(toggleCapture)
        startButton.keyEquivalent = "\r"
        startButton.bezelStyle = .rounded
        let previewButton = NSButton(title: "Open preview", target: self, action: #selector(openPreview))
        safeButton.target = self; safeButton.action = #selector(manualClear)
        safeButton.isHidden = true
        recordButton.target = self; recordButton.action = #selector(toggleRecording)
        let actions = NSStackView(views: [startButton, previewButton, recordButton, safeButton])
        actions.orientation = .horizontal; actions.spacing = 10

        permissionLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)

        let stack = NSStackView(views: [
            title, subtitle, separator(), sectionTitle("Stream"), labeledRow("Delay", delayPopup),
            labeledRow("Resolution", resolutionPopup), labeledRow("Frame rate", fpsPopup), cursorCheckbox,
            labeledRow("Clear policy", modePopup), permissionLabel, separator(), sectionTitle("Detection"),
            detectionGrid, phraseRow, phrasesLabel, separator(), actions, statusLabel
        ])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 26)
        ])
        subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        phraseRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        window?.center()
    }

    func setRunning(_ running: Bool, status: String) {
        startButton.title = running ? "Stop preview" : "Start delayed preview"
        statusLabel.stringValue = status
    }

    func refreshPermissions() {
        let screen = CGPreflightScreenCaptureAccess() ? "Screen Recording: allowed" : "Screen Recording: requested when Start is clicked"
        let accessibility = AXIsProcessTrusted() ? "Accessibility: allowed" : "Accessibility: required"
        permissionLabel.stringValue = "\(screen)  ·  \(accessibility)"
    }

    func setManualClearanceRequired(_ required: Bool) {
        safeButton.isHidden = !required
        safeButton.isEnabled = required
    }

    func setRecording(_ recording: Bool) {
        recordButton.title = recording ? "Stop recording" : "Record"
    }

    func windowWillClose(_ notification: Notification) { NSApp.hide(nil) }

    @objc private func toggleCapture() { startButton.title.hasPrefix("Stop") ? onStop?() : onStart?() }
    @objc private func openPreview() { onOpenPreview?() }
    @objc private func manualClear() { onManualClear?() }
    @objc private func toggleRecording() { onToggleRecording?() }
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
    @objc private func addPhrase() {
        let phrase = phraseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return }
        settings.customPhrases.append(phrase); phraseField.stringValue = ""; updatePhrasesLabel(); onSettingsChanged?()
    }

    private func updatePhrasesLabel() {
        phrasesLabel.stringValue = settings.customPhrases.isEmpty ? "No custom phrases" : "Custom: \(settings.customPhrases.joined(separator: ", "))"
        phrasesLabel.textColor = .secondaryLabelColor
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
