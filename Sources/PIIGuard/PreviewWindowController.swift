import AppKit

final class PreviewWindowController: NSWindowController {
    private let imageView = NSImageView()
    private let blocker = NSView()
    private let blockerLabel = NSTextField(labelWithString: "Waiting for a privacy check")
    private let stateLabel = NSTextField(labelWithString: "Delayed preview")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PII Guard Preview"
        window.minSize = NSSize(width: 560, height: 360)
        window.collectionBehavior = [.fullScreenPrimary]
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { nil }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.black.cgColor

        blocker.wantsLayer = true
        blocker.layer?.backgroundColor = NSColor.black.cgColor
        blockerLabel.textColor = .white
        blockerLabel.font = .systemFont(ofSize: 25, weight: .semibold)
        blockerLabel.alignment = .center

        stateLabel.textColor = .white
        stateLabel.font = .systemFont(ofSize: 12, weight: .medium)
        stateLabel.wantsLayer = true
        stateLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        stateLabel.layer?.cornerRadius = 6

        for view in [imageView, blocker, blockerLabel, stateLabel] { view.translatesAutoresizingMaskIntoConstraints = false }
        content.addSubview(imageView)
        content.addSubview(blocker)
        blocker.addSubview(blockerLabel)
        content.addSubview(stateLabel)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: content.leadingAnchor), imageView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: content.topAnchor), imageView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            blocker.leadingAnchor.constraint(equalTo: content.leadingAnchor), blocker.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            blocker.topAnchor.constraint(equalTo: content.topAnchor), blocker.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            blockerLabel.centerXAnchor.constraint(equalTo: blocker.centerXAnchor), blockerLabel.centerYAnchor.constraint(equalTo: blocker.centerYAnchor),
            stateLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), stateLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
        window?.center()
    }

    func showFrame(_ image: CGImage) {
        imageView.image = NSImage(cgImage: image, size: .zero)
    }

    func setBlocked(_ blocked: Bool, reason: String, delay: Double) {
        blocker.isHidden = !blocked
        blockerLabel.stringValue = blocked ? reason : ""
        stateLabel.stringValue = String(format: "  %.1f s delayed · %@  ", delay, blocked ? "blocked" : "protected")
    }
}
