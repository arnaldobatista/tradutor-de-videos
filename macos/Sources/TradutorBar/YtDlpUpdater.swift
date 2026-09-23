import Foundation

/// O YouTube quebra o yt-dlp de tempos em tempos; atualizar só esse pacote resolve sem mexer no resto do lock.
enum YtDlpUpdater {
    private static let logFile = Paths.logs.appendingPathComponent("atualizar-yt-dlp.log")

    static func run(engineDir: URL) async -> Bool {
        guard let uv = findUv() else {
            if let handle = Subprocess.openForAppending(logFile) {
                try? handle.write(contentsOf: Data("\nuv não encontrado em ~/.local/bin, /opt/homebrew/bin nem /usr/local/bin\n".utf8))
            }
            return false
        }
        // A saída vai para arquivo (e não para um pipe) para o uv terminar em paz mesmo se o app sair no meio.
        for arguments in [["lock", "--upgrade-package", "yt-dlp"], ["sync"]] {
            let result = await Subprocess.run(uv, arguments, cwd: engineDir, logTo: logFile)
            guard result.status == 0 else { return false }
        }
        return true
    }

    private static func findUv() -> String? {
        let candidates = [Paths.home.appendingPathComponent(".local/bin/uv").path, "/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
