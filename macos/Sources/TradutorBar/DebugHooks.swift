import AppKit

/// Ganchos só para verificação automatizada (ativados com `--debug-hooks`): abrir e fechar o painel e a janela
/// de Ajustes por notificação distribuída, sem mouse. Um processo local pode no máximo abrir a interface.
@MainActor
enum DebugHooks {
    static let name = Notification.Name("local.arnaldo.tradutordevideos.debug")
    private static var observer: NSObjectProtocol?

    static func install(panel: StatusPanelController, settings: SettingsWindowController) {
        observer = DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { note in
            let action = note.object as? String ?? ""
            MainActor.assumeIsolated {
                switch action {
                case "open": panel.open()
                case "close": panel.close()
                case "settings":
                    panel.close(returnFocus: false)
                    settings.show()
                default: break
                }
            }
        }
    }
}
