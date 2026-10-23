import CarPlay
import LarCore
import UIKit

/// The CarPlay screen (Driving Task category): the scenes, then the devices that switch, grouped by kind, with their state; a tap
/// switches one. An LG air conditioner opens its own list: power and the target temperature up or down.
///
/// CarPlay only runs apps Apple has approved for a category: on a car this needs the
/// `com.apple.developer.carplay-driving-task` entitlement in a paid team's profile. The iOS Simulator's CarPlay
/// window runs it without approval (the entitlement is in the simulator build only, see project.yml).
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private let root = CPListTemplate(title: "Lar", sections: [])
    private var acTemplate: CPListTemplate?
    private var acDeviceID: String?
    private var model: LarModel { LarPhoneApp.model }

    /// CarPlay lists keep few items while driving; the rest stays on the phone.
    private static let maxItems = 12

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        interfaceController.delegate = self
        root.tabTitle = "Casa"
        root.emptyViewTitleVariants = ["Nenhum aparelho"]
        root.emptyViewSubtitleVariants = ["Configure as contas no Lar do iPhone."]
        interfaceController.setRootTemplate(root, animated: false, completion: nil)
        model.home.isPopoverVisible = true
        model.home.start()
        observe()
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
        closeAirConditioner()
    }

    // MARK: Device list

    /// Rebuilds the lists from the store whenever what they read changes (Observation, re-registered each time).
    private func observe() {
        withObservationTracking {
            updateRoot()
            updateAirConditioner()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func updateRoot() {
        let usable: (HomeDevice) -> Bool = { $0.canSwitch || $0.kind == .airConditioner && $0.provider == .lg }
        // Scenes first: one tap does several things, the best fit for driving.
        let sceneItems = model.scenes.scenes.prefix(Self.maxItems).map(sceneItem)
        var count = sceneItems.count
        var sections = sceneItems.isEmpty ? [] : [CPListSection(items: Array(sceneItems), header: "Cenas", sectionIndexTitle: nil)]
        // The phone's sections: favorites first, then by kind or room; hidden devices left out.
        sections += model.home.sections(grouping: model.home.grouping).compactMap { section -> CPListSection? in
            let items = section.devices.filter(usable).prefix(max(0, Self.maxItems - count)).map(item)
            count += items.count
            return items.isEmpty ? nil : CPListSection(items: items, header: section.title, sectionIndexTitle: nil)
        }
        root.updateSections(sections)
    }

    private func sceneItem(_ scene: HomeScene) -> CPListItem {
        let item = CPListItem(text: scene.name, detailText: "\(scene.actions.count) comandos", image: UIImage(systemName: scene.symbol))
        item.handler = { [weak self] _, completion in
            Task { @MainActor in
                self?.model.home.run(scene)
                completion()
            }
        }
        return item
    }

    private func item(_ device: HomeDevice) -> CPListItem {
        let on = device.isOn == true && device.isOnline
        let item = CPListItem(text: device.name, detailText: Labels.subtitle(device),
                              image: UIImage(systemName: Labels.icon(device.kind, on: on)))
        let opensAC = device.kind == .airConditioner && device.provider == .lg && device.isOnline
        item.accessoryType = opensAC ? .disclosureIndicator : .none
        item.isEnabled = device.isOnline || device.canSwitch
        item.handler = { [weak self] _, completion in
            Task { @MainActor in
                if opensAC {
                    self?.openAirConditioner(device)
                } else {
                    self?.model.home.toggle(device.id)
                }
                completion()
            }
        }
        return item
    }

    // MARK: Air conditioner

    private func openAirConditioner(_ device: HomeDevice) {
        model.openAirConditioner(rawID: device.rawID)
        acDeviceID = device.id
        let template = CPListTemplate(title: device.name, sections: [])
        acTemplate = template
        updateAirConditioner()
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func closeAirConditioner() {
        guard acTemplate != nil else { return }
        acTemplate = nil
        acDeviceID = nil
        model.closeAirConditioner()
    }

    private func updateAirConditioner() {
        guard let template = acTemplate, let store = model.airConditioner else { return }
        let status = store.status
        let isOn = status?.isOn ?? false
        let caps = store.capabilities
        let target = status?.targetTemperature

        let power = CPListItem(text: isOn ? "Desligar" : "Ligar", detailText: Labels.activity(status, target: target),
                               image: UIImage(systemName: "power"))
        power.handler = { _, completion in
            store.perform(.power(!isOn))
            completion()
        }
        let warmer = CPListItem(text: "Aumentar 1°", detailText: "Ajustado em \(Labels.temperature(target))°C",
                                image: UIImage(systemName: "plus.circle"))
        warmer.handler = { _, completion in
            if let target { store.setTargetTemperature(target + max(caps.temperatureStep, 1), debounced: true) }
            completion()
        }
        let cooler = CPListItem(text: "Diminuir 1°", detailText: "Ambiente \(Labels.temperature(status?.currentTemperature))°C",
                                image: UIImage(systemName: "minus.circle"))
        cooler.handler = { _, completion in
            if let target { store.setTargetTemperature(target - max(caps.temperatureStep, 1), debounced: true) }
            completion()
        }
        let editable = isOn && ACMode.acceptsTargetTemperature(status?.mode)
        warmer.isEnabled = editable
        cooler.isEnabled = editable
        power.isEnabled = status != nil
        template.updateSections([
            CPListSection(items: [power]),
            CPListSection(items: [warmer, cooler], header: "Temperatura", sectionIndexTitle: nil),
        ])
    }
}

extension CarPlaySceneDelegate: CPInterfaceControllerDelegate {
    /// Back on the list: the air conditioner's store stops polling.
    nonisolated func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        nonisolated(unsafe) let template = aTemplate
        Task { @MainActor in
            if template === self.acTemplate { self.closeAirConditioner() }
        }
    }
}
