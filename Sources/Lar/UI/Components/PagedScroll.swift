import AppKit
import SwiftUI

/// Content that grows with what it holds up to what fits on the screen, then scrolls: with the scroll bar, the
/// trackpad or the mouse wheel, and ▲ ▼ buttons that move a page up or down when there's more that way. The menu bar
/// popover sizes itself to its content, so without a cap a long list made it taller than the screen.
extension EnvironmentValues {
    /// Set by the snapshots (DevTools): PagedScroll lays its content out without a scroll view.
    @Entry var rendersWithoutScrolling = false
}

struct PagedScroll<Content: View>: View {
    /// The most it takes; never more than the screen leaves (below the menu bar, with room for the header).
    var maxHeight: CGFloat
    @ViewBuilder var content: Content

    @State private var contentHeight: CGFloat = 0
    @State private var position = ScrollPosition(edge: .top)
    @State private var offset: CGFloat = 0
    @State private var visible: CGFloat = 0

    /// Height left on the screen under the menu bar, minus the popover's header and margins.
    static var screenRoom: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(240, screen - 190)
    }

    private var height: CGFloat { min(contentHeight, min(maxHeight, Self.screenRoom)) }
    private var scrolls: Bool { contentHeight > height + 1 }
    private var atTop: Bool { offset <= 2 }
    private var atBottom: Bool { offset + visible >= contentHeight - 2 }

    @Environment(\.rendersWithoutScrolling) private var rendersWithoutScrolling

    var body: some View {
        if rendersWithoutScrolling {
            // Offscreen snapshots don't draw a scroll view's content: the top of it, plainly.
            content.frame(maxHeight: maxHeight, alignment: .top).clipped()
        } else {
            scrolling
        }
    }

    private var scrolling: some View {
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollPosition($position)
        .scrollIndicators(scrolls ? .visible : .never)
        .onScrollGeometryChange(for: [CGFloat].self) { [$0.contentOffset.y, $0.containerSize.height] } action: { _, values in
            offset = values[0]
            visible = values[1]
        }
        .frame(height: max(height, 1))
        .overlay(alignment: .top) {
            if scrolls, !atTop { pageButton("chevron.up", "Página acima") { page(-1) } }
        }
        .overlay(alignment: .bottom) {
            if scrolls, !atBottom { pageButton("chevron.down", "Página abaixo") { page(1) } }
        }
        .animation(.easeOut(duration: 0.15), value: atTop)
        .animation(.easeOut(duration: 0.15), value: atBottom)
    }

    /// A page is most of what shows, so a line of the last one stays in view.
    private func page(_ direction: CGFloat) {
        let step = max(80, visible * 0.85)
        let target = min(max(0, offset + direction * step), max(0, contentHeight - visible))
        withAnimation(.easeOut(duration: 0.25)) { position.scrollTo(y: target) }
    }

    private func pageButton(_ symbol: String, _ label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 18)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .overlay(Capsule().stroke(Color.white.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .accessibilityLabel(label)
        .help(label)
        .transition(.opacity)
    }
}
