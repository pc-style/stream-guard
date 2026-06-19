import Foundation

struct LaunchAgentManager {
    static let label = "dev.pcstyle.stream-guard"

    static var plistURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(label).plist")
    }

    static var installedAppBinaryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Stream Guard.app/Contents/MacOS/StreamGuard")
    }

    static func isEnabled() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try writePlist()
            _ = try? shell("launchctl", "bootout", "gui/\(getuid())", plistURL.path)
            try shell("launchctl", "bootstrap", "gui/\(getuid())", plistURL.path)
        } else {
            _ = try? shell("launchctl", "bootout", "gui/\(getuid())", plistURL.path)
            if FileManager.default.fileExists(atPath: plistURL.path) {
                try FileManager.default.removeItem(at: plistURL)
            }
        }
    }

    private static func writePlist() throws {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [installedAppBinaryURL.path],
            "RunAtLoad": true,
            "KeepAlive": false,
            "EnvironmentVariables": ["STREAM_GUARD_AUTO_START": "0"],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
    }

    @discardableResult
    private static func shell(_ args: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/" + args[0])
        process.arguments = Array(args.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "LaunchAgentManager", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: output])
        }
        return output
    }
}
