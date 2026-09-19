/// Converts one component of a `stat` result -- `st_dev`, `st_ino` -- into a
/// form two reads of the same file can be compared by.
///
/// `st_dev` is `dev_t`: unsigned on Linux, but a signed `Int32` on Darwin,
/// where it is negative for a major device number >= 128 (FUSE, disk images,
/// network filesystems). A plain `UInt64(_:)` traps on a negative input, which
/// is exactly what a file on one of those devices supplies.
/// `truncatingIfNeeded` widens by sign-extending instead of rejecting, so it
/// never traps, and sign-extension is a bijection over the source type's bit
/// pattern: the same raw value always produces the same `UInt64`, and two
/// different raw values never collide. That is the whole of what an identity
/// check needs -- `st_ino` (`ino_t`, unsigned everywhere this package runs)
/// goes through the same call for symmetry, not because it shares the risk.
func fileIdentityComponent<Raw: FixedWidthInteger>(_ raw: Raw) -> UInt64 {
    UInt64(truncatingIfNeeded: raw)
}
