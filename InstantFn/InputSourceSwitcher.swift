import Carbon
import Foundation
import os

/// Finds the user's *actual* English and Russian keyboard input sources and switches
/// between them with `TISSelectInputSource`. No keystrokes are injected.
///
/// Everything here runs on the main thread: recent macOS versions assert when TSM/TIS
/// is called from a background thread.
@MainActor
final class InputSourceSwitcher: NSObject {
    struct Source {
        let id: String          // e.g. "com.apple.keylayout.US", "com.apple.keylayout.RussianWin"
        let name: String        // localized name, e.g. "U.S.", "Russian – PC"
        let language: String    // primary language code, e.g. "en", "ru"
        let isLayout: Bool      // keyboard layout (vs. input method mode)
        let ref: TISInputSource
    }

    private(set) var englishCandidates: [Source] = []
    private(set) var russianCandidates: [Source] = []
    private(set) var english: Source?
    private(set) var russian: Source?

    /// Called after the selected input source changed (by us or by anyone else).
    var onCurrentChanged: (() -> Void)?

    let stats = LatencyStats()
    /// Count of input-source changes made by someone else within `duplicateWindow` of
    /// our own switch: the typical sign that the system Globe action is still on.
    private(set) var duplicateCount = 0

    private let log = Logger(subsystem: "InstantFn", category: "switch")
    private let duplicateWindowNs: UInt64 = 300_000_000
    private var pending: (targetID: String, detectedAt: UInt64)?
    private var lastOwnSwitchAt: UInt64 = 0
    private var lastForeignChangeAt: UInt64 = 0
    private var lastKnownID: String?

    override init() {
        super.init()
        // System-wide broadcasts from the Text Input Sources service. `.deliverImmediately`
        // because a menu-bar agent is never the "active" app and would otherwise be throttled.
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(selectedSourceDidChange),
                           name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                           object: nil, suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(enabledSourcesDidChange),
                           name: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
                           object: nil, suspensionBehavior: .deliverImmediately)
        reload()
        lastKnownID = currentSourceID()
    }

    @objc private func enabledSourcesDidChange() {
        reload()
        onCurrentChanged?()
    }

    // MARK: Configuration

    /// Re-reads the enabled input sources. Cheap, but never called on the hot path.
    func reload() {
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceIsSelectCapable: true,
        ]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?
            .takeRetainedValue() as? [TISInputSource] else { return }

        let sources: [Source] = list.compactMap { ref in
            guard let id: String = Self.property(ref, kTISPropertyInputSourceID) else { return nil }
            let langs: [String] = Self.property(ref, kTISPropertyInputSourceLanguages) ?? []
            let type: String = Self.property(ref, kTISPropertyInputSourceType) ?? ""
            return Source(id: id,
                          name: Self.property(ref, kTISPropertyLocalizedName) ?? id,
                          language: langs.first ?? "",
                          isLayout: type == (kTISTypeKeyboardLayout as String),
                          ref: ref)
        }
        // Prefer plain keyboard layouts over input-method modes, keep system order otherwise.
        func ranked(_ lang: String) -> [Source] {
            let m = sources.filter { $0.language == lang || $0.language.hasPrefix(lang + "-") || $0.language.hasPrefix(lang + "_") }
            return m.filter(\.isLayout) + m.filter { !$0.isLayout }
        }
        englishCandidates = ranked("en")
        russianCandidates = ranked("ru")

        let d = UserDefaults.standard
        english = englishCandidates.first { $0.id == d.string(forKey: Settings.englishIDKey) } ?? englishCandidates.first
        russian = russianCandidates.first { $0.id == d.string(forKey: Settings.russianIDKey) } ?? russianCandidates.first
        log.info("sources reloaded: en=\(self.english?.id ?? "none", privacy: .public) ru=\(self.russian?.id ?? "none", privacy: .public)")
    }

    func choose(englishID: String) {
        UserDefaults.standard.set(englishID, forKey: Settings.englishIDKey); reload()
    }

    func choose(russianID: String) {
        UserDefaults.standard.set(russianID, forKey: Settings.russianIDKey); reload()
    }

    // MARK: Current source

    func currentSourceID() -> String? {
        guard let cur = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return Self.property(cur, kTISPropertyInputSourceID)
    }

    /// "EN", "RU", or a best-effort short label for any other source.
    func shortLabel(for id: String?) -> String {
        guard let id else { return "–" }
        if id == english?.id { return "EN" }
        if id == russian?.id { return "RU" }
        let all = englishCandidates + russianCandidates
        if let s = all.first(where: { $0.id == id }) { return s.language.prefix(2).uppercased() }
        return String(id.split(separator: ".").last?.prefix(2) ?? "?").uppercased()
    }

    /// Selects a specific known source (used by the benchmark to restore state).
    func select(id: String) {
        if let s = (englishCandidates + russianCandidates).first(where: { $0.id == id }) { TISSelectInputSource(s.ref) }
    }

    // MARK: Switching (hot path)

    /// Toggles RU ↔ EN. `detectedAt` is `mach_absolute_time()` from the event tap.
    /// Reads the live current source each time (≈ sub-ms) instead of a cached value, so
    /// rapid presses are always computed from the real state: no races, no drift.
    func toggle(detectedAt: UInt64) {
        guard let en = english, let ru = russian else {
            log.error("toggle ignored: English or Russian input source not enabled")
            return
        }
        let target = (currentSourceID() == en.id) ? ru : en
        var status = TISSelectInputSource(target.ref)
        if status != noErr {
            // Stale reference (source removed/re-added). Refresh once and retry.
            reload()
            if let fresh = (target.language == "ru" ? russian : english) {
                status = TISSelectInputSource(fresh.ref)
            }
        }
        let now = mach_absolute_time()

        guard status == noErr else {
            log.error("TISSelectInputSource failed: \(status)")
            return
        }
        stats.recordSelect(ns: Ticks.toNs(now &- detectedAt))
        pending = (target.id, detectedAt)
        lastOwnSwitchAt = now
        if lastForeignChangeAt != 0, Ticks.toNs(now &- lastForeignChangeAt) < duplicateWindowNs {
            noteDuplicate()
        }
        onCurrentChanged?()
    }

    @objc private func selectedSourceDidChange() {
        let now = mach_absolute_time()
        let id = currentSourceID()
        defer { lastKnownID = id; onCurrentChanged?() }

        if let p = pending, p.targetID == id {
            stats.recordConfirm(ns: Ticks.toNs(now &- p.detectedAt))
            pending = nil
            return
        }
        // macOS may broadcast the same selection more than once; that is not a change.
        guard id != lastKnownID else { return }

        // A real change we didn't make (menu bar, system Globe action, another app…).
        pending = nil
        lastForeignChangeAt = now
        if lastOwnSwitchAt != 0, Ticks.toNs(now &- lastOwnSwitchAt) < duplicateWindowNs {
            noteDuplicate()
        }
    }

    private func noteDuplicate() {
        duplicateCount += 1
        log.notice("duplicate input-source switch detected (#\(self.duplicateCount)); is the system Globe-key action still 'Change Input Source'?")
    }

    // MARK: Helpers

    private static func property<T>(_ source: TISInputSource, _ key: CFString) -> T? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as? T
    }
}

enum Ticks {
    private static let timebase: (UInt64, UInt64) = {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        return (UInt64(tb.numer), UInt64(tb.denom))
    }()
    static func toNs(_ ticks: UInt64) -> UInt64 { ticks * timebase.0 / timebase.1 }
}
