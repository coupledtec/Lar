// Renders the 1024×1024 app icon: a dark squircle with a house whose window glows warm, like a lit lamp.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit
import SwiftUI

struct Icon: View {
    private let amber = Color(red: 1.0, green: 0.78, blue: 0.30)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 230, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 230, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 6)
                )
            Ellipse()
                .fill(RadialGradient(colors: [amber.opacity(0.32), .clear], center: .center, startRadius: 10, endRadius: 360))
                .frame(width: 800, height: 520)
                .offset(y: 120)
            Image(systemName: "house.fill")
                .font(.system(size: 560, weight: .regular))
                .foregroundStyle(LinearGradient(colors: [.white, Color(white: 0.8)], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 20)
                .offset(y: -10)
            // The door, lit from inside.
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(LinearGradient(colors: [amber, Color(red: 1.0, green: 0.6, blue: 0.2)], startPoint: .top, endPoint: .bottom))
                .frame(width: 150, height: 200)
                .shadow(color: amber, radius: 40)
                .offset(y: 168)
        }
        .frame(width: 1024, height: 1024)
        .clipShape(RoundedRectangle(cornerRadius: 230, style: .continuous))
        // macOS icons leave a margin around the squircle.
        .scaleEffect(824 / 1024)
        .frame(width: 1024, height: 1024)
    }
}

let output = CommandLine.arguments.dropFirst().first ?? "icon.png"
MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: Icon())
    renderer.scale = 1
    guard let image = renderer.cgImage,
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { fatalError("Couldn't render icon") }
    try! png.write(to: URL(fileURLWithPath: output))
}
