import SwiftUI

/// Where home is, for the scenes that run on arriving and leaving.
struct HomeLocationSection: View {
    @State private var isSet = PresenceMonitor.shared.homeIsSet
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        Section {
            Button {
                Task {
                    busy = true
                    message = await PresenceMonitor.shared.setHomeHere()
                    isSet = PresenceMonitor.shared.homeIsSet
                    busy = false
                }
            } label: {
                HStack {
                    Text(isSet ? "Marcar de novo (estou em casa)" : "Estou em casa: marcar aqui")
                    if busy { Spacer(); ProgressView() }
                }
            }
            if isSet {
                Button("Esquecer a casa", role: .destructive) {
                    PresenceMonitor.shared.forgetHome()
                    isSet = false
                }
            }
        } header: {
            Text("Casa")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let message { Text(message).foregroundStyle(.orange) }
                Text("Usada só pelas cenas “Ao chegar em casa” e “Ao sair de casa” (uns 150 m em volta). A localização fica neste iPhone.")
            }
        }
    }
}
