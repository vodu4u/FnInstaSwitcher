import Carbon
import Foundation
import os

/// Switches to the *next* enabled keyboard input source with `TISSelectInputSource`,
/// cycling through everything the user enabled in Keyboard Settings, in system order
/// (EN → RU → ES → EN …). With two sources this is a plain toggle. No keystrokes are
/// injected.
///
/// Everything here runs on the main thread: recent macOS versions assert when TSM/TIS
/// is called from a background thread.
@MainActor
final class InputSourceSwitcher: NSObject {
    struct Source {
        let id: String          // e.g. "com.apple.keylayout.US", "com.apple.keylayout.Russian"
        let name: String        // localized name, e.g. "U.S.", "Russian"
        let language: String    // primary language code, e.g. "en", "ru"
        let ref: TISInputSource
    }

    /// Enabled, selectable keyboard input sources in system order. Rebuilt only when the
    /// configuration changes, never on the hot path.
    private(set) var sources: [Source] = []

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

        sources = list.compactMap { ref in
            guard let id: String = Self.property(ref, kTISPropertyInputSourceID) else { return nil }
            let langs: [String] = Self.property(ref, kTISPropertyInputSourceLanguages) ?? []
            return Source(id: id,
                          name: Self.property(ref, kTISPropertyLocalizedName) ?? id,
                          language: langs.first ?? "",
                          ref: ref)
        }
        log.info("sources reloaded: \(self.sources.map(\.id).joined(separator: ", "), privacy: .public)")
    }

    // MARK: Current source

    func currentSourceID() -> String? {
        guard let cur = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return Self.property(cur, kTISPropertyInputSourceID)
    }

    /// Short menu-bar label from the source's language: "EN", "RU", "ES", …
    func shortLabel(for id: String?) -> String {
        guard let id else { return "–" }
        if let s = sources.first(where: { $0.id == id }), !s.language.isEmpty {
            return s.language.prefix(2).uppercased()
        }
        return String(id.split(separator: ".").last?.prefix(2) ?? "?").uppercased()
    }

    func name(for id: String?) -> String? { sources.first { $0.id == id }?.name }

    /// Selects a specific known source (used by the benchmark to restore state).
    func select(id: String) {
        if let s = sources.first(where: { $0.id == id }) { TISSelectInputSource(s.ref) }
    }

    // MARK: Switching (hot path)

    /// Selects the next enabled input source. `detectedAt` is `mach_absolute_time()`
    /// from the event tap. Reads the live current source each time (≈ sub-ms) instead of
    /// a cached value, so rapid presses are always computed from the real state.
    /// Returns the ID of the newly selected source, or nil if nothing was switched.
    @discardableResult
    func selectNext(detectedAt: UInt64) -> String? {
        guard sources.count >= 2 else {
            log.error("switch ignored: fewer than two input sources enabled")
            return nil
        }
        let current = currentSourceID()
        let index = sources.firstIndex { $0.id == current } ?? -1   // unknown → first source
        let target = sources[(index + 1) % sources.count]

        var status = TISSelectInputSource(target.ref)
        if status != noErr {
            // Stale reference (source removed/re-added). Refresh once and retry by ID.
            reload()
            if let fresh = sources.first(where: { $0.id == target.id }) {
                status = TISSelectInputSource(fresh.ref)
            }
        }
        let now = mach_absolute_time()

        guard status == noErr else {
            log.error("TISSelectInputSource failed: \(status)")
            return nil
        }
        stats.recordSelect(ns: Ticks.toNs(now &- detectedAt))
        pending = (target.id, detectedAt)
        lastOwnSwitchAt = now
        if lastForeignChangeAt != 0, Ticks.toNs(now &- lastForeignChangeAt) < duplicateWindowNs {
            noteDuplicate()
        }
        onCurrentChanged?()
        return target.id
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
