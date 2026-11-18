import Sparkle
import SwiftUI

// Previews build a ServerController, which starts iMCP's network manager.
// They keep the server off (`isEnabled` is false) and don't toggle services.

#Preview("Menu") {
    // A native menu renders its items in a list here, not as a real menu.
    VStack(alignment: .leading) {
        ContentView(
            serverManager: ServerController(),
            isEnabled: .constant(false),
            updater: SPUStandardUpdaterController(
                startingUpdater: false,
                updaterDelegate: nil,
                userDriverDelegate: nil
            ).updater
        )
    }
    .padding()
}

#Preview("Settings") {
    SettingsView(serverController: ServerController(), isMenuBarExtraInserted: true)
}

#Preview("General") {
    GeneralSettingsView(serverController: ServerController(), isMenuBarExtraInserted: true)
        .frame(width: 500, height: 300)
}

#Preview("Clients") {
    ClientsSettingsView(serverController: ServerController())
        .frame(width: 500, height: 560)
}

#Preview("Service") {
    let controller = ServerController()
    if let config = controller.computedServiceConfigs.first {
        ServiceSettingsView(serverController: controller, config: config)
            .frame(width: 500, height: 560)
    }
}

#Preview("Set Up iMCP") {
    let controller = ServerController()
    OnboardingView(
        model: OnboardingModel(mode: .firstRun, serverController: controller, isEnabled: .constant(false))
    )
}
