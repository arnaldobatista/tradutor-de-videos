import AppKit

/// Acesso Total ao Disco não tem API de pedido: a Apple obriga o usuário a ligar a chave em Ajustes do
/// Sistema. O que um app consegue fazer, e este faz: detectar se tem, aparecer na lista (a própria
/// tentativa de leitura registra o app lá, com a chave desligada), abrir a lista certa e notar a concessão.
enum FullDiskAccess {
    /// Arquivos que existem em todo Mac e só são legíveis com Acesso Total ao Disco.
    private static let probes = [
        "Library/Application Support/com.apple.TCC/TCC.db",
        "Library/Safari/Bookmarks.plist",
    ]

    static func isGranted() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for probe in probes {
            let fd = open(home.appendingPathComponent(probe).path, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return true
            }
            if errno == EPERM || errno == EACCES { return false }
        }
        return false
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }
}
