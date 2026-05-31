import AppKit
import StreamGuardCore

final class BlackoutOverlay: @unchecked Sendable {
    private var window: NSWindow?
    private var overlayView: MaskOverlayView?
    private var isVisible = false

    var windowID: CGWindowID? {
        guard let window else { return nil }
        return CGWindowID(window.windowNumber)
    }

    /// Create the overlay window hidden so the first arm does not pay window construction cost.
    func prepareWindow() {
        runOnMain {
            self.ensureWindow()
        }
    }

    func show() {
        runOnMain {
            self.ensureWindow()
            guard let screen = NSScreen.main else { return }
            self.positionWindow(frame: screen.frame, mode: .full)
            self.showWindow()
        }
    }

    func showMasks(_ normalizedRects: [CGRect]) {
        runOnMain {
            self.ensureWindow()
            guard let screen = NSScreen.main else {
                self.window?.orderOut(nil)
                self.isVisible = false
                return
            }

            let layout = MaskLayout(normalizedRects: normalizedRects, screenFrame: screen.frame)
            guard !layout.rects.isEmpty else {
                self.window?.orderOut(nil)
                self.isVisible = false
                return
            }

            self.positionWindow(frame: layout.windowFrame, mode: .masks(layout.rects))
            self.showWindow()
        }
    }

    func hide() {
        runOnMain {
            self.window?.orderOut(nil)
            self.isVisible = false
        }
    }

    var visible: Bool { isVisible }

    private func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func ensureWindow() {
        guard window == nil else { return }
        createWindow()
    }

    private func createWindow() {
        guard let screen = NSScreen.main else { return }
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: 1, height: 1)
        let window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isOpaque = false
        window.alphaValue = 1
        window.backgroundColor = NSColor.clear
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        let view = MaskOverlayView(frame: NSRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        overlayView = view
        self.window = window
    }

    private func positionWindow(frame: NSRect, mode: MaskOverlayView.Mode) {
        window?.setFrame(frame, display: true)
        overlayView?.frame = NSRect(origin: .zero, size: frame.size)
        overlayView?.mode = mode
    }

    private func showWindow() {
        window?.orderFrontRegardless()
        isVisible = true
    }
}

private final class MaskOverlayView: NSView {
    enum Mode {
        case full
        case masks([CGRect])
    }

    var mode: Mode = .full {
        didSet {
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        switch mode {
        case .full:
            NSColor.black.withAlphaComponent(0.5).setFill()
            bounds.fill()
        case .masks(let rects):
            NSColor.black.withAlphaComponent(0.64).setFill()
            for rect in rects {
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            }
        }
    }
}

private struct MaskLayout {
    let windowFrame: NSRect
    let rects: [CGRect]

    init(normalizedRects: [CGRect], screenFrame: NSRect) {
        let screenRects = normalizedRects.compactMap { rect in
            Self.screenRect(from: rect, in: screenFrame)
        }

        guard let union = screenRects.reduce(nil, { partial, rect -> CGRect? in
            partial?.union(rect) ?? rect
        })?.integral else {
            self.windowFrame = .zero
            self.rects = []
            return
        }

        self.windowFrame = union
        self.rects = screenRects.map { rect in
            CGRect(
                x: rect.minX - union.minX,
                y: union.maxY - rect.maxY,
                width: rect.width,
                height: rect.height
            ).integral
        }
    }

    private static func screenRect(from normalizedRect: CGRect, in screenFrame: NSRect) -> CGRect? {
        guard normalizedRect.minX.isFinite,
              normalizedRect.minY.isFinite,
              normalizedRect.width.isFinite,
              normalizedRect.height.isFinite else { return nil }

        let minX = clamp(normalizedRect.minX, lower: 0, upper: 1)
        let minY = clamp(normalizedRect.minY, lower: 0, upper: 1)
        let maxX = clamp(normalizedRect.maxX, lower: 0, upper: 1)
        let maxY = clamp(normalizedRect.maxY, lower: 0, upper: 1)
        guard maxX > minX, maxY > minY else { return nil }

        let width = (maxX - minX) * screenFrame.width
        let height = (maxY - minY) * screenFrame.height
        guard width >= 1, height >= 1 else { return nil }

        return CGRect(
            x: screenFrame.minX + minX * screenFrame.width,
            y: screenFrame.minY + screenFrame.height - maxY * screenFrame.height,
            width: width,
            height: height
        )
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }
}
