import AppKit
import SwiftUI

/// Renderiza o painel e os Ajustes em PNG, nos cenários de prévia e nos dois temas, para revisar o visual e
/// gerar as imagens do README. Usa uma janela de verdade (e não ImageRenderer) porque controles nativos, como o
/// segmentado e o switch, só se desenham assim; a janela vira chave fora da tela para os controles saírem no
/// estado ativo, com a cor de destaque. `-AppleAccentColor 4` (azul), `1` (laranja) etc. trocam a cor só aqui.
@MainActor
enum Snapshot {
    static func run(into folder: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let previous = NSWorkspace.shared.frontmostApplication
        app.activate()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        for scenario in AppModel.PreviewScenario.allCases {
            for (suffix, appearance) in [("claro", NSAppearance.Name.aqua), ("escuro", .darkAqua)] {
                let model = AppModel.preview(scenario)
                render(PanelView(model: model).background(Color(nsColor: .windowBackgroundColor)),
                       appearance: appearance, to: folder.appendingPathComponent("painel-\(scenario.rawValue)-\(suffix).png"))
                if scenario == .dublando {
                    render(SettingsView(model: model).frame(width: 540, height: 1240),
                           appearance: appearance, to: folder.appendingPathComponent("ajustes-\(suffix).png"))
                }
            }
        }
        if let previous, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier { previous.activate() }
    }

    private static func render<V: View>(_ view: V, appearance: NSAppearance.Name, to file: URL) {
        let hosting = NSHostingView(rootView: view)
        let window = KeyWindow(contentRect: .init(x: -20_000, y: -20_000, width: 340, height: 10),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        window.setContentSize(size)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5)) // deixa o SwiftUI assentar

        defer { window.orderOut(nil) }
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: file)
        print(file.path, Int(size.width), "x", Int(size.height), NSApp.isActive ? "app ativo" : "app inativo")
    }
}

/// Um processo aberto pelo terminal não recebe ativação do macOS; a janela se declara chave para os
/// controles se desenharem no estado ativo mesmo assim.
private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { true }
}
