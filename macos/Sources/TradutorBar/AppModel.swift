import AppKit
import ServiceManagement
import os

/// Estado que o menu mostra: fase do motor, último `/status`, ajustes (com atualização otimista) e avisos.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var phase: EngineSupervisor.Phase = .starting
    @Published private(set) var unresponsive = false
    @Published private(set) var status: EngineStatus?
    @Published private(set) var settings: EngineSettings?
    @Published private(set) var flash: String?
    @Published private(set) var updatingYtDlp = false
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginNote: String?
    /// nil = ainda não verificado (ou não é preciso: cookies vêm pela extensão).
    @Published private(set) var fullDiskAccess: Bool?
    /// Voz cuja amostra está carregando / tocando: o botão de ouvir mostra isso.
    @Published private(set) var sampleLoading: String?
    @Published private(set) var samplePlaying: String?

    private let client: EngineClient
    private let supervisor: EngineSupervisor
    private let logger = Logger(subsystem: "local.arnaldo.tradutordevideos", category: "app")
    private var pollTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?
    private var loginError: String?
    private var sound: NSSound?
    private var soundDelegate: SoundDelegate?
    /// Cresce a cada escrita de ajuste: um `/status` pedido antes da escrita não pode desfazer o valor otimista.
    private var settingsEpoch = 0

    init() {
        let port = EngineSupervisor.configuredPort()
        client = EngineClient(port: port)
        supervisor = EngineSupervisor(port: port, engineDir: EngineSupervisor.configuredEngineDir(), client: client)
        supervisor.onPhaseChange = { [weak self] in self?.phase = $0 }
    }

    func start() {
        guard pollTask == nil else { return }
        refreshLoginStatus()
        supervisor.start()
        pollTask = Task { [weak self] in await self?.pollLoop() }
    }

    func shutdown() {
        pollTask?.cancel()
        supervisor.shutdown()
    }

    // MARK: - Valores derivados para o menu

    private var phaseIsRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// Os controles só ficam ativos quando uma escrita tem chance real de chegar ao motor.
    var controlsEnabled: Bool { phaseIsRunning && !unresponsive && settings != nil }

    var currentJob: Job? { phaseIsRunning ? status?.jobs.current : nil }

    var queuedCount: Int { phaseIsRunning ? status?.jobs.queued.count ?? 0 : 0 }

    var iconName: String {
        switch phase {
        case .stopped, .notInstalled: return "exclamationmark.triangle"
        case .starting: return "waveform.slash"
        case .running:
            if currentJob != nil { return "waveform.circle.fill" }
            return unresponsive ? "waveform.slash" : "waveform"
        }
    }

    var percentText: String? { currentJob.map(Self.percent) }

    enum Tone { case good, busy, bad }

    var tone: Tone {
        switch phase {
        case .stopped, .notInstalled: return .bad
        case .starting: return .busy
        case .running: return unresponsive ? .busy : .good
        }
    }

    var headline: String {
        switch phase {
        case .starting: return "Iniciando o motor…"
        case .stopped: return "Motor parado"
        case .notInstalled: return "Motor não instalado"
        case .running: return unresponsive ? "Motor sem resposta…" : "Motor ativo"
        }
    }

    var versionText: String? { phaseIsRunning ? status.map { "v\($0.version)" } : nil }

    /// Só quando o usuário precisa agir: o painel mostra isso num aviso com o botão de reiniciar.
    var problem: String? {
        switch phase {
        case .stopped: return "O motor caiu várias vezes seguidas e não foi religado."
        case .notInstalled(let message): return message
        case .starting, .running: return nil
        }
    }

    /// Mensagem passageira (resultado de uma ação) ou tarefa longa em andamento.
    var notice: String? { updatingYtDlp ? "Atualizando o yt-dlp…" : flash }

    var jobTitle: String? {
        guard let job = currentJob else { return nil }
        let title = job.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Vídeo \(job.videoId)" : title
    }

    var jobStage: String { currentJob?.stageLabel.flatMap { $0.isEmpty ? nil : $0 } ?? "Na fila" }

    var jobFraction: Double { min(max(currentJob?.progress ?? 0, 0), 1) }

    /// Com uma dublagem em andamento o cartão dela é o foco: o histórico encolhe para o painel não crescer.
    var recentJobs: [Job] { phaseIsRunning ? Array((status?.jobs.recent ?? []).prefix(currentJob == nil ? 3 : 2)) : [] }

    var voiceOptions: [VoiceOption] {
        // JSON não garante ordem de chaves: ordenar pelo id mantém o submenu estável entre atualizações.
        (status?.voices ?? [:]).sorted { $0.key < $1.key }.map { VoiceOption(id: $0.key, name: $0.value) }
    }

    var cacheDetail: String {
        guard phaseIsRunning, let bytes = status?.cacheBytes else { return "—" }
        guard let limit = settings?.cacheLimitGb, limit > 0 else { return Self.formatBytes(bytes) }
        return "\(Self.formatBytes(bytes)) de \(Self.formatBytes(Int64(limit * 1_000_000_000)))"
    }

    var cacheFraction: Double {
        guard phaseIsRunning, let bytes = status?.cacheBytes, let limit = settings?.cacheLimitGb, limit > 0 else { return 0 }
        return min(1, Double(bytes) / (limit * 1_000_000_000))
    }

    var cacheIsEmpty: Bool { (status?.cacheBytes ?? 0) == 0 }

    var browserName: String {
        settings?.cookiesFromBrowser?.split(separator: ":").first.map { String($0).capitalized } ?? ""
    }

    /// O usuário escolheu ler os cookies do navegador pelo yt-dlp (o caminho que precisa de permissão).
    var wantsBrowserCookies: Bool { settings?.useCookies == true && !browserName.isEmpty }

    /// Situação dos cookies, mostrada nos Ajustes ao lado da origem escolhida.
    var cookiesCaption: String {
        guard settings?.useCookies == true else { return "Desligados" }
        guard wantsBrowserCookies else { return "Enviados pela extensão, sem permissão extra" }
        if fullDiskAccess == false { return "Falta o Acesso Total ao Disco" }
        switch status?.cookies?.browserOk {
        case .some(true): return "Funcionando"
        case .some(false): return "Falhou na última dublagem (veja os logs)"
        case .none: return "Confere na próxima dublagem"
        }
    }

    /// Só aparece quando o usuário quer os cookies do navegador e a permissão falta.
    var needsFullDiskAccess: Bool { wantsBrowserCookies && fullDiskAccess == false }

    var voiceOffset: Double { settings?.voiceOffsetDb ?? 0 }

    var canRestart: Bool { !updatingYtDlp }

    private static func percent(_ job: Job) -> String {
        let fraction = min(max(job.progress ?? 0, 0), 1)
        return "\(Int((fraction * 100).rounded()))%"
    }

    static func formatBytes(_ bytes: Int64) -> String {
        // Base decimal, como o Finder, para o número bater com o que a pasta do cache mostra.
        let megabytes = Double(max(bytes, 0)) / 1_000_000
        if megabytes < 1000 { return String(format: "%.0f MB", megabytes) }
        return String(format: "%.1f GB", locale: Locale(identifier: "pt_BR"), megabytes / 1000)
    }

    // MARK: - Polling

    private func pollLoop() async {
        var tick = 0
        while !Task.isCancelled {
            await refresh()
            // O usuário pode mexer nos Itens de Início pelos Ajustes do Sistema; reler de vez em quando basta.
            if tick % 15 == 14 { refreshLoginStatus() }
            tick += 1
            let fast = currentJob != nil || phase == .starting
            try? await Task.sleep(for: .seconds(fast ? 1 : 2))
        }
    }

    private func checkFullDiskAccess() {
        guard wantsBrowserCookies else {
            if fullDiskAccess != nil { fullDiskAccess = nil }
            return
        }
        let granted = FullDiskAccess.isGranted()
        if fullDiskAccess == false && granted {
            // Acabou de ser concedido: o motor novo já nasce com a permissão.
            if currentJob == nil {
                showFlash("Acesso Total ao Disco concedido. Reiniciando o motor…")
                Task { await supervisor.restart() }
            } else {
                showFlash("Acesso Total ao Disco concedido. Vale a partir da próxima dublagem.")
            }
        }
        if fullDiskAccess != granted { fullDiskAccess = granted }
    }

    private func refresh() async {
        let epoch = settingsEpoch
        do {
            let fresh = try await client.status()
            supervisor.engineAnswered()
            // Só publica quando muda: reconstruir o menu a cada tick atrapalharia quem está com ele aberto.
            if status != fresh { status = fresh }
            if epoch == settingsEpoch, settings != fresh.settings { settings = fresh.settings }
        } catch {
            if error is DecodingError { logger.error("/status fora do contrato: \(String(describing: error))") }
            supervisor.engineSilent()
        }
        if unresponsive != supervisor.isUnresponsive { unresponsive = supervisor.isUnresponsive }
        checkFullDiskAccess()
        syncAccent()
    }

    /// Publica a cor de destaque do macOS no motor, de onde a extensão lê para pintar o botão do YouTube e o
    /// popup com a mesma cor do app. Roda a cada /status: trocar a cor nos Ajustes do Sistema chega em até 2 s.
    private func syncAccent() {
        guard controlsEnabled, let current = settings, let hex = Self.accentHex() else { return }
        if current.uiAccent != hex { write(\.uiAccent, key: "ui_accent", value: Optional(hex), silent: true) }
    }

    static func accentHex() -> String? {
        guard let color = NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return nil }
        let channel = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(color.redComponent), channel(color.greenComponent), channel(color.blueComponent))
    }

    // MARK: - Ajustes

    func setVoice(_ id: String) { write(\.voice, key: "voice", value: id) }
    func setTranslator(_ id: String) { write(\.translator, key: "translator", value: id) }
    func setOllamaFallback(_ on: Bool) { write(\.ollamaFallback, key: "ollama_fallback", value: on) }
    func setOllamaAssist(_ on: Bool) { write(\.ollamaAssist, key: "ollama_assist", value: on) }
    func setUseCookies(_ on: Bool) { write(\.useCookies, key: "use_cookies", value: on) }
    /// "" = cookies enviados pela extensão; "chrome" = lidos do navegador pelo yt-dlp.
    func setCookiesSource(_ browser: String) { write(\.cookiesFromBrowser, key: "cookies_from_browser", value: Optional(browser)) }
    func setVoiceOffset(_ db: Double) { write(\.voiceOffsetDb, key: "voice_offset_db", value: Optional(db)) }
    func setCacheLimit(_ gb: Double) { write(\.cacheLimitGb, key: "cache_limit_gb", value: Optional(gb)) }

    private func write<Value: Encodable & Equatable & Sendable>(
        _ keyPath: WritableKeyPath<EngineSettings, Value>, key: String, value: Value, silent: Bool = false
    ) {
        guard var optimistic = settings, optimistic[keyPath: keyPath] != value else { return }
        optimistic[keyPath: keyPath] = value
        settings = optimistic
        settingsEpoch += 1

        Task {
            do {
                let saved = try await client.updateSetting(key, value)
                settingsEpoch += 1
                settings = saved
            } catch {
                logger.error("PUT /settings \(key) falhou: \(error.localizedDescription)")
                settingsEpoch += 1
                if !silent { showFlash("Não foi possível salvar o ajuste") }
                await refresh() // volta ao valor que o motor realmente tem
            }
        }
    }

    // MARK: - Ações

    func cancelCurrentJob() {
        guard let id = currentJob?.id else { return }
        Task {
            do { try await client.cancelJob(id: id) } catch { showFlash("Não foi possível cancelar a dublagem") }
            await refresh()
        }
    }

    func clearCache() {
        Task {
            do {
                let freed = try await client.clearCache()
                showFlash("Cache limpo: \(Self.formatBytes(freed)) liberados")
            } catch {
                showFlash("Falha ao limpar o cache")
            }
            await refresh()
        }
    }

    func openFullDiskAccess() {
        _ = FullDiskAccess.isGranted() // garante que o app já conste na lista quando ela abrir
        FullDiskAccess.openSettings()
    }

    func openCacheFolder() { open(Paths.cache) }
    func openLogsFolder() { open(Paths.logs) }

    private func open(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    func restartEngine() {
        guard canRestart else { return }
        Task { await supervisor.restart() }
    }

    func updateYtDlp() {
        guard !updatingYtDlp else { return }
        guard let engineDir = supervisor.engineDir else {
            showFlash("Falha ao atualizar o yt-dlp")
            return
        }
        updatingYtDlp = true
        Task {
            let updated = await YtDlpUpdater.run(engineDir: engineDir)
            // Só reinicia quando algo mudou de fato: reiniciar derruba a dublagem em andamento.
            if updated { await supervisor.restart() }
            updatingYtDlp = false
            showFlash(updated ? "yt-dlp atualizado" : "Falha ao atualizar o yt-dlp")
        }
    }

    func openVideo(_ job: Job) {
        guard let url = URL(string: "https://www.youtube.com/watch?v=\(job.videoId)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Toca a amostra da voz; um segundo clique na mesma voz para.
    func toggleSample(voice id: String) {
        let wasPlaying = samplePlaying == id
        stopSample()
        guard !wasPlaying else { return }
        sampleLoading = id
        Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await client.voiceSample(id: id)
                guard sampleLoading == id else { return } // o usuário já pediu outra voz
                sampleLoading = nil
                guard let sound = NSSound(data: data) else { throw EngineError.invalidResponse }
                let delegate = SoundDelegate { [weak self] in
                    if self?.samplePlaying == id { self?.stopSample() }
                }
                sound.delegate = delegate
                self.sound = sound
                soundDelegate = delegate
                samplePlaying = id
                sound.play()
            } catch {
                if sampleLoading == id { sampleLoading = nil }
                showFlash("Não foi possível tocar a amostra")
            }
        }
    }

    private func stopSample() {
        sound?.stop()
        sound = nil
        soundDelegate = nil
        sampleLoading = nil
        samplePlaying = nil
    }

    func quit() { NSApp.terminate(nil) }

    private func showFlash(_ text: String) {
        flash = text
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.flash = nil
        }
    }

    // MARK: - Iniciar no login

    func setLoginEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Erro: \(error.localizedDescription)"
        }
        refreshLoginStatus()
    }

    private func refreshLoginStatus() {
        let service = SMAppService.mainApp.status
        let enabled = service == .enabled || service == .requiresApproval
        let note = loginError ?? (service == .requiresApproval
            ? "Aprove em Ajustes do Sistema › Geral › Itens de Início" : nil)
        if loginEnabled != enabled { loginEnabled = enabled }
        if loginNote != note { loginNote = note }
    }
}

private final class SoundDelegate: NSObject, NSSoundDelegate {
    private let onFinish: @MainActor () -> Void

    init(onFinish: @escaping @MainActor () -> Void) { self.onFinish = onFinish }

    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        let finish = onFinish
        Task { @MainActor in finish() }
    }
}

// MARK: - Cenários de prévia (usados só pelo modo --snapshot, para revisar o painel sem o motor)

extension AppModel {
    enum PreviewScenario: String, CaseIterable { case dublando, ocioso, parado }

    static func preview(_ scenario: PreviewScenario) -> AppModel {
        let model = AppModel()
        let settings = EngineSettings(voice: "pf_dora", translator: "youtube", ollamaFallback: true, ollamaAssist: true,
                                      useCookies: true, cacheLimitGb: 10, cookiesFromBrowser: "chrome", voiceOffsetDb: 0, uiAccent: nil)
        let voices = ["pf_dora": "Dora (feminina)", "pm_alex": "Alex (masculina)", "pm_santa": "Santa (masculina)"]
        let recent = [
            Job(id: "a.pt.pf_dora", videoId: "a", stageLabel: nil, progress: 1, title: "The History of the Internet in 10 Minutes", status: "done",
                report: JobReport(tempoTotalS: 214.6, traducao: "faixa traduzida do YouTube")),
            Job(id: "b.pt.pf_dora", videoId: "b", stageLabel: nil, progress: 1,
                title: "Sourdough Bread for Absolute Beginners", status: "done",
                report: JobReport(tempoTotalS: 101.7, traducao: "Ollama (qwen3)")),
            Job(id: "c.pt.pf_dora", videoId: "c", stageLabel: nil, progress: 0, title: "Vídeo sem legenda", status: "error",
                error: "Este vídeo não tem legendas (nem automáticas)."),
        ]
        let running = Job(id: "d.pt.pf_dora", videoId: "d", stageLabel: "Gerando a voz em português", progress: 0.23,
                          title: "How Jet Engines Actually Work, Explained from Scratch", status: "running")
        switch scenario {
        case .dublando:
            model.phase = .running(owned: true)
            model.status = EngineStatus(version: "0.1.0", jobs: .init(current: running, queued: [running], recent: recent),
                                        cacheBytes: 2_340_000_000, settings: settings, voices: voices,
                                        cookies: .init(present: true, browser: "chrome", browserOk: true))
            model.settings = settings
            model.fullDiskAccess = true
        case .ocioso:
            model.phase = .running(owned: true)
            model.status = EngineStatus(version: "0.1.0", jobs: .init(current: nil, queued: [], recent: recent),
                                        cacheBytes: 27_000_000, settings: settings, voices: voices,
                                        cookies: .init(present: true, browser: "chrome", browserOk: false))
            model.settings = settings
            model.fullDiskAccess = false
            model.flash = "Cache limpo: 1,2 GB liberados"
        case .parado:
            model.phase = .stopped
        }
        return model
    }
}
