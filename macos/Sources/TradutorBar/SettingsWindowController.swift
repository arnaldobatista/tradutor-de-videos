import AppKit
import SwiftUI

/// Janela de Ajustes (⌘,). O app não tem Dock nem menu próprio, então ele se ativa ao abri-la para ela vir à frente.
@MainActor
final class SettingsWindowController: NSObject {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        let window = self.window ?? makeWindow()
        if self.window == nil {
            self.window = window
            if !window.setFrameUsingName(Self.autosaveName) { window.center() }
            window.setFrameAutosaveName(Self.autosaveName)
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Sem controle focado ao abrir: o anel de foco só aparece quando o usuário navega pelo teclado.
        window.makeFirstResponder(nil)
    }

    private static let autosaveName = "TradutorDeVideos.Ajustes"

    private func makeWindow() -> NSWindow {
        let controller = NSHostingController(rootView: SettingsView(model: model))
        controller.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: controller)
        window.title = "Ajustes do Tradutor de Vídeos"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 540, height: 720))
        window.isReleasedWhenClosed = false
        return window
    }
}
