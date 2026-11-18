import AppKit
import EventKit
import ServiceManagement
import SwiftUI

/// The Services tab: every service with its switch. A row opens that service's own options.
struct ServicesSettingsView: View {
    @ObservedObject var serverController: ServerController
    @State private var path: [String] = []

    var body: some View {
        let configs = serverController.computedServiceConfigs

        NavigationStack(path: $path) {
            Form {
                Section {
                    ForEach(configs) { config in
                        row(config)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Services")
            .navigationDestination(for: String.self) { id in
                if let config = configs.first(where: { $0.id == id }) {
                    ServiceSettingsView(serverController: serverController, config: config)
                }
            }
        }
    }

    private func row(_ config: ServiceConfig) -> some View {
        HStack(spacing: 10) {
            Button {
                path.append(config.id)
            } label: {
                HStack(spacing: 10) {
                    ServiceIcon(config: config, isOn: config.binding.wrappedValue, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(config.name)
                        Text(config.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle(
                config.name,
                isOn: Binding(
                    get: { config.binding.wrappedValue },
                    // Delegate to ServerController so toggling activates the service (permission
                    // prompt, revert on failure) and pushes updated bindings to connected clients.
                    set: { serverController.setService(config, enabled: $0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
    }
}

/// The options of one service: its switch, what it can change, and which of its tools clients can use.
struct ServiceSettingsView: View {
    @ObservedObject var serverController: ServerController
    let config: ServiceConfig
    @State private var isToolsExpanded = false

    var body: some View {
        let isOn = config.binding.wrappedValue

        Form {
            Section {
                LabeledContent {
                    Toggle(config.name, isOn: serviceBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                } label: {
                    RowLabel(title: config.name, subtitle: config.summary) {
                        ServiceIcon(config: config, isOn: isOn, size: 32)
                    }
                }
            }

            if config.service is HomeService {
                HomeHelperSection(isHomeOn: isOn)
            }

            if config.service is FilesService {
                FilesFoldersSection()
                    .disabled(!isOn)
            }

            if config.service is CalendarService {
                CalendarSelectionSection(isCalendarOn: isOn)
            }

            if config.service.hasWriteTools {
                WritesSection(serverController: serverController, service: config.service, name: config.name)
                    .disabled(!isOn)
            }

            if config.service is NotesService {
                PrivateNotesSection()
                    .disabled(!isOn)
            }

            if config.service is RemindersService {
                PrivateRemindersSection()
            }

            toolsSection(isOn: isOn)
        }
        .formStyle(.grouped)
        .navigationTitle(config.name)
    }

    private func toolsSection(isOn: Bool) -> some View {
        let tools = config.service.tools
        let enabledCount = tools.filter { serverController.isToolEnabled($0.name) }.count
        return Section {
            DisclosureGroup(isExpanded: $isToolsExpanded) {
                ForEach(tools, id: \.name) { tool in
                    Toggle(isOn: toolBinding(tool.name)) {
                        HStack(spacing: 6) {
                            if let title = tool.annotations.title {
                                Text(title)
                            } else {
                                // Without a title, show the name that clients call the tool by.
                                Text(tool.name)
                                    .monospaced()
                            }
                            if tool.annotations.readOnlyHint == true {
                                StatusBadge(text: "Read-only")
                            } else if tool.isWrite, !config.service.areWritesEnabled() {
                                StatusBadge(text: "Writes off", kind: .attention)
                            }
                        }
                    }
                    // While the service is off, its tools keep their own settings,
                    // but a disabled switch alone still looks on, so dim the whole row.
                    .disabled(!isOn)
                    .opacity(isOn ? 1 : 0.5)
                }
            } label: {
                LabeledContent {
                    Text("\(enabledCount) of \(tools.count) on")
                        .foregroundStyle(.secondary)
                } label: {
                    RowLabel(title: "Tools") {
                        SettingsIcon(symbol: "wrench.and.screwdriver.fill", color: .gray)
                    }
                }
            }
        }
    }

    private var serviceBinding: Binding<Bool> {
        Binding(
            get: { config.binding.wrappedValue },
            set: { serverController.setService(config, enabled: $0) }
        )
    }

    private func toolBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { serverController.isToolEnabled(name) },
            set: { serverController.setTool(name, enabled: $0) }
        )
    }
}

/// The switch for the Reminders tools that use Apple's private ReminderKit framework.
private struct PrivateRemindersSection: View {
    @AppStorage(RemindersPrivate.settingKey) private var isEnabled = false

    var body: some View {
        Section {
            Toggle(isOn: $isEnabled) {
                RowLabel(title: "Private Reminders features", subtitle: "Tags, sections, subtasks, flags") {
                    SettingsIcon(symbol: "checklist", color: .orange)
                }
            }
            DisclosureGroup("Details") {
                Text(
                    "These use Apple's unsupported ReminderKit framework, which can change in any macOS update. Changes are saved through Reminders, never by editing its database. Off by default."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// A service's symbol on a circle,
/// in the service's color while the service is on and in gray while it's off,
/// as in the menu.
struct ServiceIcon: View {
    let config: ServiceConfig
    let isOn: Bool
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: config.iconName)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.white)
            .padding(size * 0.2)
            .frame(width: size, height: size)
            .background(isOn ? config.color : .gray, in: Circle())
            .animation(.default, value: isOn)
            .accessibilityHidden(true)
    }
}

/// The "Allow writes" switch of a service that has tools that change things.
///
/// Services that had write tools before this setting existed start on, so an update changes nothing for them.
/// The others start off, until the person turns the switch on.
private struct WritesSection: View {
    @ObservedObject var serverController: ServerController
    let service: any Service
    let name: String
    @AppStorage private var isWriteEnabled: Bool
    @AppStorage(ApprovalMode.defaultsKey) private var approvalModeRawValue = ApprovalMode.defaultMode.rawValue

    init(serverController: ServerController, service: any Service, name: String) {
        self.serverController = serverController
        self.service = service
        self.name = name
        _isWriteEnabled = AppStorage(
            wrappedValue: service.writesEnabledByDefault,
            ServiceWrites.settingKey(forService: service.serviceID)
        )
    }

    private var approvalMode: ApprovalMode {
        ApprovalMode(rawValue: approvalModeRawValue) ?? .defaultMode
    }

    var body: some View {
        Section {
            Toggle(isOn: $isWriteEnabled) {
                RowLabel(title: "Allow writes", subtitle: subtitle) {
                    SettingsIcon(symbol: "pencil", color: .blue)
                }
            }
            .disabled(approvalMode.bypassesServiceWriteToggles)
            .onChange(of: isWriteEnabled) {
                // Redraw the tool list's "Writes off" labels, and tell clients to list the tools again.
                serverController.objectWillChange.send()
                serverController.toolListChanged()
            }
            if service is NotesService {
                DisclosureGroup("Details") {
                    Text(
                        "Clients can create, edit, move, and delete notes and folders. Deleted notes go to Recently Deleted. An edit is refused if the note changed since the client read it. The first time, macOS asks whether iMCP may control Notes."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var subtitle: String {
        approvalMode.bypassesServiceWriteToggles
            ? "Always on in this approval mode"
            : "Create, change and delete in \(name)"
    }
}

/// The switch for the Notes tools that use Apple's private NotesShared framework.
private struct PrivateNotesSection: View {
    @AppStorage(NotesPrivate.settingKey) private var isEnabled = false

    var body: some View {
        Section {
            Toggle(isOn: $isEnabled) {
                RowLabel(title: "Private Notes features", subtitle: "Tags, checklists, tables, pins") {
                    SettingsIcon(symbol: "note.text", color: .yellow)
                }
            }
            DisclosureGroup("Details") {
                Text(
                    "These use Apple's unsupported NotesShared framework, which can change in any macOS update. They need Allow writes. Changes are saved through Notes' own code, never by editing its database. Off by default."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// The folders that the Files service shares.
private struct FilesFoldersSection: View {
    @State private var folders: [(id: UUID, status: FilesRootStatus)] = []
    @State private var errorMessage: String?

    var body: some View {
        Section {
            if folders.isEmpty {
                EmptyRow(symbol: "folder.badge.plus", text: "No folders shared")
            }
            ForEach(folders, id: \.id) { folder in
                LabeledContent {
                    Button("Remove", role: .destructive) {
                        FilesRootStore.shared.remove(folder.id)
                        reload()
                    }
                } label: {
                    RowLabel(
                        title: folder.status.name,
                        subtitle: folder.status.state == .needsReAdd
                            ? "Remove and add it again"
                            : (folder.status.path ?? "Can't be opened")
                    ) {
                        SettingsIcon(
                            symbol: folder.status.state == .needsReAdd
                                ? "exclamationmark.triangle.fill" : "folder.fill",
                            color: folder.status.state == .needsReAdd ? .orange : .blue
                        )
                    }
                }
            }
            Button("Add Folder…", action: addFolder)
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            SectionTitle(title: "Shared folders", symbol: "folder")
        } footer: {
            Text("Clients can only see these folders.")
        }
        .task { reload() }
    }

    private func reload() {
        folders = FilesRootStore.shared.summaries()
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Share Folder"
        panel.message = "Choose a folder to share with the apps that use iMCP."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FilesRootStore.shared.add(url)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }
}

/// Whether iMCP Helper's launch agent is registered, which Home needs.
private struct HomeHelperSection: View {
    var isHomeOn: Bool

    @State private var state = HomeService.shared.state()
    @State private var isWorking = false
    @State private var isConfirmingUnregister = false
    @State private var errorMessage: String?

    var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    StatusBadge(text: badgeText, kind: badgeKind)
                    switch state {
                    case .notBundled:
                        EmptyView()
                    case .notRegistered:
                        Button("Register") { register() }
                            .disabled(isWorking)
                    case .needsApproval:
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    case .registered:
                        Button("Unregister…") { isConfirmingUnregister = true }
                            .disabled(isWorking)
                    }
                }
            } label: {
                RowLabel(title: "iMCP Helper", subtitle: errorMessage ?? note) {
                    SettingsIcon(symbol: "house.fill", color: .orange)
                }
            }
        }
        .confirmationDialog("Unregister iMCP Helper?", isPresented: $isConfirmingUnregister) {
            Button("Unregister", role: .destructive) {
                Task {
                    isWorking = true
                    defer { isWorking = false }
                    do {
                        try await HomeService.shared.unregister()
                        errorMessage = nil
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    state = HomeService.shared.state()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Home tools stop working until you register it again.")
        }
        .task {
            state = HomeService.shared.state()
            errorMessage = await HomeService.shared.lastFailure
        }
    }

    private var badgeText: String {
        switch state {
        case .notBundled: "Not included"
        case .notRegistered: "Off"
        case .needsApproval: "Needs approval"
        case .registered: "Registered"
        }
    }

    private var badgeKind: StatusBadge.Kind {
        switch state {
        case .notBundled, .notRegistered: .neutral
        case .needsApproval: .attention
        case .registered: .good
        }
    }

    /// One line for the states that need an explanation.
    private var note: String? {
        switch state {
        case .notBundled: "Home needs it to reach HomeKit"
        case .needsApproval: "Approve it in Login Items"
        default: nil
        }
    }

    private func register() {
        Task {
            isWorking = true
            defer { isWorking = false }
            do {
                try await HomeService.shared.register()
                errorMessage = nil
                if isHomeOn { try await HomeService.shared.activate() }
            } catch {
                errorMessage = error.localizedDescription
            }
            state = HomeService.shared.state()
        }
    }
}

/// Which calendars clients can see, grouped by account.
private struct CalendarSelectionSection: View {
    var isCalendarOn: Bool

    private let store = CalendarService.shared.calendarSelectionStore

    @State private var selection = CalendarSelection()
    @State private var accounts: [(source: String, calendars: [EKCalendar])] = []

    var body: some View {
        Group {
            Section {
                Toggle(isOn: showsNewCalendars) {
                    RowLabel(title: "Include new calendars") {
                        SettingsIcon(symbol: "calendar.badge.plus", color: .red)
                    }
                }
            } header: {
                SectionTitle(title: "Calendars clients can see", symbol: "calendar")
            }

            ForEach(accounts, id: \.source) { account in
                Section(account.source) {
                    ForEach(account.calendars, id: \.calendarIdentifier) { calendar in
                        Toggle(isOn: binding(for: calendar)) {
                            Label {
                                Text(calendar.title)
                            } icon: {
                                Image(systemName: "circle.fill")
                                    .foregroundStyle(Color(nsColor: calendar.color ?? .gray))
                            }
                        }
                    }
                }
            }
        }
        .disabled(!isCalendarOn)
        .opacity(isCalendarOn ? 1 : 0.5)
        .task(id: isCalendarOn) { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            reload()
        }
    }

    private var showsNewCalendars: Binding<Bool> {
        Binding(
            get: { selection.showsNewCalendars },
            set: { newValue in
                selection.setShowsNewCalendars(
                    newValue,
                    existing: accounts.flatMap(\.calendars).map(\.calendarIdentifier)
                )
                store.selection = selection
            }
        )
    }

    private func binding(for calendar: EKCalendar) -> Binding<Bool> {
        Binding(
            get: { selection.isSelected(calendar.calendarIdentifier) },
            set: { newValue in
                selection.setSelected(newValue, for: calendar.calendarIdentifier)
                store.selection = selection
            }
        )
    }

    private func reload() {
        selection = store.selection
        accounts = CalendarService.shared.calendarsBySource()
    }
}
