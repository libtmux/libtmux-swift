import Foundation

/// The immutable selection applied to the authoritative registry.
public struct ToolAuthority: Sendable, Hashable {
    public let toolsets: Set<Toolset>
    public let includedTools: Set<String>
    public let excludedTools: Set<String>
    public let usedExplicitToolsets: Bool

    public init(
        toolsets: Set<Toolset>,
        includedTools: Set<String> = [],
        excludedTools: Set<String> = [],
        usedExplicitToolsets: Bool = true
    ) {
        self.toolsets = toolsets
        self.includedTools = includedTools
        self.excludedTools = excludedTools
        self.usedExplicitToolsets = usedExplicitToolsets
    }

    func resolve(_ definitions: [ToolDefinition]) -> [ToolDefinition] {
        var selected = Set(
            definitions.lazy.filter { toolsets.contains($0.toolset) }.map(\.name)
        )
        selected.formUnion(includedTools)
        selected.subtract(excludedTools)
        let callableNested = definitions.filter { !excludedTools.contains($0.name) }
        return definitions.filter { selected.contains($0.name) }
            .map { $0.restrictingNestedAuthority(to: callableNested) }
    }

    package var summary: String {
        let groups = toolsets.map(\.rawValue).sorted().joined(separator: ",")
        return "toolsets [\(groups)], \(includedTools.count) named inclusions, "
            + "\(excludedTools.count) exclusions"
    }
}
