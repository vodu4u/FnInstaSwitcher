import AppKit
import ApplicationServices
import os

private let log = Logger(subsystem: "InstantFn", category: "cursor")

/// Optional language bubble shown next to the text cursor after an Fn switch.
///
/// macOS's own bubble often shows the *previous* language when another app switches the
/// input source, so InstantFn can draw its own. Finding the text cursor in another app
/// requires Accessibility, so this feature is off by default and asks for the
/// permission only when the user turns it on. It reads only the focused element's
/// selection range and the on-screen bounds of that range — never the text itself.
@MainActor
final class CursorIndicator {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt (first time) and opens the Accessibility pane.
    static func requestAccess() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) { openAccessibilitySettings() }
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private let panel: NSPanel
    private let bubble = BubbleView()
    private var generation = 0
    /// AX queries go to another process and can block, so they never run on the main thread.
    private let axQueue = DispatchQueue(label: "InstantFn.caret", qos: .userInteractive)

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .transient]
        panel.hidesOnDeactivate = false
        panel.contentView = bubble
    }

    /// Looks up the caret off the main thread, then shows `label` under it.
    /// If the caret can't be found (some apps don't expose it), nothing is shown.
    func show(label: String) {
        guard Self.isTrusted else { log.info("bubble skipped: Accessibility not allowed"); return }
        generation += 1
        let gen = generation
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        axQueue.async {
            let caret = CaretLocator.caretRect(frontmostPID: pid)
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
                guard let caret else { log.info("bubble skipped: caret not found"); return }
                self.present(label: label, caret: caret, pid: pid, generation: gen)
            }
        }
    }

    private func present(label: String, caret: CGRect, pid: pid_t?, generation gen: Int) {
        bubble.label = label
        let size = bubble.fittingSize
        // Where macOS puts its own bubble: centered on the caret's x, ~33 pt below the
        // caret's top (measured). Tracking below snaps to the exact spot if it differs.
        place(center: CGPoint(x: caret.minX, y: caret.minY + 33.5), size: size)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        track(pid: pid, caret: caret, generation: gen, started: Date(), systemSeen: false)
    }

    /// macOS draws its own bubble (with the *previous* language) inside the focused app
    /// ~25 ms after the switch. We sit exactly on top of it and stay until it's gone.
    /// Only window *bounds* are read, which needs no permission; nothing is captured.
    private func track(pid: pid_t?, caret: CGRect, generation gen: Int, started: Date, systemSeen: Bool) {
        guard gen == generation else { return }
        let elapsed = -started.timeIntervalSinceNow
        let system = pid.flatMap { Self.systemBubbleFrame(pid: $0, near: caret) }
        if let system {
            if !systemSeen { log.info("system bubble \(system.debugDescription, privacy: .public) caret \(caret.debugDescription, privacy: .public)") }
            // The system window is the pill plus an even shadow margin, so its center is the pill's.
            place(center: CGPoint(x: system.midX, y: system.midY), size: panel.frame.size)
        }
        let seen = systemSeen || system != nil
        let finished = seen ? system == nil : elapsed > 1.2   // no system bubble: show ours 1.2 s
        if finished || elapsed > 4 { fadeOut(gen); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (seen ? 0.05 : 0.01)) { [weak self] in
            self?.track(pid: pid, caret: caret, generation: gen, started: started, systemSeen: seen)
        }
    }

    /// `center` is in AX / window-list coordinates (top-left origin of the primary screen).
    private func place(center c: CGPoint, size: NSSize) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var origin = NSPoint(x: (c.x - size.width / 2).rounded(), y: (primaryHeight - c.y - size.height / 2).rounded())
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: c.x, y: primaryHeight - c.y)) }) {
            let v = screen.visibleFrame
            origin.x = min(max(origin.x, v.minX), v.maxX - size.width)
            origin.y = min(max(origin.y, v.minY), v.maxY - size.height)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func fadeOut(_ gen: Int) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { if gen == self.generation { self.panel.orderOut(nil) } }
        })
    }

    /// The small window the focused app shows for the macOS language bubble, if any.
    private static func systemBubbleFrame(pid: pid_t, near caret: CGRect) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid && ((w[kCGWindowLayer as String] as? Int) ?? 0) > 0 {
            guard let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary),
                  r.width < 200, r.height < 150,
                  abs(r.midX - caret.minX) < 120, abs(r.midY - caret.maxY) < 120 else { continue }
            return r
        }
        return nil
    }
}

/// Accent-colored pill with the language code, styled like the system bubble.
private final class BubbleView: NSView {
    var label = "" { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
    private let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private var attrs: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: NSColor.white] }

    override var intrinsicContentSize: NSSize {
        let w = (label as NSString).size(withAttributes: attrs).width
        // Just larger than the macOS bubble (≈30×23 pt) so it fully covers it.
        return NSSize(width: max(ceil(w) + 16, 32), height: 24)
    }
    override var fittingSize: NSSize { intrinsicContentSize }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let s = (label as NSString).size(withAttributes: attrs)
        (label as NSString).draw(at: NSPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2), withAttributes: attrs)
    }
}

/// Finds the on-screen rectangle of the text cursor in the focused app (AX coordinates).
enum CaretLocator {
    private static var electronEnabled = Set<pid_t>()

    /// Call only from one serial queue.
    static func caretRect(frontmostPID: pid_t?) -> CGRect? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        guard let f = attribute(system, kAXFocusedUIElementAttribute), CFGetTypeID(f) == AXUIElementGetTypeID() else {
            log.info("caret: no focused element (pid \(frontmostPID ?? -1, privacy: .public))")
            enableElectronAccessibility(frontmostPID)
            return nil
        }
        let focused = f as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, 0.1)
        let role = attribute(focused, kAXRoleAttribute) as? String ?? "?"
        var range = CFRange()
        guard let rv = attribute(focused, kAXSelectedTextRangeAttribute), CFGetTypeID(rv) == AXValueGetTypeID(),
              AXValueGetValue(rv as! AXValue, .cfRange, &range) else {
            log.info("caret: \(role, privacy: .public) has no selected text range")
            enableElectronAccessibility(frontmostPID)
            return nil
        }

        // Zero-length ranges give an empty rect in many apps; fall back to the
        // character after, then before, the insertion point.
        if let r = bounds(focused, CFRange(location: range.location, length: 0)) { return r }
        if let r = bounds(focused, CFRange(location: range.location, length: 1)) {
            return CGRect(x: r.minX, y: r.minY, width: 0, height: r.height)
        }
        if range.location > 0, let r = bounds(focused, CFRange(location: range.location - 1, length: 1)) {
            return CGRect(x: r.maxX, y: r.minY, width: 0, height: r.height)
        }
        // WebKit / Chromium / Electron expose the caret through text markers instead.
        if let r = markerBounds(focused) { return r }
        // Last resort: the start of the focused field (e.g. empty fields have no glyph to measure).
        if let frame = elementFrame(focused) {
            log.info("caret: \(role, privacy: .public) range \(range.location, privacy: .public)+\(range.length, privacy: .public) no bounds; using field frame")
            let line = min(frame.height, 20)
            return CGRect(x: frame.minX + 6, y: frame.minY + max(0, (min(frame.height, 36) - line) / 2), width: 0, height: line)
        }
        log.info("caret: \(role, privacy: .public) range \(range.location, privacy: .public)+\(range.length, privacy: .public) has no bounds")
        return nil
    }

    private static func bounds(_ el: AXUIElement, _ range: CFRange) -> CGRect? {
        var r = range
        guard let param = AXValueCreate(.cfRange, &r) else { return nil }
        return rect(el, kAXBoundsForRangeParameterizedAttribute, param)
    }

    private static func markerBounds(_ el: AXUIElement) -> CGRect? {
        guard let marker = attribute(el, "AXSelectedTextMarkerRange") else {
            log.info("caret: no AXSelectedTextMarkerRange")
            return nil
        }
        return rect(el, "AXBoundsForTextMarkerRange", marker)
    }

    private static func rect(_ el: AXUIElement, _ attr: String, _ param: CFTypeRef) -> CGRect? {
        var out: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(el, attr as CFString, param, &out)
        guard err == .success, let v = out, CFGetTypeID(v) == AXValueGetTypeID() else {
            log.info("caret: \(attr, privacy: .public) error \(err.rawValue, privacy: .public)")
            return nil
        }
        var rect = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &rect), rect.height > 0, rect.height < 400 else {
            log.info("caret: \(attr, privacy: .public) gave \(rect.debugDescription, privacy: .public)")
            return nil
        }
        return rect
    }

    private static func elementFrame(_ el: AXUIElement) -> CGRect? {
        var pos = CGPoint.zero, size = CGSize.zero
        guard let p = attribute(el, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              AXValueGetValue(p as! AXValue, .cgPoint, &pos),
              let z = attribute(el, kAXSizeAttribute), CFGetTypeID(z) == AXValueGetTypeID(),
              AXValueGetValue(z as! AXValue, .cgSize, &size), size.height > 0 else { return nil }
        return CGRect(origin: pos, size: size)
    }

    /// Electron apps (Slack, VS Code, Claude…) build their accessibility tree only when
    /// asked via `AXManualAccessibility`. Done once per app, and only for the frontmost app.
    private static func enableElectronAccessibility(_ pid: pid_t?) {
        guard let pid, !electronEnabled.contains(pid) else { return }
        electronEnabled.insert(pid)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private static func attribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var out: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &out) == .success ? out : nil
    }
}
