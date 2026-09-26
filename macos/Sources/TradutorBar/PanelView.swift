import SwiftUI

/// Conteúdo do painel da barra de menus: o que está acontecendo agora e o que se troca com frequência.
/// Os ajustes raros ficam na janela de Ajustes, para o painel não mudar de altura à toa com ele aberto.
struct PanelView: View {
    @ObservedObject var model: AppModel
    var openSettings: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let problem = model.problem {
                ProblemBanner(message: problem, canRestart: model.canRestart) { model.restartEngine() }
            }
            activity
            if model.needsFullDiskAccess {
                PermissionNote(
                    message: "Ler os cookies do \(model.browserName) exige Acesso Total ao Disco. Ligue a chave do Tradutor de Vídeos na lista; o motor reinicia sozinho.",
                    primary: "Abrir Acesso Total ao Disco",
                    secondary: "Usar os cookies da extensão (sem permissão)",
                    onPrimary: { model.openFullDiskAccess() },
                    onSecondary: { model.setCookiesSource("") })
            }
            if model.settings != nil {
                Divider()
                voicePicker
                translatorPicker
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 340)
        // Cor de destaque do sistema passada de forma explícita: com `.accentColor` o SwiftUI deixa o segmentado
        // no azul de fábrica, e sem tint nenhum o macOS 26+ o desenha cinza.
        .tint(Color(nsColor: .controlAccentColor))
        // O painel vira janela-chave para o Esc funcionar; sem isto o primeiro controle ganha o anel de foco.
        .focusEffectDisabled()
    }

    // MARK: - Cabeçalho

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor))
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
            }
        }
    }

    // MARK: - Rodapé

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
            }
            HStack {
                Button(action: openSettings) {
                    HStack(spacing: 5) {
                        Image(systemName: "gearshape")
                        Text("Ajustes…")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(",")
                .help("Volume, cookies, Ollama, cache e manutenção (⌘,)")
                Spacer()
                Button { model.quit() } label: {
                    Text("Sair").font(.callout).foregroundStyle(.secondary).contentShape(Rectangle())
                }
                .keyboardShortcut("q")
                .buttonStyle(.plain)
                .help("Encerra o app e o motor (⌘Q)")
            }
        }
    }
}
