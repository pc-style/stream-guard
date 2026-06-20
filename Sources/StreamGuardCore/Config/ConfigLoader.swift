import Foundation

public enum ConfigLoader {
    public static func defaultConfigURL() -> URL {
        if let bundled = Bundle.main.url(forResource: "blocklist.default", withExtension: "json") {
            return bundled
        }
        return URL(fileURLWithPath: "Resources/blocklist.default.json")
    }

    public static func userConfigURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("StreamGuard", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("blocklist.json")
    }

    public static func load(from url: URL) throws -> BlocklistConfig {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(BlocklistConfig.self, from: data)
    }

    public static func loadEffective() -> BlocklistConfig {
        let userURL = userConfigURL()
        if FileManager.default.fileExists(atPath: userURL.path) {
            if let config = try? load(from: userURL) {
                return config
            }
        }
        if let config = try? load(from: defaultConfigURL()) {
            return config
        }
        return .default
    }

    public static func save(_ config: BlocklistConfig, to url: URL = userConfigURL()) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: url, options: .atomic)
    }

    public static func seedUserConfigIfNeeded() {
        let userURL = userConfigURL()
        guard !FileManager.default.fileExists(atPath: userURL.path) else { return }
        if let defaultData = try? Data(contentsOf: defaultConfigURL()) {
            try? defaultData.write(to: userURL, options: .atomic)
        } else {
            try? save(BlocklistConfig.default, to: userURL)
        }
    }
}

public final class ConfigWatcher: @unchecked Sendable {
    public var onReload: ((BlocklistConfig) -> Void)?

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "dev.pcstyle.stream-guard.config-watcher")
    private let url: URL
    private var lastModified: Date?

    public init(url: URL = ConfigLoader.userConfigURL()) {
        self.url = url
    }

    public func start() {
        stop()
        lastModified = modificationDate()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.handleChange()
        }
        self.timer = timer
        timer.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    private func handleChange() {
        guard let modified = modificationDate() else { return }
        if let last = lastModified, modified <= last { return }
        lastModified = modified
        if let config = try? ConfigLoader.load(from: url) {
            onReload?(config)
        }
    }

    private func modificationDate() -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}
