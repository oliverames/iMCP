import AppKit
import ServiceManagement
import Sparkle
import SwiftUI

/// The Settings window: a sidebar of tabs, and the tab that is selected.
/// The window can be resized, and the sidebar can be collapsed.
struct SettingsView: View {
    @ObservedObject var serverController: ServerController
    var isMenuBarExtraInserted: Bool
    var updater: SPUUpdater?

    // Settings reopens to the tab that was open last.
    @AppStorage("settingsPane") private var tab = SettingsTab.general
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(
                SettingsTab.allCases,
                selection: Binding<SettingsTab?>(get: { tab }, set: { if let newTab = $0 { tab = newTab } })
            ) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 240)
        } detail: {
            detail
                .background(SettingsWindowConfigurator())
        }
        .frame(
            minWidth: SettingsWindowConfigurator.minimumSize.width,
            idealWidth: SettingsWindowConfigurator.defaultSize.width,
            minHeight: SettingsWindowConfigurator.minimumSize.height,
            idealHeight: SettingsWindowConfigurator.defaultSize.height
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch tab {
        case .general:
            GeneralSettingsView(
                serverController: serverController,
                isMenuBarExtraInserted: isMenuBarExtraInserted,
                updater: updater
            )
        case .services:
            ServicesSettingsView(serverController: serverController)
        case .clients:
            ClientsSettingsView(serverController: serverController)
        case .mobile:
            MobileSettingsView(serverController: serverController)
        case .remoteAccess:
            RemoteAccessSettingsView(serverController: serverController)
        case .advanced:
            AdvancedSettingsView(serverController: serverController)
        }
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var serverController: ServerController
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage("isEnabled") private var isEnabled = true
    var isMenuBarExtraInserted: Bool
    var updater: SPUUpdater?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $isEnabled) {
                    RowLabel(title: "Server", subtitle: isEnabled ? nil : "Off. AI apps can't connect.") {
                        SettingsIcon(symbol: "power", color: .green)
                    }
                }

                Toggle(isOn: $showMenuBarExtra) {
                    RowLabel(
                        title: "Show in menu bar",
                        subtitle: showMenuBarExtra && !isMenuBarExtraInserted
                            ? "macOS hid the icon. Check System Settings."
                            : nil
                    ) {
                        SettingsIcon(symbol: "menubar.rectangle", color: .blue)
                    }
                }

                Toggle(isOn: $launchAtLogin) {
                    RowLabel(title: "Launch at login") {
                        SettingsIcon(symbol: "sunrise.fill", color: .orange)
                    }
                }
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            }

            Section {
                Picker(
                    selection: Binding(
                        get: { serverController.approvalMode },
                        set: { serverController.approvalMode = $0 }
                    )
                ) {
                    ForEach(ApprovalMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                } label: {
                    RowLabel(title: "Ask before", subtitle: serverController.approvalMode.settingsCaption) {
                        SettingsIcon(symbol: "hand.raised.fill", color: .purple)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                SectionTitle(title: "Approvals", symbol: "checkmark.shield")
            }

            Section {
                LabeledContent {
                    Button("Open…") {
                        OnboardingWindowController.shared.present(
                            serverController: serverController,
                            isEnabled: $isEnabled
                        )
                    }
                } label: {
                    RowLabel(title: "Setup Assistant") {
                        SettingsIcon(symbol: "wand.and.stars", color: .indigo)
                    }
                }

                LabeledContent {
                    Button("Check Now") { updater?.checkForUpdates() }
                        .disabled(!(updater?.canCheckForUpdates ?? false))
                } label: {
                    RowLabel(title: "Updates", subtitle: version) {
                        SettingsIcon(symbol: "arrow.triangle.2.circlepath", color: .teal)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
