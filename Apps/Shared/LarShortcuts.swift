import AppIntents

/// The phrases Siri knows without any setup, and what the Shortcuts app offers first.
struct LarShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunSceneIntent(),
            phrases: ["Executar \(\.$scene) no \(.applicationName)", "Ativar \(\.$scene) no \(.applicationName)",
                      "Cena \(\.$scene) no \(.applicationName)"],
            shortTitle: "Executar cena", systemImageName: "sparkles"
        )
        AppShortcut(
            intent: TurnOnIntent(),
            phrases: ["Ligar \(\.$device) no \(.applicationName)", "Ligue \(\.$device) no \(.applicationName)"],
            shortTitle: "Ligar", systemImageName: "power"
        )
        AppShortcut(
            intent: TurnOffIntent(),
            phrases: ["Desligar \(\.$device) no \(.applicationName)", "Desligue \(\.$device) no \(.applicationName)"],
            shortTitle: "Desligar", systemImageName: "poweroff"
        )
    }
}
