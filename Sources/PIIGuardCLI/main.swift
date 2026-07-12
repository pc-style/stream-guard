import AppKit
import PIIGuardCore

let appPath = "/Applications/PII Guard.app"
let arguments = Array(CommandLine.arguments.dropFirst())
let launchTimeout: TimeInterval = 10
let maximumCheckBytes = 1_048_576

func appIsRunning() -> Bool {
    NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "dev.pcstyle.piiguard" }
}

func usage() -> Never {
    print("""
    usage: pii-guard <command>

      status              Show whether PII Guard is running
      start               Launch the installed menu-bar app (10 second timeout)
      stop                Stop the menu-bar app
      permission          Open Accessibility privacy settings
      check <text>        Detect PII supplied as an argument
      check --stdin       Detect PII read from standard input (recommended for sensitive text)
    """)
    exit(2)
}

func readStandardInput() -> String {
    var data = Data()
    do {
        while let chunk = try FileHandle.standardInput.read(upToCount: min(64 * 1_024, maximumCheckBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumCheckBytes else {
                fputs("Input exceeds the 1 MiB limit\n", stderr)
                exit(1)
            }
        }
    } catch {
        fputs("Could not read standard input: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
    guard let text = String(data: data, encoding: .utf8) else {
        fputs("Standard input must be valid UTF-8\n", stderr)
        exit(1)
    }
    return text
}

guard let command = arguments.first else { usage() }

switch command {
case "status":
    print(appIsRunning() ? "PII Guard is running" : "PII Guard is not running")
case "start":
    guard FileManager.default.fileExists(atPath: appPath) else {
        fputs("PII Guard is not installed at \(appPath)\n", stderr); exit(1)
    }
    var launchCompleted = false
    var launchError: Error?
    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath), configuration: .init()) { _, error in
        launchError = error
        launchCompleted = true
    }
    let deadline = Date().addingTimeInterval(launchTimeout)
    while !launchCompleted && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    guard launchCompleted else {
        fputs("Timed out after \(Int(launchTimeout)) seconds while starting PII Guard\n", stderr)
        exit(1)
    }
    if let launchError {
        fputs("Could not start PII Guard: \(launchError.localizedDescription)\n", stderr)
        exit(1)
    }
case "stop":
    let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "dev.pcstyle.piiguard" }
    apps.forEach { $0.terminate() }
    print(apps.isEmpty ? "PII Guard was not running" : "PII Guard stopped")
case "permission":
    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    NSWorkspace.shared.open(url)
case "check":
    guard arguments.count > 1 else { usage() }
    let text = arguments[1] == "--stdin" ? readStandardInput() : arguments.dropFirst().joined(separator: " ")
    let detections = DetectionEngine().detect(in: text, options: DetectionOptions())
    if detections.isEmpty {
        print("No supported PII detected")
    } else {
        for detection in detections { print("\(detection.kind.rawValue) at characters \(detection.range.location)-\(NSMaxRange(detection.range))") }
    }
default:
    usage()
}
