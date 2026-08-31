import Foundation

/// Minimal async subprocess runner with an optional watchdog.
enum Subprocess {
    struct TimedOut: Error, Equatable { let seconds: TimeInterval }

    static func run(
        _ executable: String, _ args: [String], cwd: URL? = nil,
        environment: [String: String]? = nil, timeout: TimeInterval? = nil
    ) async throws -> (stdout: String, stderr: String, code: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        if let environment { process.environment = environment }
        // Close stdin: `claude -p` and `codex exec` otherwise wait for piped input.
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let out = PipeCollector(outPipe), err = PipeCollector(errPipe)
        try process.run()

        let watchdog = Flag()
        if let timeout, timeout > 0 {
            // Signal the pid directly rather than trusting `isRunning` /
            // `terminate()` (the CI runner let a `sleep` run to completion).
            // SIGTERM first; SIGKILL 2s later can't be blocked or ignored.
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard kill(pid, SIGTERM) == 0 else { return }
                watchdog.set()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { _ = kill(pid, SIGKILL) }
            }
        }
        await Task.detached { process.waitUntilExit() }.value
        // Collect what arrived; don't wait for EOF, which never comes if a
        // grandchild inherited the pipe (a login shell's helper, an MCP server).
        let outData = await Task.detached { out.finish(grace: 0.3) }.value
        let errData = await Task.detached { err.finish(grace: 0.3) }.value
        // Only a signal death counts as a timeout: a process that exited on its
        // own just before the deadline (still a zombie when signalled) is fine.
        if watchdog.isSet, process.terminationReason == .uncaughtSignal {
            throw TimedOut(seconds: timeout ?? 0)
        }
        return (
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self),
            process.terminationStatus
        )
    }

    /// Drains a pipe as data arrives (so a chatty child can't fill the 64 KB
    /// buffer and deadlock) and lets the caller stop waiting once the child has
    /// exited, even if some grandchild still holds the write end open.
    private final class PipeCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var eof = false
        private let handle: FileHandle

        init(_ pipe: Pipe) {
            handle = pipe.fileHandleForReading
            handle.readabilityHandler = { [weak self] h in
                let chunk = h.availableData
                guard let self else { return }
                self.lock.lock(); defer { self.lock.unlock() }
                if chunk.isEmpty {
                    self.eof = true
                    h.readabilityHandler = nil
                } else {
                    self.data.append(chunk)
                }
            }
        }

        /// Call after the child exited: wait up to `grace` for EOF (a
        /// well-behaved child closes its end at exit), then return what arrived.
        func finish(grace: TimeInterval) -> Data {
            let deadline = Date().addingTimeInterval(grace)
            while Date() < deadline {
                lock.lock(); let done = eof; lock.unlock()
                if done { break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            handle.readabilityHandler = nil
            lock.lock(); defer { lock.unlock() }
            return data
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
}

/// PATH plumbing for the CLI-backed providers (`claude`, `codex`).
///
/// A GUI app inherits a bare PATH (`/usr/bin:/bin:/usr/sbin:/sbin`). A login
/// shell (`zsh -lc`) adds what `.zprofile` adds (Homebrew) but NOT what `.zshrc`
/// adds — nvm, volta, bun, `~/.local/bin` — so tools installed through version
/// managers stay invisible. We union the login PATH with the well-known tool
/// directories, and when running a tool we put its own directory first so a
/// `#!/usr/bin/env node` script finds the sibling `node`.
enum CLIEnvironment {
    private actor Cache {
        static let shared = Cache()
        var path: String?
        func set(_ p: String) { path = p }
    }

    /// Login-shell PATH ∪ known tool dirs ∪ our own PATH, deduped. Resolved once.
    static func augmentedPATH() async -> String {
        if let cached = await Cache.shared.path { return cached }
        var dirs: [String] = []
        if let (out, _, code) = try? await Subprocess.run("/bin/zsh", ["-lc", "printf %s \"$PATH\""], timeout: 10),
           code == 0 {
            dirs += out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":").map(String.init)
        }
        dirs += extraToolDirs()
        dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let path = dedupe(dirs).joined(separator: ":")
        await Cache.shared.set(path)
        return path
    }

    /// Directories that `.zshrc`-style setup would add; only those that exist.
    static func extraToolDirs(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        fileManager: FileManager = .default
    ) -> [String] {
        var dirs = nvmBinDirs(home: home, fileManager: fileManager)
        dirs += [
            "\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.volta/bin", "\(home)/.cargo/bin",
            "/opt/homebrew/bin", "/usr/local/bin",
        ]
        return dirs.filter { fileManager.fileExists(atPath: $0) }
    }

    /// Every nvm-installed node's `bin`, the `default` alias first, then newest.
    static func nvmBinDirs(home: String, fileManager: FileManager = .default) -> [String] {
        let root = "\(home)/.nvm/versions/node"
        guard let versions = try? fileManager.contentsOfDirectory(atPath: root) else { return [] }
        let alias = (try? String(contentsOfFile: "\(home)/.nvm/alias/default", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        func isDefault(_ v: String) -> Bool {
            !alias.isEmpty && (v == alias || v == "v\(alias)" || v.hasPrefix("v\(alias)."))
        }
        return versions
            .sorted { a, b in
                if isDefault(a) != isDefault(b) { return isDefault(a) }
                return a.compare(b, options: .numeric) == .orderedDescending
            }
            .map { "\(root)/\($0)/bin" }
    }

    /// First executable named `tool` on the augmented PATH, else the first
    /// existing fallback path.
    static func resolve(_ tool: String, fallbacks: [String] = []) async -> String? {
        let fm = FileManager.default
        for dir in (await augmentedPATH()).split(separator: ":") {
            let candidate = "\(dir)/\(tool)"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return fallbacks.first { fm.isExecutableFile(atPath: $0) }
    }

    /// Our environment with PATH = the tool's own directory + the augmented PATH.
    static func environment(for executable: String) async -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = pathPrepending(executable, to: await augmentedPATH())
        return env
    }

    static func pathPrepending(_ executable: String, to path: String) -> String {
        let own = (executable as NSString).deletingLastPathComponent
        return dedupe([own] + path.split(separator: ":").map(String.init)).joined(separator: ":")
    }

    static func dedupe(_ dirs: [String]) -> [String] {
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// `claude -p` / `codex exec` don't stream tokens; emit the finished text in
/// word chunks so the panel still animates.
func emitInWordChunks(_ result: String, _ onEvent: (RewriteEvent) -> Void) {
    var emitted = ""
    for word in result.split(separator: " ", omittingEmptySubsequences: false) {
        let chunk = (emitted.isEmpty ? "" : " ") + word
        emitted += chunk
        onEvent(.content(chunk))
    }
}
