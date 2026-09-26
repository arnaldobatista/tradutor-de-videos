import AppKit
import Combine
import SwiftUI

/// Ícone na barra de menus e o painel que ele abre.
///
/// Feito em AppKit em vez do MenuBarExtra do SwiftUI: ao mudar de altura com o painel aberto (dublagem
/// começando, aviso aparecendo), a janela do MenuBarExtra se redimensionava pelo centro e cortava o topo e o
/// rodapé. Aqui o topo fica preso logo abaixo do ícone e só a borda de baixo se mexe.
@MainActor
final class StatusPanelController: NSObject {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = MenuPanel()
    private let hosting: NSHostingController<PanelView>
    private var sizeObservation: NSKeyValueObservation?
    private var monitors: [Any] = []
    private var cancellables: Set<AnyCancellable> = []
    private var lastIcon = ""
    private var lastTitle = ""
    /// App que estava em primeiro plano quando o painel abriu: recebe o foco de volta ao fechar com Esc ou pelo ícone.
    private var previousApp: NSRunningApplication?
    /// Canto superior esquerdo do painel aberto, logo abaixo do ícone.
    private var pinnedTopLeft: NSPoint?
    private var pinning = false

    private(set) var isOpen = false

    init(model: AppModel, openSettings: @escaping () -> Void) {
        self.model = model
        hosting = NSHostingController(rootView: PanelView(model: model))
        super.init()
        hosting.rootView = PanelView(model: model) { [weak self] in
            self?.close(returnFocus: false)
            openSettings()
        }
        hosting.sizingOptions = [.preferredContentSize]
        // A janela tem barra de título invisível (ver MenuPanel): sem isto o SwiftUI reserva 28 pt para ela.
        hosting.safeAreaRegions = []
        panel.contentView = Self.background(around: hosting.view)
        sizeObservation = hosting.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.fitToContent() }
        }

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(toggle(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.setAccessibilityLabel("Tradutor de Vídeos")
        }
        updateButton()
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateButton() } }
            .store(in: &cancellables)
        // O Auto Layout do AppKit também redimensiona a janela quando o conteúdo muda: qualquer que seja a origem,
        // o canto de cima fica preso sob o ícone.
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            NotificationCenter.default.publisher(for: name, object: panel)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.pinTopLeft() } }
                .store(in: &cancellables)
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.close(returnFocus: false) } }
            .store(in: &cancellables)
    }

    /// Vidro do macOS 26+ (o mesmo material dos menus e da Central de Controle); antes disso, o material de popover.
    private static func background(around content: NSView) -> NSView {
        content.autoresizingMask = [.width, .height]
        #if compiler(>=6.2) // NSGlassEffectView só existe no SDK do macOS 26 (Xcode 26+)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = MenuPanel.glassCornerRadius
            glass.contentView = content
            return glass
        }
        #endif
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        content.frame = effect.bounds
        effect.addSubview(content)
        return effect
    }

    // MARK: - Ícone

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let icon = model.iconName
        if icon != lastIcon {
            lastIcon = icon
            let image = NSImage(systemSymbolName: icon, accessibilityDescription: "Tradutor de Vídeos")
            image?.isTemplate = true
            button.image = image
        }
        let title = model.percentText.map { " \($0)" } ?? ""
        if title != lastTitle {
            lastTitle = title
            button.title = title
        }
    }

    // MARK: - Abrir e fechar

    @objc private func toggle(_ sender: Any?) {
        isOpen ? close() : open()
    }

    func open() {
        guard !isOpen, let anchor = anchorRect() else { return }
        isOpen = true
        let size = currentContentSize()
        let visible = (statusItem.button?.window?.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let x = min(max(anchor.minX, visible.minX + 8), visible.maxX - size.width - 8)
        let top = anchor.minY - 4
        let height = min(size.height, top - visible.minY - 8)
        pinnedTopLeft = NSPoint(x: x, y: top)
        panel.setFrame(NSRect(x: x, y: top - height, width: size.width, height: height), display: true)

        // Ativar o app faz os controles aparecerem no estado ativo, com a cor de destaque do sistema; inativos
        // ficam cinza. É o que o MenuBarExtra também fazia.
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        NSApp.activate()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        statusItem.button?.highlight(true)
        installMonitors()
    }

    /// `returnFocus`: devolve o foco ao app anterior. Não se aplica quando o usuário clicou em outro app (ele já
    /// escolheu onde quer o foco) nem quando o painel fecha para abrir os Ajustes.
    func close(returnFocus: Bool = true) {
        guard isOpen else { return }
        isOpen = false
        pinnedTopLeft = nil
        removeMonitors()
        statusItem.button?.highlight(false)
        let hasOtherWindow = NSApp.windows.contains { $0 !== panel && $0.isVisible && $0.canBecomeMain }
        if returnFocus, !hasOtherWindow, let previousApp, !previousApp.isTerminated {
            NSApp.yieldActivation(to: previousApp)
            previousApp.activate()
        }
        previousApp = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isOpen else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    private func anchorRect() -> NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func currentContentSize() -> NSSize {
        let preferred = hosting.preferredContentSize
        return preferred.width > 0 && preferred.height > 0 ? preferred : hosting.view.fittingSize
    }

    /// Conteúdo mudou de altura: mantém o topo onde está e mexe só na borda de baixo.
    private func fitToContent() {
        guard isOpen, let pin = pinnedTopLeft else { return }
        let size = currentContentSize()
        let frame = panel.frame
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let height = min(size.height, pin.y - visible.minY - 8)
        guard abs(frame.height - height) > 0.5 || abs(frame.width - size.width) > 0.5 else { return pinTopLeft() }
        pinning = true
        panel.setFrame(NSRect(x: pin.x, y: pin.y - height, width: size.width, height: height), display: true)
        pinning = false
        panel.invalidateShadow()
    }

    private func pinTopLeft() {
        guard isOpen, !pinning, let pin = pinnedTopLeft else { return }
        let frame = panel.frame
        guard abs(frame.minX - pin.x) > 0.5 || abs(frame.maxY - pin.y) > 0.5 else { return }
        pinning = true
        panel.setFrameOrigin(NSPoint(x: pin.x, y: pin.y - frame.height))
        pinning = false
        panel.invalidateShadow()
    }

    // MARK: - Fechar ao clicar fora ou com Esc

    private func installMonitors() {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close(returnFocus: false) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event } // Esc
            MainActor.assumeIsolated { self?.close() }
            return nil
        }) {
            monitors.append(local)
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }
}

/// Janela que se comporta como um menu: fica acima das outras, não ativa o app sozinha e aceita teclado para o
/// Esc e os atalhos funcionarem.
///
/// No macOS 26+ ela tem barra de título invisível: o sistema desenha o contorno da janela com o raio de canto
/// dela, e numa janela sem borda esse raio é quase zero, o que deixava uma quina escura em volta do vidro
/// arredondado. Com título, o contorno segue o raio padrão de janela, e o vidro usa o mesmo.
final class MenuPanel: NSPanel {
    /// Raio de canto de uma janela com título no macOS 26/27, medido nas capturas: o vidro precisa coincidir.
    static let glassCornerRadius: CGFloat = 26

    private static var usesGlass: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }

    init() {
        let style: NSWindow.StyleMask = Self.usesGlass
            ? [.titled, .fullSizeContentView, .nonactivatingPanel]
            : [.borderless, .nonactivatingPanel]
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400), styleMask: style, backing: .buffered, defer: true)
        if Self.usesGlass {
            titlebarAppearsTransparent = true
            titleVisibility = .hidden
            titlebarSeparatorStyle = .none
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                standardWindowButton(button)?.isHidden = true
            }
        }
        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        isMovableByWindowBackground = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // A barra de título é invisível, mas o duplo clique nela ainda maximizaria a janela.
    override func zoom(_ sender: Any?) {}
}
