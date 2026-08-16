/// The version this package is released as.
///
/// One string, because it is claimed in four places that have to agree: the git
/// tag, the `exact:` pins the documentation tells a reader to depend on, the
/// `CHANGELOG.md` entry, and what the MCP server reports to a client asking who
/// it is talking to. `Scripts/check_version.py` fails when they diverge, and
/// the release workflow refuses a tag that does not match this.
public enum LibTmuxVersion {
    /// The current version, in the form a git tag carries it: bare semver, no
    /// `v`, with a prerelease suffix while the API may still change.
    public static let current = "0.1.0-alpha.2"
}
