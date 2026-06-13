import AppKit
import StreamGuardCore

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let statusMenuItem = NSMenuItem(title: "Status: Idle", action: nil, keyEquivalent: "")
    private let startItem = NSMenuItem(title: "Start Monitoring", action: #selector(toggleMonitoring), keyEquivalent: "s")
    private let disableItem = NSMenuItem(title: "Disable / Enable (⌘⇧D)", action: #selector(toggleMonitoring), keyEquivalent: "D")
    private let guardModeItem = NSMenuItem(title: "OCR Guard Mode", action: nil, keyEquivalent: "")
    private let blurAllModeItem = NSMenuItem(title: "Blur All (Buggy)", action: #selector(selectBlurAllMode), keyEquivalent: "")
    private let whitelistModeItem = NSMenuItem(title: "Whitelist", action: #selector(selectWhitelistMode), keyEquivalent: "")
    private let blacklistModeItem = NSMenuItem(title: "Blacklist", action: #selector(selectBlacklistMode), keyEquivalent: "")
    private let openStatusItem = NSMenuItem(title: "Open Status Page", action: #selector(openStatus), keyEquivalent: "o")
    private let openConfigItem = NSMenuItem(title: "Open Config Folder", action: #selector(openConfig), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
    private var hotKeyMonitor: Any?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureMenuBar()
        AppCoordinator.shared.onStatusChange = { [weak self] message in
            Task { @MainActor in
                self?.updateStatus(message)
            }
        }
    }

    private func configureMenuBar() {
        if let button = statusItem.button {
            button.title = "🛡"
            button.toolTip = "Stream Guard"
        }

        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        startItem.target = self
        menu.addItem(startItem)

        disableItem.target = self
        disableItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(disableItem)

        configureGuardModeMenu()
        menu.addItem(guardModeItem)

        openStatusItem.target = self
        menu.addItem(openStatusItem)

        openConfigItem.target = self
        menu.addItem(openConfigItem)

        menu.addItem(.separator())
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        installHotKeyMonitor()
        updateMonitoringLabel()
    }

    private func configureGuardModeMenu() {
        let submenu = NSMenu()
        for item in [blacklistModeItem, whitelistModeItem, blurAllModeItem] {
            item.target = self
            submenu.addItem(item)
        }
        guardModeItem.submenu = submenu
        updateGuardModeLabel()
    }

    private func updateStatus(_ message: String) {
        statusMenuItem.title = "Status: \(message)"
        updateMonitoringLabel()
        updateGuardModeLabel()
    }

    private func updateMonitoringLabel() {
        let monitoring = AppCoordinator.shared.monitoring
        startItem.title = monitoring ? "Stop Monitoring" : "Start Monitoring"
        disableItem.title = monitoring ? "Disable Monitoring (⌘⇧D)" : "Enable Monitoring (⌘⇧D)"
        if let button = statusItem.button {
            button.title = monitoring ? "🛡●" : "🛡"
        }
    }

    private func updateGuardModeLabel() {
        let mode = AppCoordinator.shared.currentStatusPayload().ocrGuardMode
        guardModeItem.title = "OCR Guard Mode: \(mode)"
        blurAllModeItem.state = mode == OCRGuardMode.blurAll.rawValue ? .on : .off
        whitelistModeItem.state = mode == OCRGuardMode.whitelist.rawValue ? .on : .off
        blacklistModeItem.state = mode == OCRGuardMode.blacklist.rawValue ? .on : .off
    }

    private func installHotKeyMonitor() {
        hotKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift],
                  event.charactersIgnoringModifiers?.lowercased() == "d" else { return }
            Task { @MainActor in
                self.toggleMonitoring()
            }
        }
    }

    @objc private func toggleMonitoring() {
        if AppCoordinator.shared.monitoring {
            AppCoordinator.shared.stopMonitoring()
        } else {
            AppCoordinator.shared.startMonitoring()
        }
        updateMonitoringLabel()
    }

    @objc private func openStatus() {
        AppCoordinator.shared.openStatusPage()
    }

    @objc private func openConfig() {
        AppCoordinator.shared.openConfigFolder()
    }

    @objc private func selectBlurAllMode() {
        AppCoordinator.shared.setGuardModeFromMenu(.blurAll)
        updateGuardModeLabel()
    }

    @objc private func selectWhitelistMode() {
        AppCoordinator.shared.setGuardModeFromMenu(.whitelist)
        updateGuardModeLabel()
    }

    @objc private func selectBlacklistMode() {
        AppCoordinator.shared.setGuardModeFromMenu(.blacklist)
        updateGuardModeLabel()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
