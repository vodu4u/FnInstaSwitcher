import AppKit
import CoreGraphics
import ServiceManagement

/// Persisted user settings.
enum Settings {
    static let enabledKey = "enabled"
    static let cursorIndicatorKey = "cursorIndicator"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [enabledKey: true, cursorIndicatorKey: false])
    }
    /// Opt-in: show InstantFn's own language bubble at the text cursor (needs Accessibility).
    static var cursorIndicator: Bool {
        get { UserDefaults.standard.bool(forKey: cursorIndicatorKey) }
        set { UserDefaults.standard.set(newValue, forKey: cursorIndicatorKey) }
    }
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}

/// The macOS setting "Keyboard → Press 🌐 key to". InstantFn only *reads* it.
///
/// If it is "Change Input Source", macOS switches too and every Fn press would switch
/// twice (net: nothing). InstantFn pauses switching in that case and asks the user to
/// set it to "Do Nothing". To restore standard behavior, set it back.
enum GlobeKeySetting {
    // Values as stored by System Settings in com.apple.HIToolbox / AppleFnUsageType.
    enum Action: Int {
        case doNothing = 0, changeInputSource = 1, emojiAndSymbols = 2, dictation = 3
        var title: String {
            switch self {
            case .doNothing: "Do Nothing"
            case .changeInputSource: "Change Input Source"
            case .emojiAndSymbols: "Show Emoji & Symbols"
            case .dictation: "Start Dictation"
            }
        }
    }

    /// nil = the key is not set (macOS uses a hardware-dependent default).
    static func read() -> Action? {
        let domain = "com.apple.HIToolbox" as CFString
        CFPreferencesAppSynchronize(domain)
        guard let raw = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, domain) as? Int else { return nil }
        return Action(rawValue: raw)
    }

    /// True if the system's own Globe action would also switch input sources.
    static var conflictsWithInstantFn: Bool { read() == .changeInputSource }

    /// True if a plain Fn tap also does something else (emoji picker, dictation, or an
    /// unset value whose default depends on the Mac). InstantFn still switches, but
    /// asks the user to choose "Do Nothing".
    static var needsDoNothing: Bool { read() != .doNothing }

    static func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }
}

/// macOS's own language bubble at the text cursor: the per-user global preference
/// `TSMLanguageIndicatorEnabled` (absent = on). Takes effect immediately, no admin rights.
/// When it's off, macOS still shows a small grey label for programmatic switches.
enum SystemLanguageIndicator {
    private static let key = "TSMLanguageIndicatorEnabled" as CFString

    static var isHidden: Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        return (CFPreferencesCopyAppValue(key, kCFPreferencesAnyApplication) as? Bool) == false
    }

    /// Hiding writes `false`; showing removes the key, i.e. back to the macOS default.
    static func setHidden(_ hidden: Bool) {
        CFPreferencesSetValue(key, hidden ? kCFBooleanFalse : nil,
                              kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}

/// Input Monitoring is the only permission InstantFn uses.
enum Permissions {
    static var inputMonitoringGranted: Bool { CGPreflightListenEventAccess() }

    /// Shows the system prompt the first time; afterwards macOS only allows changing it
    /// in System Settings, so we open the right pane.
    static func requestInputMonitoring() {
        if !CGRequestListenEventAccess() { openInputMonitoringSettings() }
    }

    static func openInputMonitoringSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
}

/// Launch at login via `SMAppService` (no helper app, no launchd plist written by us).
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isOn: Bool { status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("InstantFn: launch-at-login change failed: \(error.localizedDescription)")
        }
        if status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}
