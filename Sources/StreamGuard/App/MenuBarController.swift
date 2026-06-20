import AppKit

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let statusMenuItem = NSMenuItem(title: "Protection: Idle", action: nil, keyEquivalent: "")
    private let startItem = NSMenuItem(title: "Start Protection", action: #selector(toggleProtection), keyEquivalent: "s")
    private let setupItem = NSMenuItem(title: "Open Setup / Settings", action: #selector(openSetup), keyEquivalent: ",")
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let diagnosticsItem = NSMenuItem(title: "Advanced Diagnostics", action: #selector(openDiagnostics), keyEquivalent: "d")
    private let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
    private lazy var setupWindow = SetupWindowController(coordinator: AppCoordinator.shared)

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureMenuBar()
        AppCoordinator.shared.onStatusChange = { [weak self] message in
            Task { @MainActor in self?.updateStatus(message) }
        }
    }

    private func configureMenuBar() {
        statusItem.button?.title = "🛡"
        statusItem.button?.toolTip = "Stream Guard"
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        for item in [startItem, setupItem, launchAtLoginItem, diagnosticsItem] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
        updateMonitoringLabel()
    }

    private func updateStatus(_ message: String) {
        statusMenuItem.title = "Protection: \(message)"
        updateMonitoringLabel()
    }

    private func updateMonitoringLabel() {
        let monitoring = AppCoordinator.shared.monitoring
        startItem.title = monitoring ? "Stop Protection" : "Start Protection"
        launchAtLoginItem.state = AppCoordinator.shared.launchAtLoginEnabled() ? .on : .off
        statusItem.button?.title = monitoring ? "🛡●" : "🛡"
    }

    @objc private func toggleProtection() {
        if AppCoordinator.shared.monitoring { AppCoordinator.shared.stopMonitoring() }
        else { AppCoordinator.shared.startMonitoring() }
        updateMonitoringLabel()
    }

    @objc private func openSetup() { setupWindow.show() }
    @objc private func openDiagnostics() { AppCoordinator.shared.openStatusPage() }

    @objc private func toggleLaunchAtLogin() {
        do { try AppCoordinator.shared.setLaunchAtLogin(!AppCoordinator.shared.launchAtLoginEnabled()) }
        catch { statusMenuItem.title = "Protection: \(error.localizedDescription)" }
        updateMonitoringLabel()
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
