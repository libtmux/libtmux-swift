import Testing

@testable import LibTmuxMCP

/// Covers the identity property `fileIdentityComponent` exists for, using
/// synthetic `dev_t` bit patterns rather than a real file.
///
/// The crash this guards against needs a file whose major device number is
/// >= 128 -- FUSE, a disk image, a network filesystem -- on Darwin, where
/// `dev_t` is a signed `Int32`. Neither a loop device nor a FUSE mount
/// reaches it on Linux: this platform's own `dev_t` is unsigned, so nothing
/// mounted here, however constructed, can carry the negative bit pattern
/// that only exists inside Darwin's 32-bit signed encoding. A synthetic value
/// standing in for that encoding is therefore not a fallback for a real
/// device; it is the only way to exercise this property outside Darwin
/// itself.
@Suite("file identity components")
struct FileIdentityTests {
    /// Darwin's `makedev`: an 8-bit major in the top byte, a 24-bit minor
    /// below it. A major >= 128 sets bit 31, which is the sign bit of the
    /// `Int32` `dev_t` is declared as there.
    private static func darwinDevT(major: UInt8, minor: UInt32) -> Int32 {
        Int32(bitPattern: (UInt32(major) << 24) | (minor & 0xff_ffff))
    }

    @Test(
        "a major device number >= 128 reaches Darwin's negative dev_t",
        arguments: [UInt8(128), 129, 200, 255]
    )
    func majorAtOrAboveTheThresholdIsNegative(major: UInt8) {
        // Confirms the fixture actually lands in the zone the production
        // comment describes, rather than asserting a property that happens
        // to hold for an unrelated value.
        #expect(Self.darwinDevT(major: major, minor: 42) < 0)
    }

    @Test("a major device number below 128 stays positive")
    func majorBelowTheThresholdIsPositive() {
        // The contrasting case: an ordinary disk (major 8, say) never hits
        // the trap in the first place, so a fix that only worked by
        // coincidence for small majors would not be caught by the tests
        // above alone.
        #expect(Self.darwinDevT(major: 8, minor: 1) > 0)
    }

    @Test(
        "the same raw value always converts to the same identity",
        arguments: [UInt8(8), 127, 128, 200, 255]
    )
    func conversionIsRepeatable(major: UInt8) {
        let raw = Self.darwinDevT(major: major, minor: 7)
        // Standing in for two `stat` calls against one unchanged file.
        #expect(fileIdentityComponent(raw) == fileIdentityComponent(raw))
    }

    @Test("distinct raw values never collide, negative ones included")
    func conversionNeverCollides() {
        let majors: [UInt8] = [0, 1, 8, 127, 128, 129, 200, 254, 255]
        let raw = majors.map { Self.darwinDevT(major: $0, minor: 42) }
        #expect(raw.contains { $0 < 0 })
        let converted = Set(raw.map(fileIdentityComponent))
        #expect(converted.count == raw.count)
    }

    @Test(
        "the values a plain UInt64(_:) would trap on are exactly the negative ones",
        arguments: [UInt8(128), 200, 255]
    )
    func theDangerZoneIsWhereADirectConversionIsUnrepresentable(major: UInt8) {
        let raw = Self.darwinDevT(major: major, minor: 3)
        // `UInt64(exactly:)` returning `nil` is the non-trapping witness that
        // `UInt64(raw)` would trap here -- the crash `fileIdentityComponent`
        // exists to avoid. `truncatingIfNeeded` succeeds where this fails.
        #expect(UInt64(exactly: raw) == nil)
        #expect(fileIdentityComponent(raw) == UInt64(truncatingIfNeeded: raw))
    }
}
