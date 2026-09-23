import SwiftUI

/// Painel que abre no ícone da barra de menus. Ordem pensada pelo uso: o que está acontecendo agora,
/// depois o que se troca com frequência (voz, tradução), depois ajustes raros recolhidos, e manutenção no rodapé.
struct PanelView: View {
    @ObservedObject var model: AppModel
    @State private var showAdvanced: Bool
    @State private var confirmingClear = false

    /// Azul do ícone da extensão. Fixo, para app e extensão terem a mesma cara seja qual for o acento do sistema.
    static let brand = Color(red: 0.13, green: 0.47, blue: 0.87)

    init(model: AppModel, startExpanded: Bool = false) {
        self.model = model
        _showAdvanced = State(initialValue: startExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let problem = model.problem {
                ProblemBanner(message: problem, canRestart: model.canRestart) { model.restartEngine() }
            }
            activity
            if model.needsFullDiskAccess {
                PermissionNote(
                    message: "Para ler os cookies do \(model.browserName), o macOS exige Acesso Total ao Disco, e a Apple não deixa nenhum app pedir isso por diálogo: é preciso ligar a chave em Ajustes do Sistema. Na lista, ligue a do Tradutor de Vídeos; se ele não constar, o + adiciona (está em Aplicativos). O motor reinicia sozinho em seguida.",
                    primary: "Abrir Acesso Total ao Disco",
                    secondary: "Ou usar os cookies pela extensão, que não precisa de permissão",
                    onPrimary: { model.openFullDiskAccess() },
                    onSecondary: { model.setCookiesSource("") })
            }
            if model.settings != nil {
                Divider()
                voicePicker
                translatorPicker
                advanced
                Divider()
                cache
            } else {
                Divider()
            }
            footer
        }
        .padding(16)
        .frame(width: 340)
        .tint(Self.brand)
    }

    // MARK: - Cabeçalho

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Self.brand))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Tradutor de Vídeos").font(.headline)
                HStack(spacing: 5) {
                    Circle().fill(toneColor).frame(width: 7, height: 7)
                    Text(verbatim: model.headline).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer()
            if let version = model.versionText {
                Text(verbatim: version).font(.caption).monospacedDigit().foregroundStyle(.tertiary)
            }
        }
    }

    private var toneColor: Color {
        switch model.tone {
        case .good: return .green
        case .busy: return .orange
        case .bad: return .red
        }
    }

    // MARK: - O que está acontecendo

    @ViewBuilder
    private var activity: some View {
        if let title = model.jobTitle {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Meter(fraction: model.jobFraction, height: 6)
                        .accessibilityLabel("Progresso da dublagem")
                        .accessibilityValue("\(Int((model.jobFraction * 100).rounded())) por cento")
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: model.jobStage).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(verbatim: "\(Int((model.jobFraction * 100).rounded()))%")
                            .font(.caption.weight(.medium)).monospacedDigit()
                    }
                    HStack {
                        if model.queuedCount > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "list.bullet").accessibilityHidden(true)
                                Text(verbatim: "\(model.queuedCount) na fila")
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Cancelar", role: .cancel) { model.cancelCurrentJob() }
                            .controlSize(.small)
                    }
                }
            }
        } else if model.problem == nil {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text("Abra um vídeo no YouTube e clique no balão que aparece nos controles do player.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if !model.recentJobs.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel("Recentes")
                VStack(spacing: 0) {
                    ForEach(model.recentJobs) { job in
                        RecentRow(job: job) { model.openVideo(job) }
                    }
                }
            }
        }
    }

    // MARK: - Ajustes frequentes

    private var voicePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Voz")
            if let settings = model.settings, !model.voiceOptions.isEmpty {
                HStack(spacing: 8) {
                    Picker("Voz", selection: Binding(get: { settings.voice }, set: { model.setVoice($0) })) {
                        ForEach(model.voiceOptions) { voice in
                            Text(verbatim: voice.shortName).tag(voice.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    SampleButton(model: model, voice: settings.voice)
                }
                .disabled(!model.controlsEnabled)
                if let current = model.voiceOptions.first(where: { $0.id == settings.voice }) {
                    Caption(current.name + ". Vale para as próximas dublagens.")
                }
            } else {
                Caption("Disponível quando o motor estiver ativo.")
            }
        }
    }

    private var translatorPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Tradução")
            if let settings = model.settings {
                Picker("Tradução", selection: Binding(get: { settings.translator }, set: { model.setTranslator($0) })) {
                    Text("Legenda do YouTube").tag("youtube")
                    Text("LLM local").tag("ollama")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!model.controlsEnabled)
                Caption(settings.translator == "ollama"
                    ? "O Ollama traduz respeitando o tempo de cada fala. Mais lento, costuma ficar melhor."
                    : "Usa a legenda traduzida pelo YouTube. É o caminho mais rápido.")
            } else {
                Caption("Disponível quando o motor estiver ativo.")
            }
        }
    }

    // MARK: - Ajustes raros

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { showAdvanced.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                    Text("Mais ajustes").font(.callout)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityHint(showAdvanced ? "Recolhe os ajustes" : "Mostra os ajustes")

            if showAdvanced {
                VStack(alignment: .leading, spacing: 12) {
                    SettingToggle(
                        title: "Tradução reserva",
                        caption: "Usa o Ollama quando o YouTube não entrega a legenda em português.",
                        isOn: Binding(get: { model.settings?.ollamaFallback ?? false }, set: { model.setOllamaFallback($0) }))
                    SettingToggle(
                        title: "Frases completas e enxutas",
                        caption: "O Ollama pontua a transcrição e encurta as falas que não cabem no tempo.",
                        isOn: Binding(get: { model.settings?.ollamaAssist ?? false }, set: { model.setOllamaAssist($0) }))
                    SettingToggle(
                        title: "Cookies do YouTube",
                        caption: model.cookiesCaption,
                        isOn: Binding(get: { model.settings?.useCookies ?? false }, set: { model.setUseCookies($0) }))
                    if model.settings?.useCookies == true {
                        Picker("Origem dos cookies", selection: Binding(
                            get: { model.wantsBrowserCookies ? "chrome" : "" },
                            set: { model.setCookiesSource($0) }
                        )) {
                            Text("Pela extensão").tag("")
                            Text("Do Chrome, pelo yt-dlp").tag("chrome")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Volume da voz dublada").font(.callout)
                        Picker("Volume da voz dublada", selection: Binding(
                            get: { model.voiceOffset }, set: { model.setVoiceOffset($0) }
                        )) {
                            Text("Mais baixa").tag(-3.0)
                            Text("Como no original").tag(0.0)
                            Text("Mais alta").tag(3.0)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Caption("Em relação à voz original, fala a fala. O som de fundo não muda.")
                    }
                }
                .disabled(!model.controlsEnabled)
                SettingToggle(
                    title: "Iniciar no login",
                    caption: model.loginNote ?? "Abre o app, e com ele o motor, quando você entra no Mac.",
                    isOn: Binding(get: { model.loginEnabled }, set: { model.setLoginEnabled($0) }))
            }
        }
    }

    // MARK: - Cache e rodapé

    private var cache: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Cache")
                Spacer()
                Text(verbatim: model.cacheDetail).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Meter(fraction: model.cacheFraction, height: 4, tint: .secondary)
                    .accessibilityLabel("Uso do cache")
                    .accessibilityValue(model.cacheDetail)
                Button(confirmingClear ? "Confirmar" : "Limpar") {
                    if confirmingClear {
                        confirmingClear = false
                        model.clearCache()
                    } else {
                        confirmingClear = true
                        // Apagar é irreversível (os vídeos teriam que ser dublados de novo): pede um segundo clique.
                        Task {
                            try? await Task.sleep(for: .seconds(4))
                            confirmingClear = false
                        }
                    }
                }
                .controlSize(.small)
                .tint(confirmingClear ? .red : nil)
                .disabled(!model.controlsEnabled || model.cacheIsEmpty)
                .help("Apaga as dublagens guardadas. Os vídeos teriam que ser dublados de novo.")
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let notice = model.notice {
                Label {
                    Text(verbatim: notice).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .transition(.opacity)
            }
            HStack {
                Menu {
                    Button("Abrir pasta do cache") { model.openCacheFolder() }
                    Button("Abrir logs") { model.openLogsFolder() }
                    Divider()
                    Button("Reiniciar motor") { model.restartEngine() }.disabled(!model.canRestart)
                    Button("Atualizar yt-dlp") { model.updateYtDlp() }.disabled(model.updatingYtDlp)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "ellipsis.circle")
                        Text("Manutenção")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Pasta do cache, logs, reiniciar o motor, atualizar o yt-dlp")
                Spacer()
                Button { model.quit() } label: {
                    Text("Sair").font(.callout).foregroundStyle(.secondary)
                }
                .keyboardShortcut("q")
                .buttonStyle(.plain)
                .help("Encerra o app e o motor (⌘Q)")
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.notice)
    }
}

// MARK: - Peças

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(verbatim: text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(verbatim: text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Barra de medida fina. Desenhada à mão para o progresso e o cache terem o mesmo traço.
private struct Meter: View {
    let fraction: Double
    let height: CGFloat
    var tint: Color = PanelView.brand

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(tint)
                    .frame(width: fraction > 0 ? max(height, geometry.size.width * fraction) : 0)
                    .animation(.easeOut(duration: 0.4), value: fraction)
            }
        }
        .frame(height: height)
        .accessibilityElement()
    }
}

private struct ProblemBanner: View {
    let message: String
    let canRestart: Bool
    let restart: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: message).font(.callout).fixedSize(horizontal: false, vertical: true)
                Button("Reiniciar motor", action: restart).controlSize(.small).disabled(!canRestart)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
    }
}

/// Aviso com ação: para o que não para o app, mas que só o usuário resolve (permissão do sistema).
private struct PermissionNote: View {
    let message: String
    let primary: String
    let secondary: String
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield").foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(primary, action: onPrimary).controlSize(.small)
                Button(action: onSecondary) {
                    Text(verbatim: secondary).font(.caption).underline()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.1)))
    }
}

private struct SampleButton: View {
    @ObservedObject var model: AppModel
    let voice: String

    var body: some View {
        Button { model.toggleSample(voice: voice) } label: {
            Group {
                if model.sampleLoading == voice {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: model.samplePlaying == voice ? "stop.fill" : "speaker.wave.2.fill")
                }
            }
            .frame(width: 18, height: 16)
        }
        .help(model.samplePlaying == voice ? "Parar a amostra" : "Ouvir uma amostra desta voz")
        .accessibilityLabel(model.samplePlaying == voice ? "Parar a amostra" : "Ouvir uma amostra desta voz")
    }
}

private struct SettingToggle: View {
    let title: String
    let caption: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.callout)
                Caption(caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

private struct RecentRow: View {
    let job: Job
    let open: () -> Void
    @State private var hovering = false

    private var failed: Bool { job.status == "error" }

    private var detail: String {
        if failed { return job.error ?? "A dublagem falhou." }
        var parts: [String] = []
        if let seconds = job.report?.tempoTotalS { parts.append("Dublado em \(Self.duration(seconds))") }
        if let source = job.report?.traducao {
            parts.append(source.lowercased().hasPrefix("ollama") ? "LLM local" : "legenda do YouTube")
        }
        return parts.isEmpty ? "Dublado" : parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(failed ? Color.red : Color.green)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: job.title ?? "Vídeo \(job.videoId)").font(.callout).lineLimit(1)
                    Text(verbatim: detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Abrir o vídeo no YouTube")
        .padding(.horizontal, -6)
    }

    private static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total < 60 ? "\(total) s" : "\(total / 60) min \(total % 60) s"
    }
}

extension VoiceOption {
    /// "Dora (feminina)" → "Dora": o controle segmentado não comporta o nome inteiro.
    var shortName: String { name.components(separatedBy: " (").first ?? name }
}
