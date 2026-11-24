import Darwin
import Foundation

/// A user-installed Cursor command hook. The helper keeps only turn identifiers and state.
struct CursorActivityHooks {
    static let argument = "--notchagent-cursor-activity-hook"
    private static let events = ["beforeSubmitPrompt", "preToolUse", "stop", "sessionEnd"]
    private let config: URL
    private let stateDirectory: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        config = home.appendingPathComponent(".cursor/hooks.json")
        stateDirectory = home.appendingPathComponent("Library/Caches/com.vinz.codenotch/CursorActivity")
    }

    private struct Input: Decodable {
        let hook_event_name: String
        let conversation_id: String
        let generation_id: String?
        let status: String?
    }

    private struct Turn: Codable {
        enum State: String, Codable { case busy, finished, stopped }
        let id: String
        let generation: String
        let state: State
        let at: Date
    }

    private var enabled: Bool { FileManager.default.fileExists(atPath: stateDirectory.path) }

    var isInstalled: Bool {
        guard enabled, let (_, root) = try? configuration(),
              let hooks = root["hooks"] as? [String: [[String: Any]]] else { return false }
        return Self.events.allSatisfy { hooks[$0]?.contains(where: Self.owns) == true }
    }

    func setInstalled(_ install: Bool, executable: URL? = Bundle.main.executableURL) throws {
        let files = FileManager.default
        let (original, root) = try configuration()
        var updated = root
        var hooks = (root["hooks"] as? [String: [[String: Any]]]) ?? [:]
        // Each script command is a quoted absolute path. These are the only entries this installer owns.
        guard !install || executable != nil else { throw ConfigError.executable }
        let escaped = executable?.path.replacingOccurrences(of: "'", with: "'\\''") ?? ""
        for event in Self.events {
            var handlers = hooks[event, default: []].filter { !Self.owns($0) }
            if install { handlers.append(["command": "'\(escaped)' \(Self.argument)", "timeout": 3]) }
            if hooks[event] != nil || install { hooks[event] = handlers }
        }
        if install || root["hooks"] != nil { updated["hooks"] = hooks }
        if install && updated["version"] == nil { updated["version"] = 1 }

        let createState = install && !enabled
        if install {
            try files.createDirectory(at: stateDirectory, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
        }
        do {
            if install || original != nil {
                try writeConfiguration(updated, replacing: original)
            }
        } catch {
            if createState { try? files.removeItem(at: stateDirectory) }
            throw error
        }
        if !install && enabled {
            try files.removeItem(at: stateDirectory)
        }
    }

    private func writeConfiguration(_ root: [String: Any], replacing original: Data?) throws {
        let files = FileManager.default
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let directory = config.deletingLastPathComponent()
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        if let original {
            let backup = directory.appendingPathComponent("hooks.json.notchagent-backup-\(UUID().uuidString)")
            try files.copyItem(at: config, to: backup)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            guard try Data(contentsOf: backup) == original else { throw ConfigError.backup }
        }
        let pending = directory.appendingPathComponent(".hooks.json.notchagent-\(UUID().uuidString)")
        defer { try? files.removeItem(at: pending) }
        guard files.createFile(atPath: pending.path, contents: data, attributes: [.posixPermissions: 0o600]),
              try Data(contentsOf: pending) == data else { throw CocoaError(.fileWriteUnknown) }
        guard try configuration().0 == original else { throw ConfigError.changed }
        guard rename(pending.path, config.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private enum ConfigError: LocalizedError {
        case invalid, changed, backup, executable
        var errorDescription: String? {
            switch self {
            case .invalid: return L10n.t("Cursor’s hooks file is invalid or uses an unsupported format.")
            case .changed: return L10n.t("Cursor’s hooks file changed during the update. Try again.")
            case .backup: return L10n.t("Could not verify the backup of Cursor’s hooks file.")
            case .executable: return L10n.t("Could not locate the NotchAgent executable.")
            }
        }
    }

    private func configuration() throws -> (Data?, [String: Any]) {
        let data: Data
        do {
            data = try Data(contentsOf: config)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return (nil, [:])
        }
        let attributes = try config.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["hooks"] == nil || root["hooks"] is [String: [[String: Any]]],
              root["version"] == nil || root["version"] as? Int == 1
        else { throw ConfigError.invalid }
        return (data, root)
    }

    private static func owns(_ handler: [String: Any]) -> Bool {
        (handler["command"] as? String)?.hasSuffix("/Contents/MacOS/NotchAgent' \(argument)") == true
    }

    /// The global Cursor config is shared with the editor. Accept only events
    /// run under a Cursor CLI process, leaving the editor on its native reader.
    static func runHelper() {
        defer { print("{}") }
        guard Preferences.storedCursorConnection(), hasCLIAncestor() else { return }
        let hooks = CursorActivityHooks()
        guard hooks.enabled else { return }
        var data = Data()
        while let chunk = try? FileHandle.standardInput.read(upToCount: 16_384), !chunk.isEmpty {
            guard data.count + chunk.count <= 1_048_576 else { return }
            data.append(chunk)
        }
        hooks.record(data)
    }

    private static func hasCLIAncestor() -> Bool {
        var pid = getppid()
        for _ in 0..<8 where pid > 1 {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
                let path = String(cString: buffer)
                if URL(fileURLWithPath: path).lastPathComponent == "cursor-agent" { return true }
            }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
            pid = info.kp_eproc.e_ppid
        }
        return false
    }

    func record(_ data: Data, now: Date = Date()) {
        guard let input = try? JSONDecoder().decode(Input.self, from: data),
              Self.validID(input.conversation_id), let generation = input.generation_id,
              Self.validID(generation) else { return }
        let state: Turn.State
        switch input.hook_event_name {
        case "beforeSubmitPrompt", "preToolUse": state = .busy
        case "stop": state = input.status == "completed" ? .finished : .stopped
        case "sessionEnd": state = .stopped
        default: return
        }

        withStateLock {
            let file = stateDirectory.appendingPathComponent("\(input.conversation_id).json")
            if let current = Self.readTurn(file) {
                if current.generation == generation && current.state != .busy { return }
                if current.generation != generation && input.hook_event_name != "beforeSubmitPrompt" { return }
            }
            let turn = Turn(id: input.conversation_id, generation: generation, state: state, at: now)
            guard let bytes = try? JSONEncoder().encode(turn) else { return }
            try? bytes.write(to: file, options: .atomic)
        }
    }

    func sessions(now: Date = Date(), staleAfter: TimeInterval) -> [AgentSession] {
        var sessions: [AgentSession] = []
        withStateLock {
            let files = (try? FileManager.default.contentsOfDirectory(at: stateDirectory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json" {
                guard let turn = Self.readTurn(file) else { continue }
                let age = now.timeIntervalSince(turn.at)
                if age > staleAfter {
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
                let state: AgentSession.State
                switch turn.state {
                case .busy: state = .busy
                case .finished where age <= 9: state = .success
                default: continue
                }
                sessions.append(AgentSession(id: "cursor.\(turn.id)", name: "Cursor CLI",
                    detail: state == .busy ? L10n.t("Working") : L10n.t("Complete"),
                    state: state, waitingFor: nil, since: turn.at))
            }
        }
        return sessions
    }

    private static func readTurn(_ file: URL) -> Turn? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Turn.self, from: data)
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private func withStateLock(_ action: () -> Void) {
        let lock = stateDirectory.appendingPathComponent(".lock")
        let fd = Darwin.open(lock.path, O_CREAT | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { return }
        }
        action()
    }
}
