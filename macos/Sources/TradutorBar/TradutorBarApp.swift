import AppKit

@main
enum Main {
    static func main() {
        // `--snapshot <pasta>` renderiza o painel e os Ajustes em PNG com dados de prévia e sai: serve para revisar o visual.
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { Snapshot.run(into: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
            return
        }
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    private var statusPanel: StatusPanelController?
    private var settingsWindow: SettingsWindowController?
    private var signalSources: [DispatchSourceSignal] = []
    private var activity: NSObjectProtocol?

    override init() {
        model = Self.previewScenario().map(AppModel.preview) ?? AppModel()
        super.init()
    }

    /// `--debug-hooks --preview <cenário>`: instância de demonstração com dados de exemplo, sem motor. Serve para
    /// capturar as telas do README com o vidro e as cores reais, sem expor o histórico de quem está usando.
    private static func previewScenario() -> AppModel.PreviewScenario? {
        let args = CommandLine.arguments
        guard args.contains("--debug-hooks"), let index = args.firstIndex(of: "--preview"), index + 1 < args.count else { return nil }
        return AppModel.PreviewScenario(rawValue: args[index + 1])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement só vale dentro do .app; isto cobre também o binário rodado direto.
        NSApp.setActivationPolicy(.accessory)
        // Sem janela visível o App Nap atrasa timers, e com isso o religamento do motor e o polling.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Supervisão do motor de dublagem")
        installSignalHandlers()

        let settings = SettingsWindowController(model: model)
        settingsWindow = settings
        statusPanel = StatusPanelController(model: model) { settings.show() }
        NSApp.mainMenu = Self.mainMenu()
        if Self.previewScenario() == nil { model.start() }

        if CommandLine.arguments.contains("--debug-hooks"), let panel = statusPanel {
            DebugHooks.install(panel: panel, settings: settings)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    @objc func showSettings(_ sender: Any?) {
        statusPanel?.close()
        settingsWindow?.show()
    }

    /// O app não mostra barra de menus, mas os atalhos da janela de Ajustes (⌘W, ⌘Q, ⌘,) vêm daqui.
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Ajustes…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Sair do Tradutor de Vídeos", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let windowMenu = NSMenu(title: "Janela")
        windowMenu.addItem(withTitle: "Fechar", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        for menu in [appMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = menu
            main.addItem(item)
        }
        return main
    }

    /// Por padrão um SIGTERM mata o app sem passar por `applicationWillTerminate`, e o motor ficaria órfão.
    private func installSignalHandlers() {
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.model.shutdown()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
