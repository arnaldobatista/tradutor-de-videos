import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: model.iconName)
            if let percent = model.percentText {
                Text(verbatim: percent).monospacedDigit()
            }
        }
        .accessibilityLabel("Tradutor de Vídeos")
    }
}
