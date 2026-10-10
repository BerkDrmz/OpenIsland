import AppKit

/// Apps which expose a volume control of their own. No audio tap is created.
enum DirectApplicationVolume: Equatable {
    case chromium(String)
    case safari
    case music
    case spotify

    static func kind(for bundleID: String) -> Self? {
        switch bundleID {
        case "com.google.Chrome", "com.google.Chrome.canary", "com.microsoft.edgemac",
             "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera":
            // Full application audio goes through the Core Audio process tap.
            // On older macOS versions, keep the existing active-tab fallback.
            if #available(macOS 14.2, *) { return nil }
            return .chromium(bundleID)
        case "com.apple.Safari":
            if #available(macOS 14.2, *) { return nil }
            return .safari
        case "com.apple.Music": return .music
        case "com.spotify.client": return .spotify
        default: return nil
        }
    }

    var isBrowser: Bool {
        switch self { case .chromium, .safari: true; case .music, .spotify: false }
    }

    enum Result { case applied, noPlayer, browserSettingDisabled, automationDenied, failed }

    /// Called only when the user moves a slider. Browser scripts address the
    /// front window's active tab; there is no timer or background page injection.
    func apply(_ level: Float) async -> Result {
        let percentage = Int((min(max(level, 0), 1) * 100).rounded())
        let source: String
        switch self {
        case .chromium(let bundleID):
            source = """
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return -1
                return execute (active tab of front window) javascript "\(Self.browserJavaScript(percentage))"
            end tell
            """
        case .safari:
            source = """
            tell application id "com.apple.Safari"
                if (count of windows) is 0 then return -1
                return do JavaScript "\(Self.browserJavaScript(percentage))" in current tab of front window
            end tell
            """
        case .music, .spotify:
            let bundleID = self == .music ? "com.apple.Music" : "com.spotify.client"
            source = """
            tell application id "\(bundleID)"
                set sound volume to \(percentage)
                return sound volume
            end tell
            """
        }
        let outcome = await ScriptRunner.shared.execute(source, cacheResult: false) { descriptor in
            descriptor.stringValue.flatMap(Int.init)
        }
        switch outcome.errorCode {
        case 12: return .browserSettingDisabled
        case -1743: return .automationDenied
        case .some: return .failed
        case nil:
            guard let value = outcome.value else { return .failed }
            if isBrowser { return value > 0 ? .applied : .noPlayer }
            return value == percentage ? .applied : .failed
        }
    }

    /// HTML media elements only; Web Audio, protected media, remote frames and
    /// browser UI sounds are outside this API. Avoid code from untrusted pages.
    private static func browserJavaScript(_ percentage: Int) -> String {
        "(()=>{const a=document.querySelectorAll('audio,video');for(const e of a)e.volume=\(percentage)/100;return a.length})()"
    }
}
