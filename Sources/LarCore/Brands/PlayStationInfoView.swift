#if !os(watchOS)
import SwiftUI

/// What the PlayStation account says: the game being played (its art and for how long) and the trophies.
public struct PlayStationInfoView: View {
    let device: HomeDevice

    public init(device: HomeDevice) {
        self.device = device
    }

    public static func shows(_ device: HomeDevice) -> Bool {
        device.controls["game"] != nil || device.controls["trophies"] != nil
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let game = device.controls["game"] {
                HStack(spacing: 12) {
                    if let art = device.controls["art"].flatMap(URL.init(string:)) {
                        AsyncImage(url: art) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.secondary.opacity(0.2)
                        }
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(game).font(.headline).lineLimit(2)
                        if let since = device.controls["since"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) {
                            Text("Jogando há \(Text(since, style: .relative))").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let trophies = device.controls["trophies"]?.split(separator: "|").compactMap({ Int($0) }), trophies.count == 5 {
                HStack(spacing: 12) {
                    Label("Nível \(trophies[0])", systemImage: "trophy.fill").foregroundStyle(.yellow)
                    Spacer()
                    trophy(trophies[1], .cyan)
                    trophy(trophies[2], .yellow)
                    trophy(trophies[3], .gray)
                    trophy(trophies[4], .brown)
                }
                .font(.footnote)
            }
        }
    }

    private func trophy(_ count: Int, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "trophy.fill").foregroundStyle(color)
            Text("\(count)").monospacedDigit()
        }
    }
}
#endif
