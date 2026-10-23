import LarCore
import SwiftUI

/// Pairing with the Mac (the code its Settings → iPhone shows) and the sync's state.
struct MacSyncSection: View {
    var model: LarModel

    @State private var code = ""
    @State private var busy = false
    @State private var message: String?
    @State private var paired = SyncClient.isPaired

    var body: some View {
        Section {
            if paired {
                Button {
                    Task {
                        busy = true
                        await model.syncWithMac()
                        busy = false
                    }
                } label: {
                    HStack {
                        Text("Sincronizar agora")
                        if busy { Spacer(); ProgressView() }
                    }
                }
                if let last = model.lastSync {
                    LabeledContent("Última vez", value: last.formatted(date: .omitted, time: .shortened))
                }
                Button("Esquecer o Mac", role: .destructive) {
                    SyncClient.forget()
                    paired = false
                }
            } else {
                TextField("Código mostrado no Mac", text: $code)
                    .keyboardType(.numberPad)
                    .onChange(of: code) { _, new in code = String(new.filter(\.isNumber).prefix(6)) }
                Button {
                    Task {
                        busy = true
                        do {
                            try await SyncClient.pair(code: code)
                            paired = true
                            message = nil
                            await model.syncWithMac()
                        } catch {
                            message = (error as? SyncError)?.message ?? error.localizedDescription
                        }
                        busy = false
                    }
                } label: {
                    HStack {
                        Text("Parear com o Mac")
                        if busy { Spacer(); ProgressView() }
                    }
                }
                .disabled(code.count != 6 || busy)
            }
        } header: {
            Text("Mac")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let problem = message ?? model.syncProblem { Text(problem).foregroundStyle(.orange) }
                Text(paired
                     ? "Cenas, nomes, favoritos e cômodos ficam iguais no Mac e no iPhone pela rede de casa. As chaves das contas não passam."
                     : "No Mac: Ajustes → iPhone → Parear um iPhone. Digite aqui o código que aparecer.")
            }
        }
    }
}
