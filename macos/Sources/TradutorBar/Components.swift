import SwiftUI

// Peças visuais compartilhadas pelo painel da barra de menus e pela janela de Ajustes.
// Cores de destaque vêm sempre do sistema (Color.accentColor), para seguir o tema do macOS.

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(verbatim: text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }
}

struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(verbatim: text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Barra de medida fina. Desenhada à mão para o progresso e o cache terem o mesmo traço.
struct Meter: View {
    let fraction: Double
    let height: CGFloat
    var tint: Color = .accentColor

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

struct ProblemBanner: View {
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
struct PermissionNote: View {
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

struct SampleButton: View {
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

struct RecentRow: View {
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
