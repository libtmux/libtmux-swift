/// Preserves file identity components without trapping on Darwin's signed dev_t.
/// Sign-extension keeps distinct raw values distinct, including negative devices.
func fileIdentityComponent<Raw: FixedWidthInteger>(_ raw: Raw) -> UInt64 {
    UInt64(truncatingIfNeeded: raw)
}
