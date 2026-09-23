import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let logs = home.appendingPathComponent("Library/Logs/TradutorDeVideos", isDirectory: true)
    static let cache = home.appendingPathComponent("Library/Caches/TradutorDeVideos", isDirectory: true)
}

enum Subprocess {
    struct Result: Sendable {
        let status: Int32
        let output: String
    }

    /// Apps abertos pelo Finder ou pelo launchd não herdam o PATH do shell; ffmpeg, deno e o Python do
    /// Homebrew ficam nestas pastas.
    static func environment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let inherited = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + inherited
        env.merge(extra) { _, new in new }
        return env
    }

    /// Abre em modo append de verdade (O_APPEND): o motor e o app escrevem no mesmo arquivo sem se sobrepor.
    static func openForAppending(_ url: URL) -> FileHandle? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        return descriptor >= 0 ? FileHandle(fileDescriptor: descriptor, closeOnDealloc: true) : nil
    }

    /// Roda até o fim fora da thread principal. Com `logTo`, stdout e stderr vão para o arquivo; sem ele,
    /// o stdout volta em `output`. `status` é -1 quando o executável nem chegou a iniciar.
    static func run(
        _ executable: String, _ arguments: [String], cwd: URL? = nil, logTo log: URL? = nil
    ) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.currentDirectoryURL = cwd
                process.environment = environment()
                process.standardInput = FileHandle.nullDevice

                var pipe: Pipe?
                if let log, let handle = openForAppending(log) {
                    let header = "\n$ \(([executable] + arguments).joined(separator: " "))\n"
                    try? handle.write(contentsOf: Data(header.utf8))
                    process.standardOutput = handle
                    process.standardError = handle
                } else {
                    pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = FileHandle.nullDevice
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Result(status: -1, output: error.localizedDescription))
                    return
                }
                let data = pipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
                process.waitUntilExit()
                continuation.resume(returning: Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self)))
            }
        }
    }
}
