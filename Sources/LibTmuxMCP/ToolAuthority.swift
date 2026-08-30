import Foundation

/// The tools this server is authorised to expose and run.
public struct ToolAuthority: Sendable, Hashable {
    /// The highest tier any enabled tool may reach.
    public let tier: SafetyTier
    /// The exact tools enabled within `tier`, or `nil` for every tool in it.
    public let enabledTools: Set<ToolOperation>?

    public init(
        tier: SafetyTier = .readonly,
        enabledTools: Set<ToolOperation>? = nil
    ) {
        self.tier = tier
        self.enabledTools = enabledTools
    }

    static func configured(tier: SafetyTier, exactNames value: String) -> (
        authority: ToolAuthority,
        warning: String?
    ) {
        if value.isEmpty {
            return (ToolAuthority(tier: tier, enabledTools: []), nil)
        }

        let names = value.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard names.allSatisfy({ !$0.isEmpty }) else {
            return (
                ToolAuthority(tier: tier, enabledTools: []),
                "LIBTMUX_MCP_TOOLS contains an empty tool name; serving no tools"
            )
        }

        let unknown = names.filter { ToolOperation(rawValue: $0) == nil }
        guard unknown.isEmpty else {
            return (
                ToolAuthority(tier: tier, enabledTools: []),
                "LIBTMUX_MCP_TOOLS contains unknown tool names: "
                    + unknown.sorted().joined(separator: ", ")
                    + "; serving no tools"
            )
        }

        return (
            ToolAuthority(
                tier: tier,
                enabledTools: Set(names.compactMap(ToolOperation.init(rawValue:)))
            ),
            nil
        )
    }

    func rejection(for definition: ToolDefinition) -> ToolError? {
        guard definition.tier <= tier else {
            return .deniedByTier(
                definition.name,
                needs: definition.tier,
                allowed: tier
            )
        }
        if let enabledTools, !enabledTools.contains(definition.operation) {
            return .notEnabled(definition.name)
        }
        return nil
    }

    package var summary: String {
        guard let enabledTools else { return "the \(tier.rawValue) tier" }
        return "\(enabledTools.count) exact tools within the \(tier.rawValue) tier"
    }
}
