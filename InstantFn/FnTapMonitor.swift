import CoreGraphics
import Foundation

/// Detects a *standalone, short* press of the Fn/Globe key.
///
/// How it works:
/// - Uses a **listen-only** `CGEventTap` at session level. A listen-only tap can only
///   observe events. It cannot delay, change, drop or inject them, so InstantFn can
///   never block or corrupt keyboard input, even if it hangs or crashes. When the
///   process exits, the system removes the tap automatically.
/// - Listen-only keyboard taps need the **Input Monitoring** permission
///   (`CGPreflightListenEventAccess`). Accessibility is *not* needed, because
///   InstantFn never posts or modifies events.
/// - Fn is a modifier. Pressing/releasing it produces a `flagsChanged` event with
///   keycode `kVK_Function` (0x3F); the `maskSecondaryFn` bit tells up vs. down.
///   Note: macOS also sets `maskSecondaryFn` on arrow/F-row/Home/End *keyDown*
///   events even when Fn is not held, so the flag alone is NOT used to detect Fn.
/// - A "tap" fires on Fn **release**, only if, while Fn was held, no other key was
///   pressed, no other modifier changed, no mouse button was pressed, and it was
///   held for less than `maxTapDuration`. This keeps every Fn+key shortcut intact.
///
/// Privacy: the callback reads only the event *type*, the modifier flags and (for
/// modifier events) the keycode. It never reads characters and stores nothing.
///
/// Threading: the tap runs on its own high-priority thread with its own run loop, so
/// detection is never delayed by the main thread (e.g. while the menu is open).
/// All `fn*` state below is touched only on that thread.
final class FnTapMonitor {
    /// Called **on the tap thread** with `mach_absolute_time()` at the moment the
    /// qualifying Fn release was seen. Must return quickly.
    var onFnTap: ((UInt64) -> Void)?

    /// Max time Fn may be held and still count as a tap. A longer hold is treated as
    /// "user changed their mind" and does nothing.
    let maxTapDurationNs: UInt64 = 600_000_000

    // MARK: Tap-thread state (only touched on the tap thread)
    private var fnDown = false
    private var fnDownAt: UInt64 = 0
    private var tainted = false

    // MARK: Lifecycle state (main thread)
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var thread: Thread?
    private let runLoopLock = NSLock()
    private var tapRunLoop: CFRunLoop?   // guarded by runLoopLock

    /// Diagnostics: how many times macOS disabled the tap (timeout/user input).
    private(set) var reenableCount = 0

    var isRunning: Bool { port != nil }

    private static let kVK_Function: Int64 = 0x3F
    /// Some keyboards/OS versions also report the Globe key as keycode 179 (0xB3)
    /// key events. It is ignored rather than treated as "another key".
    private static let kVK_Globe: Int64 = 0xB3
    private static let otherModifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]

    private static let ticksToNs: (UInt64) -> UInt64 = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let numer = UInt64(tb.numer), denom = UInt64(tb.denom)
        return { $0 * numer / denom }
    }()

    // MARK: Start / stop

    /// Creates the tap. Returns false if macOS refused (usually: no Input Monitoring).
    @discardableResult
    func start() -> Bool {
        guard port == nil else { return true }

        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: fnTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        self.port = port
        self.source = source

        let thread = Thread { [weak self] in
            guard let self else { return }
            let rl = CFRunLoopGetCurrent()
            self.runLoopLock.lock(); self.tapRunLoop = rl; self.runLoopLock.unlock()
            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()   // returns when the port is invalidated or the loop is stopped
            self.runLoopLock.lock(); self.tapRunLoop = nil; self.runLoopLock.unlock()
        }
        thread.name = "InstantFn.EventTap"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        return true
    }

    func stop() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)   // also removes its run-loop source
        runLoopLock.lock(); let rl = tapRunLoop; runLoopLock.unlock()
        if let rl { CFRunLoopStop(rl) }
        self.port = nil
        self.source = nil
        self.thread = nil
    }

    /// Re-enables the tap if macOS disabled it, and clears any half-finished Fn press.
    /// Safe to call from the main thread (e.g. after wake).
    func revalidate() {
        if let port, !CGEvent.tapIsEnabled(tap: port) {
            CGEvent.tapEnable(tap: port, enable: true)
        }
        runOnTapThread { [weak self] in self?.resetState() }
    }

    private func runOnTapThread(_ block: @escaping () -> Void) {
        runLoopLock.lock(); let rl = tapRunLoop; runLoopLock.unlock()
        guard let rl else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(rl)
    }

    // MARK: Event handling (tap thread). Hot path: no allocation, no locks, no I/O.

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .flagsChanged:
            let flags = event.flags
            let fnNow = flags.contains(.maskSecondaryFn)
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)

            if keycode == Self.kVK_Function || keycode == Self.kVK_Globe {
                if fnNow {
                    if !fnDown {
                        fnDown = true
                        fnDownAt = mach_absolute_time()
                        // Shift/Ctrl/Opt/Cmd already held → this is a combo, not a plain Fn tap.
                        tainted = !flags.intersection(Self.otherModifiers).isEmpty
                    }
                } else if fnDown {
                    fnDown = false
                    let now = mach_absolute_time()
                    if !tainted,
                       flags.intersection(Self.otherModifiers).isEmpty,
                       Self.ticksToNs(now &- fnDownAt) <= maxTapDurationNs {
                        onFnTap?(now)
                    }
                }
            } else {
                // Another modifier (Shift, Ctrl, Opt, Cmd, Caps Lock…) changed while Fn was held.
                if fnDown { tainted = true }
                // Resync: if the Fn bit is clear, Fn is up, whatever we thought before.
                if !fnNow { fnDown = false }
            }

        case .keyDown:
            if event.getIntegerValueField(.keyboardEventKeycode) == Self.kVK_Globe { return }
            if fnDown {
                tainted = true   // Fn + key (F-keys, arrows, Fn+E, Fn+F, …): leave it to macOS
                // A keyDown *without* the Fn bit proves Fn is not physically held:
                // we missed the release (e.g. during sleep). Resync without firing.
                if !event.flags.contains(.maskSecondaryFn) { fnDown = false }
            }

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if fnDown { tainted = true }

        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // We may have missed events; never fire based on stale state.
            resetState()
            reenableCount += 1
            if let port { CGEvent.tapEnable(tap: port, enable: true) }

        default:
            break
        }
    }

    private func resetState() {
        fnDown = false
        tainted = false
    }
}

/// C-compatible tap callback. For a listen-only tap the return value is ignored by the
/// system, but we return the event unchanged anyway.
private func fnTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                           refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<FnTapMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
