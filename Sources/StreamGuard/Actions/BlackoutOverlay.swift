import AppKit
import StreamGuardCore

final class BlackoutOverlay: @unchecked Sendable {
    private var window: NSWindow?
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
            self.window?.orderFrontRegardless()
            self.isVisible = true
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
        let frame = screen.frame
        let window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isOpaque = false
        window.alphaValue = 0.5
        window.backgroundColor = NSColor.black.withAlphaComponent(0.5)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        window.contentView = view
        self.window = window
    }
}
