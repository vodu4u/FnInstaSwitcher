import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let monitor = FnTapMonitor()
    private var switcher: InputSourceSwitcher!
    private var statusItem: NSStatusItem!
    private var globeConflict = false      // system would switch too → switching paused
    private var globeNotDoNothing = false  // Fn tap also triggers some other system action
    private var tapStartFailed = false
    private var ignoredForConflict = 0


    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        switcher = InputSourceSwitcher()
        switcher.onCurrentChanged = { [weak self] in self?.updateStatusTitle() }

        // Hot path: tap thread → main queue → TISSelectInputSource.
        monitor.onFnTap = { [weak self] detectedAt in
            DispatchQueue.main.async { self?.handleFnTap(detectedAt: detectedAt) }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        observeSystem()
        refreshGlobeConflict()

        if CommandLine.arguments.contains("--benchmark") { runBenchmark(); return }

        if !Permissions.inputMonitoringGranted { Permissions.requestInputMonitoring() }
        applyState()
        updateStatusTitle()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
    }

    private func handleFnTap(detectedAt: UInt64) {
        guard Settings.enabled else { return }
        guard !globeConflict else { ignoredForConflict += 1; return }
        switcher.selectNext(detectedAt: detectedAt)
    }

    /// Installs or removes the tap so it only exists while it's actually needed.
    private func applyState() {
        let wanted = Settings.enabled && Permissions.inputMonitoringGranted
        if wanted && !monitor.isRunning {
            tapStartFailed = !monitor.start()
        } else if !wanted && monitor.isRunning {
            monitor.stop()
        }
        if !wanted { tapStartFailed = false }
        updateStatusTitle()
    }

    private func refreshGlobeConflict() {
        globeConflict = GlobeKeySetting.conflictsWithInstantFn
        globeNotDoNothing = GlobeKeySetting.needsDoNothing
        updateStatusTitle()
    }

    // MARK: System events (event-driven, no polling)

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.screensDidWakeNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recoverAfterSystemEvent() }
            }
        }
        // The user may have just changed a setting in System Settings: re-check when they leave it.
        ws.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.apple.systempreferences" else { return }
            MainActor.assumeIsolated {
                self?.refreshGlobeConflict()
                self?.applyState()
            }
        }
    }

    private func recoverAfterSystemEvent() {
        monitor.revalidate()   // re-enable tap if needed, drop any half-finished Fn press
        switcher.reload()      // input-source refs may have changed
        applyState()
        refreshGlobeConflict()
    }

    // MARK: Status item

    private func updateStatusTitle() {
        guard let button = statusItem?.button else { return }
        let label = switcher.shortLabel(for: switcher.currentSourceID())
        let problem = globeNotDoNothing || tapStartFailed
            || (Settings.enabled && !Permissions.inputMonitoringGranted)
        button.title = problem ? "\(label) ⚠︎" : label
        button.appearsDisabled = !Settings.enabled
        button.toolTip = problem ? "InstantFn needs attention — open the menu" : "InstantFn"
    }

    // MARK: Menu
    //
    // Layout (rebuilt each time the menu opens; it's tiny):
    //
    //   ⚠︎ <problem>…                 ← only when something needs fixing
    //   ─────
    //   INPUT SOURCES                 ← the order Fn cycles through; ✓ = current
    //   ✓ U.S.
    //     Russian
    //   ─────
    //   ✓ Switch on Fn                ← master on/off
    //   ✓ Launch at Login
    //   ─────
    //   Advanced ▸                    ← status details, settings shortcuts, restore
    //   Quit InstantFn          ⌘Q

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        refreshGlobeConflict()
        applyState()   // picks up a permission granted since last time
        menu.removeAllItems()

        // 1. Problems, only if any.
        let problems = currentProblems()
        for (title, sel) in problems {
            let i = item(title, sel)
            i.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")?
                .withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
            menu.addItem(i)
        }
        if !problems.isEmpty { menu.addItem(.separator()) }

        // 2. Input sources.
        menu.addItem(header("Input Sources"))
        let curID = switcher.currentSourceID()
        if switcher.sources.count < 2 {
            menu.addItem(item("Add a Second Input Source…", #selector(openKeyboardSettings)))
        }
        for src in switcher.sources {
            let i = item(src.name, #selector(selectSource(_:)))
            i.representedObject = src.id
            i.state = src.id == curID ? .on : .off
            menu.addItem(i)
        }
        menu.addItem(.separator())

        // 3. Toggles.
        let fn = item("Switch on Fn", #selector(toggleEnabled))
        fn.state = Settings.enabled ? .on : .off
        menu.addItem(fn)
        let login = item(LoginItem.status == .requiresApproval ? "Launch at Login (Needs Approval)" : "Launch at Login",
                         #selector(toggleLogin))
        login.state = LoginItem.status == .enabled ? .on : (LoginItem.status == .requiresApproval ? .mixed : .off)
        menu.addItem(login)
        menu.addItem(.separator())

        // 4. Advanced + Quit.
        let advanced = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
        advanced.submenu = advancedMenu()
        menu.addItem(advanced)
        menu.addItem(item("Quit InstantFn", #selector(quit), key: "q"))
    }

    /// Things the user must fix for Fn switching to work, as (title, action).
    private func currentProblems() -> [(String, Selector)] {
        guard Settings.enabled else { return [] }
        var p: [(String, Selector)] = []
        if !Permissions.inputMonitoringGranted {
            p.append(("Allow Input Monitoring…", #selector(requestInputMonitoring)))
        } else if tapStartFailed {
            p.append(("Reopen InstantFn to Finish Setup", #selector(quit)))
        }
        if globeNotDoNothing {
            p.append(("Set “Press 🌐 key to” to “Do Nothing”…", #selector(openKeyboardSettings)))
        }
        return p
    }

    private func advancedMenu() -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false

        sub.addItem(header("Status"))
        let im = info(Permissions.inputMonitoringGranted ? "Input Monitoring: Allowed" : "Input Monitoring: Not Allowed")
        im.toolTip = "Needed only to see Fn press and release. InstantFn never reads characters, never stores keystrokes, and cannot block or change input (listen-only). Accessibility is not used."
        sub.addItem(im)
        sub.addItem(info("🌐 Key Action: \(GlobeKeySetting.read()?.title ?? "System Default")"))
        sub.addItem(.separator())
        sub.addItem(item("Keyboard Settings…", #selector(openKeyboardSettings)))
        sub.addItem(item("Input Monitoring Settings…", #selector(openInputMonitoringSettings)))
        #if DEBUG
        sub.addItem(.separator())
        sub.addItem(header("Diagnostics"))
        sub.addItem(info("Fn→select: " + LatencyStats.summary(switcher.stats.select)))
        sub.addItem(info("Fn→confirmed: " + LatencyStats.summary(switcher.stats.confirm)))
        sub.addItem(info("Duplicates \(switcher.duplicateCount) · ignored \(ignoredForConflict) · tap re-enabled \(monitor.reenableCount)"))
        #endif
        sub.addItem(.separator())
        sub.addItem(item("Restore Standard macOS Behavior…", #selector(restoreStandard)))
        return sub
    }

    private func item(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    private func info(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        return info(title)
    }

    // MARK: Actions

    @objc private func toggleEnabled() { Settings.enabled.toggle(); applyState() }
    @objc private func toggleLogin() { LoginItem.set(!LoginItem.isOn) }
    @objc private func requestInputMonitoring() { Permissions.requestInputMonitoring() }
    @objc private func openInputMonitoringSettings() { Permissions.openInputMonitoringSettings() }
    @objc private func openKeyboardSettings() { GlobeKeySetting.openKeyboardSettings() }
    @objc private func selectSource(_ s: NSMenuItem) { if let id = s.representedObject as? String { switcher.select(id: id); updateStatusTitle() } }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func restoreStandard() {
        Settings.enabled = false
        applyState()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "InstantFn is disabled"
        alert.informativeText = """
        The event tap has been removed; InstantFn no longer observes the keyboard.

        To get the standard macOS Globe behavior back, open Keyboard Settings and set \
        “Press 🌐 key to” to “Change Input Source”. You can also turn off Launch at Login \
        and remove InstantFn from Privacy & Security → Input Monitoring.
        """
        alert.addButton(withTitle: "Open Keyboard Settings")
        alert.addButton(withTitle: "Done")
        if alert.runModal() == .alertFirstButtonReturn { GlobeKeySetting.openKeyboardSettings() }
    }

    // MARK: Benchmark (development aid)

    /// `InstantFn --benchmark`: exercises the exact production path (background thread
    /// timestamp → main queue → selectNext) 40 times without needing a physical Fn press,
    /// prints the measured latencies, restores the original input source and quits.
    private func runBenchmark() {
        let original = switcher.currentSourceID()
        let rounds = 40
        var i = 0
        func step() {
            if i == rounds {
                print("select:  " + LatencyStats.summary(switcher.stats.select))
                print("confirm: " + LatencyStats.summary(switcher.stats.confirm))
                print("duplicates: \(switcher.duplicateCount)")
                if let original { switcher.select(id: original) }
                fflush(stdout)
                NSApp.terminate(nil)
                return
            }
            i += 1
            DispatchQueue.global(qos: .userInteractive).async {
                let t0 = mach_absolute_time()
                DispatchQueue.main.async { self.switcher.selectNext(detectedAt: t0) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { step() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { step() }
    }
}
