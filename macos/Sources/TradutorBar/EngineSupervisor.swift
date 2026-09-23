import Foundation
import os

/// Mantém o motor Python de pé: adota um que já esteja respondendo na porta ou sobe o próprio, religa
/// quando cai e garante que o processo filho nunca sobreviva ao app.
@MainActor
final class EngineSupervisor {
    enum Phase: Equatable {
        case starting
        case running(owned: Bool)
        case stopped
        case notInstalled(String)
    }

    static let defaultPort = 47811
    private static let maxCrashes = 5
    private static let crashWindow: TimeInterval = 60
    private static let killGrace: TimeInterval = 3
    private static let maxLogBytes = 10_000_000

    let port: Int
    let engineDir: URL?
    var onPhaseChange: ((Phase) -> Void)?

    private(set) var phase: Phase = .starting {
        didSet { if phase != oldValue { onPhaseChange?(phase) } }
    }

    /// Processo nosso vivo, mas sem responder: provavelmente ocupado, então não é motivo para matar.
    var isUnresponsive: Bool { phase == .running(owned: true) && silentPolls >= 3 }

    private let client: EngineClient
    private let logger = Logger(subsystem: "local.arnaldo.tradutordevideos", category: "motor")
    private let logFile = Paths.logs.appendingPathComponent("motor-stdout.log")

    private var process: Process?
    private var watchdog: Process?
    private var crashTimes: [Date] = []
    private var silentPolls = 0
    private var generation = 0
    private var busy = false
    private var shuttingDown = false

    init(port: Int, engineDir: URL?, client: EngineClient) {
        self.port = port
        self.engineDir = engineDir
        self.client = client
    }

    static func configuredPort() -> Int {
        let raw = ProcessInfo.processInfo.environment["TDV_PORT"].flatMap { Int($0) }
        return raw.flatMap { (1...65535).contains($0) ? $0 : nil } ?? defaultPort
    }

    static func configuredEngineDir() -> URL? {
        let fromEnv = ProcessInfo.processInfo.environment["TDV_ENGINE_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let path = fromEnv ?? (Bundle.main.object(forInfoDictionaryKey: "TDVEngineDir") as? String)
        return path.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    // MARK: - Ciclo de vida

    func start() {
        guard !busy, !shuttingDown else { return }
        busy = true
        Task {
            await bringUp()
            busy = false
        }
    }

    func restart() async {
        guard !shuttingDown else { return }
        generation += 1 // cancela religamentos agendados por quedas anteriores
        while busy { try? await Task.sleep(for: .milliseconds(50)) }
        guard !shuttingDown else { return }
        busy = true
        defer { busy = false }

        crashTimes.removeAll()
        silentPolls = 0
        let wasAdopted = phase == .running(owned: false)
        phase = .starting
        await stopOwnedProcess()
        if wasAdopted { await stopAdoptedEngine() }
        await bringUp()
    }

    /// Síncrono de propósito: roda ao sair e ao receber sinais, quando não há mais run loop para esperar.
    func shutdown() {
        shuttingDown = true
        generation += 1
        guard let child = process else {
            stopWatchdog()
            return
        }
        process = nil
        child.terminationHandler = nil

        if child.isRunning {
            logger.info("encerrando o motor (pid \(child.processIdentifier))")
            child.terminate()
            let deadline = Date().addingTimeInterval(Self.killGrace)
            while child.isRunning, Date() < deadline { usleep(50_000) }
        }
        if child.isRunning {
            kill(child.processIdentifier, SIGKILL)
            let hardDeadline = Date().addingTimeInterval(2)
            while child.isRunning, Date() < hardDeadline { usleep(20_000) }
        }
        // Se nem o SIGKILL resolveu a tempo, o vigia fica vivo: ele termina o serviço quando o app sair.
        if !child.isRunning { stopWatchdog() }
    }

    // MARK: - Sinais vindos do polling

    func engineAnswered() {
        silentPolls = 0
        switch phase {
        case .starting, .stopped, .notInstalled:
            phase = .running(owned: process != nil)
        case .running:
            break
        }
    }

    func engineSilent() {
        silentPolls += 1
        switch phase {
        case .running(owned: false) where silentPolls >= 2:
            // O motor adotado sumiu: a partir daqui o motor passa a ser nosso.
            logger.info("motor adotado parou de responder: assumindo")
            silentPolls = 0
            start()
        case .notInstalled:
            // Depois de um `uv sync` o app se recupera sozinho, sem precisar reabrir.
            if let python = pythonURL, FileManager.default.isExecutableFile(atPath: python.path) { start() }
        default:
            break
        }
    }

    // MARK: - Subida

    private var pythonURL: URL? {
        // Sem resolver o symlink: é pelo caminho dentro da .venv que o Python encontra o ambiente virtual.
        engineDir?.appendingPathComponent(".venv/bin/python")
    }

    private func bringUp() async {
        guard !shuttingDown else { return }
        if let process, process.isRunning { return }

        if await client.health() {
            guard !shuttingDown, process == nil else { return }
            logger.info("motor já respondendo na porta \(self.port): adotado")
            silentPolls = 0
            phase = .running(owned: false)
            return
        }
        guard !shuttingDown, process == nil else { return }
        spawn()
    }

    private func spawn() {
        guard let engineDir, let python = pythonURL else {
            phase = .notInstalled("Motor não configurado: defina TDV_ENGINE_DIR ou gere o app com build.sh")
            return
        }
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            phase = .notInstalled("Motor não instalado: rode `uv sync` em engine/")
            return
        }

        rotateLogIfNeeded()
        let log = Subprocess.openForAppending(logFile)
        writeMarker("iniciando o motor na porta \(port)", to: log)

        let child = Process()
        child.executableURL = python
        child.arguments = ["-m", "dublador.server"]
        child.currentDirectoryURL = engineDir
        // TDV_PORT explícito para app e motor nunca discordarem da porta; sem buffer para o log sair na hora.
        child.environment = Subprocess.environment(extra: ["TDV_PORT": String(port), "PYTHONUNBUFFERED": "1"])
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = log ?? FileHandle.nullDevice
        child.standardError = log ?? FileHandle.nullDevice
        child.terminationHandler = { [weak self] finished in
            let pid = finished.processIdentifier
            let status = finished.terminationStatus
            let signaled = finished.terminationReason == .uncaughtSignal
            Task { @MainActor in self?.childDidExit(pid: pid, status: status, signaled: signaled) }
        }

        do {
            try child.run()
        } catch {
            logger.error("falha ao iniciar o motor: \(error.localizedDescription)")
            writeMarker("falha ao iniciar o motor: \(error.localizedDescription)", to: log)
            registerCrash()
            return
        }
        logger.info("motor iniciado (pid \(child.processIdentifier)) na porta \(self.port)")
        process = child
        silentPolls = 0
        phase = .starting
        startWatchdog(for: child.processIdentifier)
    }

    private func childDidExit(pid: Int32, status: Int32, signaled: Bool) {
        guard let current = process, current.processIdentifier == pid else { return }
        process = nil
        stopWatchdog()
        guard !shuttingDown else { return }

        let cause = signaled ? "sinal \(status)" : "código \(status)"
        logger.error("motor (pid \(pid)) encerrou sozinho: \(cause)")
        writeMarker("motor (pid \(pid)) encerrou sozinho: \(cause)", to: Subprocess.openForAppending(logFile))
        registerCrash()
    }

    private func registerCrash() {
        let now = Date()
        crashTimes = crashTimes.filter { now.timeIntervalSince($0) < Self.crashWindow } + [now]
        guard crashTimes.count < Self.maxCrashes else {
            logger.error("\(Self.maxCrashes) quedas em \(Int(Self.crashWindow)) s: desistindo até alguém pedir para reiniciar")
            phase = .stopped
            return
        }

        phase = .starting
        let delay = pow(2, Double(crashTimes.count - 1)) // 1, 2, 4, 8 s
        let expected = generation
        logger.info("religando o motor em \(Int(delay)) s")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.generation == expected else { return }
            self.start()
        }
    }

    // MARK: - Parada

    private func stopOwnedProcess() async {
        defer { stopWatchdog() }
        guard let child = process else { return }
        process = nil
        child.terminationHandler = nil
        guard child.isRunning else { return }

        child.terminate()
        let deadline = Date().addingTimeInterval(Self.killGrace)
        while child.isRunning, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        let hardDeadline = Date().addingTimeInterval(2)
        while child.isRunning, Date() < hardDeadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// O motor adotado não é filho nosso, então só dá para achá-lo pela porta. A linha de comando é
    /// conferida antes do sinal para nunca derrubar um túnel ou proxy que só esteja repassando a porta.
    private func stopAdoptedEngine() async {
        let listing = await Subprocess.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"])
        let pids = listing.output.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        for pid in pids where pid > 1 && pid != getpid() {
            let command = await Subprocess.run("/bin/ps", ["-o", "command=", "-p", String(pid)])
            guard command.output.contains("dublador.server") else { continue }

            logger.info("reiniciando o motor adotado (pid \(pid))")
            kill(pid, SIGTERM)
            let deadline = Date().addingTimeInterval(Self.killGrace)
            while kill(pid, 0) == 0, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    // MARK: - Vigia

    /// Se o app morrer sem chance de limpar (SIGKILL, crash), ninguém manda o SIGTERM no motor. O vigia
    /// fica bloqueado lendo um pipe cuja única ponta de escrita é nossa: quando o app some, o kernel
    /// fecha o pipe, o `read` volta e o vigia encerra o motor.
    private func startWatchdog(for pid: Int32) {
        let guardian = Process()
        guardian.executableURL = URL(fileURLWithPath: "/bin/sh")
        guardian.arguments = ["-c", "read -r ignored; kill -TERM \(pid) 2>/dev/null || exit 0; sleep 3; kill -KILL \(pid) 2>/dev/null"]
        guardian.standardInput = Pipe()
        guardian.standardOutput = FileHandle.nullDevice
        guardian.standardError = FileHandle.nullDevice
        do {
            try guardian.run()
            watchdog = guardian
        } catch {
            logger.error("vigia do motor não iniciou: \(error.localizedDescription)")
        }
    }

    private func stopWatchdog() {
        // SIGKILL e não fechar o pipe: fechar faria o vigia mandar sinal para um pid que já pode ser de outro.
        if let watchdog, watchdog.isRunning { kill(watchdog.processIdentifier, SIGKILL) }
        watchdog = nil
    }

    // MARK: - Log

    private func rotateLogIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: logFile.path)[.size] as? Int) ?? 0
        guard size > Self.maxLogBytes else { return }
        let previous = logFile.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: logFile, to: previous)
    }

    private func writeMarker(_ text: String, to handle: FileHandle?) {
        // Hora local no mesmo formato do motor.log, para dar para cruzar os dois arquivos.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let stamp = formatter.string(from: Date())
        try? handle?.write(contentsOf: Data("=== \(stamp) TradutorBar: \(text) ===\n".utf8))
    }
}
