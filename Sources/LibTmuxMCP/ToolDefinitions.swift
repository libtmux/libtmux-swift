extension TmuxTools {
    /// The one authoritative public tool registry, in protocol order.
    public static let definitions = capabilityDefinitions

    static let byName = Dictionary(
        uniqueKeysWithValues: definitions.map { ($0.name, $0) }
    )
}
