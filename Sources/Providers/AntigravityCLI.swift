import Darwin
import Foundation

/// Reads the installed CLI's own signed-in account through its read-only report.
enum AntigravityCLI {
    static func quota() async throws -> [LimitWindow] {
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser
        let paths = [home.appendingPathComponent(".local/bin/agy").path,
                     "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
        guard let binary = paths.first(where: { path in
            var directory: ObjCBool = false
            return files.fileExists(atPath: path, isDirectory: &directory)
                && !directory.boolValue && files.isExecutableFile(atPath: path)
        }) else {
            throw UsageProviderError.apiError(L10n.t("Install the Antigravity CLI to read its usage."))
        }
        return try await quota(binary: binary, home: home)
    }

    static func quota(binary: String, home: URL) async throws -> [LimitWindow] {
        let files = FileManager.default
        let workspace = files.temporaryDirectory.appendingPathComponent("notch-antigravity-\(UUID().uuidString)")
        try files.createDirectory(at: workspace, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: workspace) }

        // Refreshes have no interactive sign-in. Keep the CLI's browser launch
        // helpers inside this private working directory.
        for name in ["open", "xdg-open"] {
            let launcher = workspace.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 1\n".utf8).write(to: launcher)
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        }
        let environment = ["HOME=\(home.path)", "PATH=\(workspace.path):/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
                           "BROWSER=\(workspace.appendingPathComponent("open").path)",
                           "AGY_CLI_DISABLE_AUTO_UPDATE=true", "TERM=dumb"]
        let version = try await run(binary, arguments: ["--version"], environment: environment,
                                    workspace: workspace, timeout: .seconds(3))
        // Prior versions could pass /usage through as a model prompt.
        guard supportsUsageReport(String(decoding: version, as: UTF8.self)) else {
            throw UsageProviderError.apiError(L10n.t("Update the Antigravity CLI to read its usage."))
        }
        let data = try await run(binary, arguments: ["-p", "/usage", "--output-format", "json", "--print-timeout", "25s"],
                                 environment: environment, workspace: workspace, timeout: .seconds(35))
        let windows = AntigravityQuotaParser.parseCLI(data)
        guard !windows.isEmpty else {
            throw UsageProviderError.apiError(L10n.t("The Antigravity CLI returned no measured quota."))
        }
        return windows
    }

    static func supportsUsageReport(_ output: String) -> Bool {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = text.split(separator: ".").compactMap { Int($0) }
        guard components.count == 3, components.allSatisfy({ $0 >= 0 }),
              text.split(separator: ".", omittingEmptySubsequences: false).count == 3 else { return false }
        return !components.lexicographicallyPrecedes([1, 1, 11])
    }

    /// Give each invocation its own process group so a timeout or cancellation
    /// also cleans up children the CLI started. Only bounded stdout is kept.
    private static func run(_ binary: String, arguments: [String], environment: [String],
                            workspace: URL, timeout: Duration) async throws -> Data {
        try Task.checkCancellation()
        guard !PersistentWrites.isSuspended else { throw CancellationError() }
        let output = Pipe()
        let reader = output.fileHandleForReading
        let writer = output.fileHandleForWriting
        let fd = reader.fileDescriptor
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw UsageProviderError.badResponse(status: 0) }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw UsageProviderError.badResponse(status: 0) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw UsageProviderError.badResponse(status: 0) }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, workspace.path) == 0,
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, writer.fileDescriptor, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, writer.fileDescriptor) == 0,
              posix_spawn_file_actions_addclose(&actions, fd) == 0
        else { throw UsageProviderError.badResponse(status: 0) }

        var argv = ([binary] + arguments).map { strdup($0) }
        var envp = environment.map { strdup($0) }
        defer { (argv + envp).forEach { free($0) } }
        guard (argv + envp).allSatisfy({ $0 != nil }) else { throw UsageProviderError.badResponse(status: 0) }
        argv.append(nil)
        envp.append(nil)
        var pid: pid_t = 0
        guard posix_spawn(&pid, binary, &actions, &attributes, &argv, &envp) == 0 else {
            throw UsageProviderError.apiError(L10n.t("Could not start the Antigravity CLI."))
        }
        try? writer.close()
        var exitStatus: Int32 = 0
        defer {
            // Keep the group leader unreaped until after the signal, so its
            // PID cannot have been recycled as an unrelated group ID.
            _ = killpg(pid, SIGKILL)
            while waitpid(pid, &exitStatus, 0) == -1 && errno == EINTR {}
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while clock.now < deadline {
            try Task.checkCancellation()
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                guard data.count + count <= 1024 * 1024 else { throw UsageProviderError.badResponse(status: 0) }
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count < 0 && errno == EINTR { continue }
            guard count == 0 || errno == EAGAIN else { throw UsageProviderError.badResponse(status: 0) }

            var info = siginfo_t()
            guard waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 else {
                if errno == EINTR { continue }
                throw UsageProviderError.badResponse(status: 0)
            }
            if info.si_pid != 0 {
                guard info.si_code == CLD_EXITED, info.si_status == 0 else {
                    throw UsageProviderError.apiError(L10n.t("Could not read Antigravity CLI usage. Check your sign-in in agy."))
                }
                // Bytes written between the nonblocking read and exit still
                // belong to this report. Drain them before returning.
                while true {
                    let tail = read(fd, &buffer, buffer.count)
                    if tail < 0 && errno == EINTR { continue }
                    guard tail > 0 else { return data }
                    guard data.count + tail <= 1024 * 1024 else { throw UsageProviderError.badResponse(status: 0) }
                    data.append(contentsOf: buffer.prefix(tail))
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw UsageProviderError.timedOut
    }
}
