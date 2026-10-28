import LarCore
import SwiftUI

/// ◀ "2 de 5" ▶ under a paged list; nothing when it all fits on one page.
struct PageControl<Item>: View {
    let paged: Paged<Item>
    @Binding var page: Int

    var body: some View {
        if paged.pages > 1 {
            HStack(spacing: 14) {
                Button { page = paged.page - 1 } label: { Image(systemName: "chevron.left") }
                    .disabled(!paged.hasPrevious)
                    .accessibilityLabel("Página anterior")
                Text(paged.label)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button { page = paged.page + 1 } label: { Image(systemName: "chevron.right") }
                    .disabled(!paged.hasNext)
                    .accessibilityLabel("Próxima página")
            }
            #if os(watchOS)
            .buttonStyle(.plain)
            #else
            .buttonStyle(.borderless)
            #endif
            .frame(maxWidth: .infinity)
        }
    }
}
