import Combine
import Foundation
import SQLite3

/// Notices when Antigravity is working.
///
/// Its transcripts are appended to as an agent runs, so a file written moments
/// ago is a turn in progress. The step *statuses* cannot be used for this —
/// every one of them says `DONE`, because a step is only written once it is
/// finished. Recency is the signal there is.
///
/// Without this the Gemini ring never showed the working state that Claude,
/// Cursor and Codex all had, and the store never learned Antigravity was busy,
/// so it stayed on its slow idle poll while usage was actively being spent.
final class AntigravityActivityMonitor: AgentActivityMonitor {
    @Published private(set) var sessions: [AgentSession] = []
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }

    private let roots: [URL]
    private let interval: TimeInterval
    /// How recently a transcript must have been written to count as live.
    /// Generous, because a model can think for a while between two lines.
    private let staleAfter: TimeInterval
    private var timer: Timer?
    private var transcripts: [URL: TranscriptState] = [:]

    private struct TranscriptState {
        let modified: Date
        let state: AgentSession.State
        let waitingFor: String?
    }

    init(roots: [URL] = AntigravityActivity.transcriptRoots,
         interval: TimeInterval = 2,
         staleAfter: TimeInterval = 45) {
        self.roots = roots
        self.interval = interval
        self.staleAfter = staleAfter
    }

    convenience init(profile: AntigravityProfile,
                     interval: TimeInterval = 2,
                     staleAfter: TimeInterval = 45) {
        let roots = profile.slug == nil ? AntigravityActivity.transcriptRoots : [profile.brainDirectory]
        self.init(roots: roots, interval: interval, staleAfter: staleAfter)
    }

    func start() {
        stop()
        poll()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        transcripts.removeAll()
        sessions = []
    }

    private func poll() {
        let found = Self.read(roots: roots, staleAfter: staleAfter, now: Date(), cache: &transcripts)
        guard found != sessions else { return }
        sessions = found
    }

    static func read(roots: [URL], staleAfter: TimeInterval, now: Date = Date()) -> [AgentSession] {
        var cache: [URL: TranscriptState] = [:]
        return read(roots: roots, staleAfter: staleAfter, now: now, cache: &cache)
    }

    static func read(root: URL, staleAfter: TimeInterval, now: Date = Date()) -> [AgentSession] {
        read(roots: [root], staleAfter: staleAfter, now: now)
    }

    private static func read(roots: [URL], staleAfter: TimeInterval, now: Date,
                             cache: inout [URL: TranscriptState]) -> [AgentSession] {
        var newestByID: [String: (url: URL, modified: Date)] = [:]
        for root in roots {
            let trajectories = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for trajectory in trajectories {
                let path = trajectory.path + "/.system_generated/logs/transcript.jsonl"
                var info = stat()
                guard stat(path, &info) == 0 else { continue }
                let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                    + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
                let id = trajectory.lastPathComponent
                // Backup directories can contain a copy of the same turn.
                if let previous = newestByID[id], previous.modified >= modified { continue }
                newestByID[id] = (URL(fileURLWithPath: path), modified)
            }
        }

        let current = Set(newestByID.values.map(\.url))
        cache = cache.filter { current.contains($0.key) }
        return newestByID.compactMap { id, reading in
            let state: TranscriptState
            if let cached = cache[reading.url], cached.modified == reading.modified {
                state = cached
            } else {
                guard let data = tail(of: reading.url) else { return nil }
                let parsed = parseState(inTail: data)
                state = TranscriptState(modified: reading.modified, state: parsed.state,
                                        waitingFor: parsed.waitingFor)
                cache[reading.url] = state
            }
            return session(id: id, transcript: reading.url, reading: state, staleAfter: staleAfter, now: now)
        }.sorted { $0.since == $1.since ? $0.id < $1.id : $0.since > $1.since }
    }

    static func tail(of url: URL, bytes: Int = 64 * 1024) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(bytes) ? end - UInt64(bytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil else { return nil }
        return try? handle.readToEnd()
    }

    static func parseState(inTail data: Data) -> (state: AgentSession.State, waitingFor: String?) {
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        
        for line in lines.reversed() {
            guard let json = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = json["type"] as? String else { continue }
            
            if type == "USER_INPUT" {
                return (.busy, nil)
            } else if type == "PLANNER_RESPONSE" {
                if let toolCalls = json["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                    for call in toolCalls {
                        guard let name = call["name"] as? String else { continue }
                        if name.contains("ask_question") {
                            return (.waiting, L10n.t("Question"))
                        }
                        if name.contains("multi_replace_file_content") || name.contains("write_to_file") || name.contains("replace_file_content") {
                            if let args = call["arguments"] as? [String: Any],
                               let meta = args["ArtifactMetadata"] as? [String: Any],
                               meta["RequestFeedback"] as? Bool == true {
                                return (.waiting, L10n.t("Approval"))
                            }
                        }
                    }
                    return (.busy, nil)
                } else {
                    return (.idle, nil)
                }
            } else if type == "EPHEMERAL_MESSAGE" || type == "CONVERSATION_HISTORY" || type == "KNOWLEDGE_ARTIFACTS" || type == "CHECKPOINT" {
                continue
            } else {
                return (.busy, nil) // A tool response
            }
        }
        
        return (.idle, nil)
    }

    /// Only a transcript written within the window counts. An older one is a
    /// finished turn, and showing it as work in progress would be a guess
    /// dressed as a fact.
    private static func session(
        id: String, transcript: URL, reading: TranscriptState, staleAfter: TimeInterval, now: Date
    ) -> AgentSession? {
        var state = reading.state
        var waitingFor = reading.waitingFor
        
        if state == .busy {
            let root = transcript.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let dbURL = root.appendingPathComponent("conversations/\(id).db")
            
            if let db = SQLiteStore.open(dbURL) {
                defer { sqlite3_close(db) }
                let rows = SQLiteStore.rows(in: db, sql: "SELECT status FROM steps ORDER BY idx DESC LIMIT 1")
                if let first = rows.first, first.first == "2" {
                    state = .waiting
                    waitingFor = L10n.t("Permission")
                }
            }
        }
        
        let age = now.timeIntervalSince(reading.modified)
        
        if state == .idle {
            if age <= 9 {
                state = .success
            } else {
                return nil
            }
        } else if state == .busy {
            // Fallback timeout for busy state, just in case the file stops updating
            // due to a crash but the state didn't become idle.
            guard age <= staleAfter + 15 else { return nil }
        }
        // If state == .waiting, we do not expire it, it remains indefinitely.

        let detail: String
        switch state {
        case .busy: detail = L10n.t("Working")
        case .waiting: detail = waitingFor ?? L10n.t("Waiting")
        case .success: detail = L10n.t("Complete")
        case .idle: detail = L10n.t("Idle")
        }

        return AgentSession(
            id: "antigravity.\(id)",
            name: "Antigravity",
            detail: detail,
            state: state,
            waitingFor: waitingFor,
            since: reading.modified
        )
    }
}
