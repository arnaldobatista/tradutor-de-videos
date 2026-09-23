import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        // `--snapshot <pasta>` renderiza o painel em PNG com dados de prévia e sai: serve para revisar o visual.
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { Snapshot.run(into: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
            return
        }
        TradutorBarApp.main()
    }
}

struct TradutorBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: appDelegate.model)
        } label: {
            MenuBarLabel(model: appDelegate.model)
        }
        // Janela em vez de menu: só assim cabem barra de progresso, controles segmentados e textos de apoio.
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    private var signalSources: [DispatchSourceSignal] = []
    private var activity: NSObjectProtocol?

    override init() {
        model = AppModel()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement só vale dentro do .app; isto cobre também o binário rodado direto.
        NSApp.setActivationPolicy(.accessory)
        // Sem janela visível o App Nap atrasa timers, e com isso o religamento do motor e o polling.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Supervisão do motor de dublagem")
        installSignalHandlers()
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
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
