import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Installs the bundled `AntiBleed.driver` into the system HAL plug-in folder
/// (D-023).
///
/// The product is a menu-bar utility for non-technical users: telling them to
/// run `Scripts/install-driver.sh` from a terminal is not a shipping answer.
/// The driver ships inside the app bundle at
/// `Contents/Library/Audio/Plug-Ins/HAL/AntiBleed.driver`, and this type copies
/// it to `/Library/Audio/Plug-Ins/HAL/` and restarts `coreaudiod`.
///
/// Writing to `/Library` and restarting a system daemon both require root, so
/// the copy runs through one `AppleScript` `with administrator privileges`
/// call: macOS shows its own authentication dialog, the app never sees the
/// password. Everything happens in a single elevated shell invocation so the
/// user is prompted exactly once.
public enum DriverInstaller {
    public enum Status: Equatable {
        case installed              // present and same version as the bundled one
        case outdated               // present but older than the bundled one
        case notInstalled
        case noBundledDriver        // running from a raw SwiftPM binary, not a bundle
    }

    public enum InstallError: LocalizedError {
        case noBundledDriver
        case authorizationCancelled
        case commandFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noBundledDriver:
                return "This build has no bundled driver. Run Scripts/package.sh to produce AntiBleed.app."
            case .authorizationCancelled:
                return "Installation needs an administrator password. Nothing was changed."
            case .commandFailed(let detail):
                return "Driver installation failed: \(detail)"
            }
        }
    }

    public static let installedPath = "/Library/Audio/Plug-Ins/HAL/AntiBleed.driver"

    /// The driver inside our own app bundle, if we are running as one.
    public static var bundledDriverPath: String? {
#if canImport(AppKit)
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/Audio/Plug-Ins/HAL/AntiBleed.driver")
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
#else
        return nil
#endif
    }

    /// CFBundleVersion of a driver bundle, used to detect an outdated install.
    static func version(ofDriverAt path: String) -> String? {
        let plist = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return (dict["CFBundleVersion"] as? String) ?? (dict["CFBundleShortVersionString"] as? String)
    }

    public static func status() -> Status {
        guard let bundled = bundledDriverPath else {
            return FileManager.default.fileExists(atPath: installedPath) ? .installed : .noBundledDriver
        }
        guard FileManager.default.fileExists(atPath: installedPath) else { return .notInstalled }
        let installedVersion = version(ofDriverAt: installedPath)
        let bundledVersion = version(ofDriverAt: bundled)
        if let a = installedVersion, let b = bundledVersion, a != b { return .outdated }
        return .installed
    }

    /// Copies the bundled driver into place and restarts coreaudiod.
    ///
    /// MUST be called on the main thread: `NSAppleScript` is documented by Apple
    /// as "main thread only" (Thread Safety Summary, Foundation). Running it on a
    /// background queue is the classic intermittent-crash recipe.
    ///
    /// Staged through `/tmp` on purpose: with the app in `~/Desktop` or
    /// `~/Downloads`, a root shell is still blocked by TCC from reading the
    /// user's folder, so a direct `cp` fails with "Operation not permitted".
    /// `/tmp` is outside TCC, so the unprivileged copy happens first and only
    /// the final move needs root.
    @MainActor
    public static func install() throws {
#if canImport(AppKit)
        guard let source = bundledDriverPath else { throw InstallError.noBundledDriver }

        let stage = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("AntiBleed_install_stage.driver")
        try? FileManager.default.removeItem(atPath: stage)
        try FileManager.default.copyItem(atPath: source, toPath: stage)
        defer { try? FileManager.default.removeItem(atPath: stage) }

        // One elevated shell: replace the bundle, fix ownership, restart the daemon.
        // Single-quoted paths; the quoting helper rejects anything that could
        // escape them.
        let script = "rm -rf '\(installedPath)'"
            + " && mkdir -p '/Library/Audio/Plug-Ins/HAL'"
            + " && cp -R '\(stage)' '\(installedPath)'"
            + " && chown -R root:wheel '\(installedPath)'"
            + " && chmod -R 755 '\(installedPath)'"
            + " && (launchctl kickstart -k system/com.apple.audio.coreaudiod || killall coreaudiod)"
        guard !stage.contains("'"), !installedPath.contains("'") else {
            throw InstallError.commandFailed("unsafe path")
        }
        try runElevated(script)
#else
        throw InstallError.noBundledDriver
#endif
    }

#if canImport(AppKit)
    /// Runs a shell command as root through the system authentication dialog.
    /// The password is typed into macOS's own panel; it never reaches this process.
    @MainActor
    private static func runElevated(_ shellCommand: String) throws {
        // The command is embedded in an AppleScript string literal, so backslashes
        // and double quotes must be escaped for AppleScript, in that order.
        let quoted = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(quoted)\" with administrator privileges"
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw InstallError.commandFailed("could not build the installation script")
        }
        script.executeAndReturnError(&error)
        if let error {
            // -128 is the documented "user cancelled" code from the auth dialog.
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -128 { throw InstallError.authorizationCancelled }
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "unknown error"
            throw InstallError.commandFailed(message)
        }
    }
#endif
}
