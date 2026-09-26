import SwiftUI

/// Janela de Ajustes: tudo que se configura uma vez e esquece. Formulário agrupado, como os Ajustes do Sistema,
/// com a cor de destaque e o tema claro/escuro do macOS.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var confirmingClear = false

    var body: some View {
        Form {
            if let problem = model.problem {
                Section {
                    ProblemBanner(message: problem, canRestart: model.canRestart) { model.restartEngine() }
                        .listRowInsets(EdgeInsets())
                }
            }
            if let settings = model.settings {
                dubbing(settings)
                ollama(settings)
                cookies(settings)
                storage(settings)
            } else if model.problem == nil {
                Section {
                    Label("Os ajustes aparecem quando o motor estiver ativo.", systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                }
            }
            general
        }
        .formStyle(.grouped)
        .tint(Color(nsColor: .controlAccentColor))
        .frame(minWidth: 500, idealWidth: 540, minHeight: 420, idealHeight: 720)
        .confirmationDialog("Limpar o cache?", isPresented: $confirmingClear) {
            Button("Limpar cache", role: .destructive) { model.clearCache() }
        } message: {
            Text(verbatim: "Apaga as dublagens guardadas (\(model.cacheDetail)). Os vídeos teriam que ser dublados de novo.")
        }
    }

    // MARK: - Seções

    private func dubbing(_ settings: EngineSettings) -> some View {
        Section {
            LabeledContent("Voz") {
                HStack(spacing: 8) {
                    Picker("Voz", selection: Binding(get: { settings.voice }, set: { model.setVoice($0) })) {
                        ForEach(model.voiceOptions) { voice in
                            Text(verbatim: voice.name).tag(voice.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    SampleButton(model: model, voice: settings.voice)
                }
            }
            Picker("Tradução", selection: Binding(get: { settings.translator }, set: { model.setTranslator($0) })) {
                Text("Legenda do YouTube").tag("youtube")
                Text("LLM local (Ollama)").tag("ollama")
            }
            Picker("Volume da voz dublada", selection: Binding(get: { model.voiceOffset }, set: { model.setVoiceOffset($0) })) {
                Text("Mais baixa (−3 dB)").tag(-3.0)
                Text("Como no original").tag(0.0)
                Text("Mais alta (+3 dB)").tag(3.0)
            }
        } header: {
            Text("Dublagem")
        } footer: {
            FooterText("A voz dublada acompanha o volume da original, fala a fala; o som de fundo fica como no vídeo. Mudanças valem para as próximas dublagens.")
        }
        .disabled(!model.controlsEnabled)
    }

    private func ollama(_ settings: EngineSettings) -> some View {
        Section {
            Toggle(isOn: Binding(get: { settings.ollamaFallback }, set: { model.setOllamaFallback($0) })) {
                Text("Tradução reserva")
                Text("Usa o Ollama quando o YouTube não entrega a legenda em português.")
            }
            Toggle(isOn: Binding(get: { settings.ollamaAssist }, set: { model.setOllamaAssist($0) })) {
                Text("Frases completas e enxutas")
                Text("Pontua a transcrição automática e encurta as falas que não cabem no tempo.")
            }
        } header: {
            Text("LLM local (Ollama)")
        }
        .disabled(!model.controlsEnabled)
    }

    private func cookies(_ settings: EngineSettings) -> some View {
        Section {
            Toggle(isOn: Binding(get: { settings.useCookies }, set: { model.setUseCookies($0) })) {
                Text("Usar cookies do YouTube")
                Text("Sem eles o YouTube costuma negar a legenda traduzida.")
            }
            if settings.useCookies {
                Picker("Origem", selection: Binding(get: { model.wantsBrowserCookies ? "chrome" : "" },
                                                    set: { model.setCookiesSource($0) })) {
                    Text("Enviados pela extensão").tag("")
                    Text("Lidos do Chrome pelo yt-dlp").tag("chrome")
                }
                LabeledContent("Situação") {
                    Text(verbatim: model.cookiesCaption).multilineTextAlignment(.trailing)
                }
                if model.needsFullDiskAccess {
                    HStack {
                        Spacer()
                        Button("Abrir Acesso Total ao Disco") { model.openFullDiskAccess() }
                    }
                }
            }
        } header: {
            Text("Cookies")
        } footer: {
            if model.wantsBrowserCookies {
                FooterText("Ler os cookies do Chrome exige Acesso Total ao Disco. O app percebe quando a permissão é dada e reinicia o motor sozinho.")
            }
        }
        .disabled(!model.controlsEnabled)
    }

    private func storage(_ settings: EngineSettings) -> some View {
        Section {
            LabeledContent("Em uso") {
                VStack(alignment: .trailing, spacing: 6) {
                    Text(verbatim: model.cacheDetail).monospacedDigit()
                    Meter(fraction: model.cacheFraction, height: 4).frame(width: 160)
                }
            }
            Picker("Limite", selection: Binding(get: { settings.cacheLimitGb ?? 10 }, set: { model.setCacheLimit($0) })) {
                ForEach([5.0, 10.0, 20.0, 50.0], id: \.self) { gb in
                    Text(verbatim: "\(Int(gb)) GB").tag(gb)
                }
            }
            HStack {
                Button("Abrir pasta") { model.openCacheFolder() }
                Spacer()
                Button("Limpar cache…", role: .destructive) { confirmingClear = true }
                    .disabled(model.cacheIsEmpty)
            }
        } header: {
            Text("Cache")
        } footer: {
            FooterText("Vídeos já dublados abrem na hora. Acima do limite, os menos usados saem primeiro.")
        }
        .disabled(!model.controlsEnabled)
    }

    private var general: some View {
        Section {
            Toggle(isOn: Binding(get: { model.loginEnabled }, set: { model.setLoginEnabled($0) })) {
                Text("Iniciar no login")
                if let note = model.loginNote { Text(verbatim: note) }
            }
            LabeledContent("Motor") {
                HStack(spacing: 6) {
                    Circle().fill(model.tone == .good ? Color.green : model.tone == .busy ? .orange : .red)
                        .frame(width: 7, height: 7)
                    Text(verbatim: [model.headline, model.versionText].compactMap { $0 }.joined(separator: " · "))
                }
            }
            HStack {
                Button("Reiniciar motor") { model.restartEngine() }.disabled(!model.canRestart)
                Button("Atualizar yt-dlp") { model.updateYtDlp() }.disabled(model.updatingYtDlp)
                Spacer()
                Button("Abrir logs") { model.openLogsFolder() }
            }
            if let notice = model.notice {
                Label { Text(verbatim: notice) } icon: { Image(systemName: "info.circle") }
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Geral")
        } footer: {
            FooterText("Se o YouTube começar a recusar vídeos, atualize o yt-dlp.")
        }
    }
}

/// Rodapé de seção alinhado à esquerda (o padrão do Form agrupado alinha à direita quando quebra linha).
private struct FooterText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(verbatim: text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
