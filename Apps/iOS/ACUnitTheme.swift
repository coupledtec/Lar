import LarCore
import SwiftUI

/// The colors the Mac's air conditioner illustration (ACUnitView and AirflowView, compiled into this app from
/// Sources/Lar/UI/Components) reads from the Mac's Theme.
enum Theme {
    static let accent = Color.accentColor

    static func modeColor(_ mode: String?) -> Color { Palette.mode(mode) }
}
