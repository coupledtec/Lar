import Foundation

/// A text the person reads, made in LarCore: Portuguese is the source, and the app's String Catalog (in the main
/// bundle of each app and extension) has the other languages. The literal is extracted into the catalog.
func tr(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: .main)
}
