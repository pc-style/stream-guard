import AppKit
import PIIGuardCore

let appPath = "/Applications/PII Guard.app"
let arguments = Array(CommandLine.arguments.dropFirst())

func appIsRunning() -> Bool {
    NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "dev.pcstyle.piiguard" }
}

func usage() -> Never {
    print("""
    usage: pii-guard <command>

      status          Show whether PII Guard is running
      start           Launch the installed menu-bar app
      stop            Stop the menu-bar app
      permission      Open Accessibility privacy settings
      check <text>    Detect PII locally without storing or sending the text
    """)
    exit(2)
}

guard let command = arguments.first else { usage() }

switch command {
case "status":
    print(appIsRunning() ? "PII Guard is running" : "PII Guard is not running")
case "start":
    guard FileManager.default.fileExists(atPath: appPath) else {
        fputs("PII Guard is not installed at \(appPath)\n", stderr); exit(1)
    }
    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath), configuration: .init()) { _, error in
        if let error { fputs("Could not start PII Guard: \(error.localizedDescription)\n", stderr); exit(1) }
        exit(0)
    }
    RunLoop.current.run()
case "stop":
    let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "dev.pcstyle.piiguard" }
    apps.forEach { $0.terminate() }
    print(apps.isEmpty ? "PII Guard was not running" : "PII Guard stopped")
case "permission":
    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    NSWorkspace.shared.open(url)
case "check":
    guard arguments.count > 1 else { usage() }
    let text = arguments.dropFirst().joined(separator: " ")
    let detections = DetectionEngine().detect(in: text, options: DetectionOptions())
    if detections.isEmpty {
        print("No supported PII detected")
    } else {
        for detection in detections { print("\(detection.kind.rawValue) at characters \(detection.range.location)-\(NSMaxRange(detection.range))") }
    }
default:
    usage()
}
