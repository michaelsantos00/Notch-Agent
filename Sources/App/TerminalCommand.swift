import AppKit
import Foundation

/// A command-line tool's login runs in the user's terminal, because that is
/// where the tool expects to be: it prints a URL, opens the browser and waits
/// for the callback on its own port. NotchAgent only has to type the command
/// into a fresh window of whichever terminal is installed.
enum TerminalCommand {
    /// Ghostty and iTerm2 before Terminal, because whoever has installed one
    /// of them has done so to use it instead.
    static let terminals: [(bundleID: String, name: String)] = [
        ("com.mitchellh.ghostty", "Ghostty"), ("com.googlecode.iterm2", "iTerm2"), ("com.apple.Terminal", "Terminal"),
    ]

    static func installed() -> [(bundleID: String, name: String)] {
        terminals.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

    private static var installedCache: [String: (at: Date, ok: Bool)] = [:]
    private static let cacheLock = NSLock()

    /// Whether the program a command starts with is on this Mac: the first
    /// word that is not an environment assignment, looked up where the usual
    /// installers put binaries and then on the login shell's PATH. A settings
    /// row asks on every redraw, so the answer is kept for a minute.
    static func isInstalled(command: String) -> Bool {
        let words = command.split(separator: " ").map(String.init)
        guard let binary = words.first(where: { !$0.contains("=") }) else { return false }
        // The lock guards the cache and nothing else. Held across the shell
        // below, it hung the app: see `loginShellFinds`.
        cacheLock.lock()
        let cached = installedCache[binary]
        cacheLock.unlock()
        if let cached, Date().timeIntervalSince(cached.at) < 60 { return cached.ok }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin",
                    "\(home)/.bun/bin", "\(home)/.cargo/bin", "\(home)/.grok/bin", "/usr/bin"]
        dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var ok = dirs.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(binary)") }
        // Automatic login shell process execution is disabled in this private build.
        // Binary detection relies on static well-known paths and inherited PATH.
        cacheLock.lock()
        installedCache[binary] = (Date(), ok)
        cacheLock.unlock()
        return ok
    }

    /// Login shell subprocess invocation is disabled for privacy.
    private static func loginShellFinds(_ binary: String) -> Bool {
        return false
    }

    /// Run a command in a new window of the first installed terminal.
    @MainActor static func run(_ cmd: String) {
        let choice = installed().first?.bundleID ?? "com.apple.Terminal"
        let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script: String
        switch choice {
        case "com.mitchellh.ghostty":
            // Ghostty has no "do script"; the window needs a moment to have a
            // terminal before text can be typed into it.
            script = """
            tell application "Ghostty"
                activate
                set w to new window
                delay 0.8
                set t to focused terminal of selected tab of front window
                input text "\(escaped)" to t
                send key "enter" to t
            end tell
            """
        case "com.googlecode.iterm2":
            script = """
            tell application "iTerm2"
                activate
                create window with default profile
                delay 0.5
                tell current session of current window to write text "\(escaped)"
            end tell
            """
        default:
            script = "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell"
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            try? p.run()
        }
    }
}
