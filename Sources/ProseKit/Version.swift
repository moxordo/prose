/// Single source of truth for the app version. `scripts/codesign.sh`'s
/// siblings (`bundle.sh`, `install.sh`) stamp this into Info.plist, and
/// `prose version` prints it. Bump here, add a CHANGELOG entry, tag `vX.Y.Z`.
public enum ProseVersion {
    public static let current = "0.2.0"
}
