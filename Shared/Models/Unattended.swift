import Foundation

/// Whether iMCP answers its own confirmation requests without showing a window.
///
/// This is the setting for a headless, unattended Mac:
/// while it is on, nothing in iMCP blocks on a popup.
/// It adds no permissions. The per-service Allow writes switches
/// still decide what clients may change.
/// See `ServiceWrites` and `OutboundConfirmation`.
enum Unattended {
    /// The `UserDefaults` key of the setting.
    static let defaultsKey = "unattendedAutoApprove"
    /// The key of the approval modes this setting replaces.
    /// Its value decides the default until the new setting is chosen.
    static let legacyDefaultsKey = "approvalMode"

    /// Whether confirmations are auto-approved, using `false` until the person chooses.
    /// A choice made under the replaced approval modes decides the default:
    /// the full-access modes that never showed iMCP windows become `true`, and the rest become `false`.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: defaultsKey) != nil {
            return defaults.bool(forKey: defaultsKey)
        }
        switch defaults.string(forKey: legacyDefaultsKey) {
        case "agentManaged", "allowEverything":
            return true
        default:
            return false
        }
    }

    static func setEnabled(_ isEnabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(isEnabled, forKey: defaultsKey)
        defaults.removeObject(forKey: legacyDefaultsKey)
    }
}

/// Calls one tool after the service's Allow writes switch.
///
/// iMCP shows no window of its own here: the switch is what stands between
/// clients and the tools that change things, and the outbound sends that
/// need a person's answer confirm through `OutboundConfirmation`,
/// which `Unattended` can auto-approve.
enum ToolCallApproval {
    static func execute(
        tool: Tool,
        in service: any Service,
        arguments: [String: Value],
        clientName: String?,
        defaults: UserDefaults = .standard
    ) async throws -> Value {
        if tool.isWrite, !service.areWritesEnabled(defaults: defaults) {
            throw WritesDisabledError(tool: tool.name)
        }

        guard
            let value = try await ToolCallContext.$clientName.withValue(
                clientName,
                operation: {
                    try await service.call(tool: tool.name, with: arguments, defaults: defaults)
                }
            )
        else {
            throw ToolExecutionError.toolNotFound(tool.name)
        }
        return value
    }
}

private enum ToolExecutionError: LocalizedError {
    case toolNotFound(String)

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let name):
            "Tool not found: \(name)"
        }
    }
}
