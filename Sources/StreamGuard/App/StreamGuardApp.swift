import AppKit

@main
struct StreamGuardApp {
    private static var appDelegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let coordinator = AppCoordinator.shared
        let menuBar = MenuBarController()
        let delegate = AppDelegate(coordinator: coordinator, menuBar: menuBar)
        appDelegate = delegate
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator: AppCoordinator
    private let menuBar: MenuBarController

    init(coordinator: AppCoordinator, menuBar: MenuBarController) {
        self.coordinator = coordinator
        self.menuBar = menuBar
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.applicationDidFinishLaunching()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stopMonitoring()
    }
}
