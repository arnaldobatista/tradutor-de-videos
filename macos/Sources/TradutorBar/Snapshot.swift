import AppKit
import SwiftUI

/// Renderiza o painel fora da tela, nos cenários de prévia e nos dois temas. Usa uma janela de verdade
/// (e não ImageRenderer) porque controles nativos, como o segmentado e o switch, só se desenham assim.
@MainActor
enum Snapshot {
    static func run(into folder: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        for scenario in AppModel.PreviewScenario.allCases {
            for (suffix, appearance) in [("claro", NSAppearance.Name.aqua), ("escuro", .darkAqua)] {
                let expanded = scenario == .ocioso
                let view = PanelView(model: AppModel.preview(scenario), startExpanded: expanded)
                    .background(Color(nsColor: .windowBackgroundColor))
                let hosting = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 340, height: 10),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = hosting
                hosting.layoutSubtreeIfNeeded()
                let size = hosting.fittingSize
                window.setContentSize(size)
                hosting.frame = NSRect(origin: .zero, size: size)
                hosting.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.3)) // deixa o SwiftUI assentar

                guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let file = folder.appendingPathComponent("painel-\(scenario.rawValue)-\(suffix).png")
                try? bitmap.representation(using: .png, properties: [:])?.write(to: file)
                print(file.path, Int(size.width), "x", Int(size.height))
            }
        }
    }
}
