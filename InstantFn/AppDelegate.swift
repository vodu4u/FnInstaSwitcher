import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let monitor = FnTapMonitor()
    private var switcher: InputSourceSwitcher!
    private var statusItem: NSStatusItem!
    private var globeConflict = false
    private var tapStartFailed = false
    private var ignoredForConflict = 0

    // Menu items updated in menuNeedsUpdate.
    private let enabledItem = NSMenuItem()
    private let currentItem = NSMenuItem()
    private let switchOnFnItem = NSMenuItem()
    private let englishItem = NSMenuItem()
    private let russianItem = NSMenuItem()
    private let loginItem = NSMenuItem()
    private let permissionsItem = NSMenuItem()
    #if DEBUG
    private let diagSelectItem = NSMenuItem()
    private let diagConfirmItem = NSMenuItem()
    private let diagOtherItem = NSMenuItem()
    #endif

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
        statusItem.menu = buildMenu()

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
        guard Settings.enabled, Settings.switchOnFn else { return }
        guard !globeConflict else { ignoredForConflict += 1; return }
        switcher.toggle(detectedAt: detectedAt)
    }

    /// Installs or removes the tap so it only exists while it's actually needed.
    private func applyState() {
        let wanted = Settings.enabled && Settings.switchOnFn && Permissions.inputMonitoringGranted
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
        let problem = globeConflict || tapStartFailed
            || (Settings.enabled && Settings.switchOnFn && !Permissions.inputMonitoringGranted)
        button.title = problem ? "\(label) ⚠︎" : label
        button.appearsDisabled = !(Settings.enabled && Settings.switchOnFn)
        button.toolTip = problem ? "InstantFn needs attention — open the menu" : "InstantFn"
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        func action(_ item: NSMenuItem, _ sel: Selector) -> NSMenuItem {
            item.target = self; item.action = sel; return item
        }
        menu.addItem(action(enabledItem, #selector(toggleEnabled)))
        currentItem.isEnabled = false
        menu.addItem(currentItem)
        menu.addItem(action(switchOnFnItem, #selector(toggleSwitchOnFn)))
        menu.addItem(.separator())
        englishItem.submenu = NSMenu(); menu.addItem(englishItem)
        russianItem.submenu = NSMenu(); menu.addItem(russianItem)
        menu.addItem(.separator())
        menu.addItem(action(loginItem, #selector(toggleLogin)))
        permissionsItem.title = "Permissions Status"
        permissionsItem.submenu = NSMenu()
        menu.addItem(permissionsItem)
        #if DEBUG
        menu.addItem(.separator())
        for item in [diagSelectItem, diagConfirmItem, diagOtherItem] { item.isEnabled = false; menu.addItem(item) }
        #endif
        menu.addItem(.separator())
        menu.addItem(action(NSMenuItem(title: "Restore Standard macOS Behavior…", action: nil, keyEquivalent: ""),
                            #selector(restoreStandard)))
        menu.addItem(action(NSMenuItem(title: "Quit InstantFn", action: nil, keyEquivalent: "q"), #selector(quit)))
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        refreshGlobeConflict()
        applyState()   // picks up a permission granted since last time

        enabledItem.title = "InstantFn — \(Settings.enabled ? "Enabled" : "Disabled")"
        enabledItem.state = Settings.enabled ? .on : .off

        let curID = switcher.currentSourceID()
        currentItem.title = "Current Input Source: \(switcher.shortLabel(for: curID))"

        switchOnFnItem.title = "Switch on Fn: \(Settings.switchOnFn ? "ON" : "OFF")"
        switchOnFnItem.state = Settings.switchOnFn ? .on : .off
        switchOnFnItem.isEnabled = Settings.enabled

        fillSourceMenu(englishItem, label: "English", chosen: switcher.english, candidates: switcher.englishCandidates, sel: #selector(chooseEnglish(_:)))
        fillSourceMenu(russianItem, label: "Russian", chosen: switcher.russian, candidates: switcher.russianCandidates, sel: #selector(chooseRussian(_:)))

        switch LoginItem.status {
        case .enabled: loginItem.title = "Launch at Login: ON"; loginItem.state = .on
        case .requiresApproval: loginItem.title = "Launch at Login: needs approval in Login Items"; loginItem.state = .mixed
        default: loginItem.title = "Launch at Login: OFF"; loginItem.state = .off
        }

        fillPermissionsMenu(permissionsItem.submenu!)

        #if DEBUG
        diagSelectItem.title = "Fn→select: " + LatencyStats.summary(switcher.stats.select)
        diagConfirmItem.title = "Fn→confirmed: " + LatencyStats.summary(switcher.stats.confirm)
        diagOtherItem.title = "Duplicates: \(switcher.duplicateCount) · ignored (Globe conflict): \(ignoredForConflict) · tap re-enabled: \(monitor.reenableCount)"
        #endif
    }

    private func fillSourceMenu(_ item: NSMenuItem, label: String, chosen: InputSourceSwitcher.Source?,
                                candidates: [InputSourceSwitcher.Source], sel: Selector) {
        item.title = "\(label) source: \(chosen?.name ?? "not found — add it in Keyboard Settings")"
        let sub = item.submenu!
        sub.removeAllItems()
        for c in candidates {
            let i = NSMenuItem(title: "\(c.name)  (\(c.id))", action: sel, keyEquivalent: "")
            i.target = self; i.representedObject = c.id
            i.state = (c.id == chosen?.id) ? .on : .off
            sub.addItem(i)
        }
        if candidates.isEmpty {
            let i = NSMenuItem(title: "Open Keyboard Settings…", action: #selector(openKeyboardSettings), keyEquivalent: "")
            i.target = self; sub.addItem(i)
        }
    }

    private func fillPermissionsMenu(_ sub: NSMenu) {
        sub.removeAllItems()
        func info(_ t: String) { let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false; sub.addItem(i) }
        func button(_ t: String, _ s: Selector) { let i = NSMenuItem(title: t, action: s, keyEquivalent: ""); i.target = self; sub.addItem(i) }

        if Permissions.inputMonitoringGranted {
            info(tapStartFailed ? "Input Monitoring: granted, but the event tap failed — quit and reopen InstantFn"
                                : "Input Monitoring: Granted ✓")
        } else {
            button("Input Monitoring: NOT granted — Grant Access…", #selector(requestInputMonitoring))
        }
        info("   Needed only to see Fn press/release. InstantFn never reads characters,")
        info("   never stores keystrokes, and cannot block or change input (listen-only).")
        info("Accessibility: not required ✓")
        sub.addItem(.separator())
        let globe = GlobeKeySetting.read()
        if globe == .changeInputSource {
            button("System “Press 🌐 key to”: Change Input Source ⚠︎ — set to “Do Nothing”…", #selector(openKeyboardSettings))
            info("   Switching is paused until then, to avoid double switching.")
        } else {
            info("System “Press 🌐 key to”: \(globe?.title ?? "not set (system default)") ✓")
        }
        sub.addItem(.separator())
        button("Open Input Monitoring Settings…", #selector(openInputMonitoringSettings))
        button("Open Keyboard Settings…", #selector(openKeyboardSettings))
    }

    // MARK: Actions

    @objc private func toggleEnabled() { Settings.enabled.toggle(); applyState() }
    @objc private func toggleSwitchOnFn() { Settings.switchOnFn.toggle(); applyState() }
    @objc private func toggleLogin() { LoginItem.set(!LoginItem.isOn) }
    @objc private func requestInputMonitoring() { Permissions.requestInputMonitoring() }
    @objc private func openInputMonitoringSettings() { Permissions.openInputMonitoringSettings() }
    @objc private func openKeyboardSettings() { GlobeKeySetting.openKeyboardSettings() }
    @objc private func chooseEnglish(_ s: NSMenuItem) { if let id = s.representedObject as? String { switcher.choose(englishID: id); updateStatusTitle() } }
    @objc private func chooseRussian(_ s: NSMenuItem) { if let id = s.representedObject as? String { switcher.choose(russianID: id); updateStatusTitle() } }
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
    /// timestamp → main queue → toggle) 40 times without needing a physical Fn press,
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
                DispatchQueue.main.async { self.switcher.toggle(detectedAt: t0) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { step() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { step() }
    }
}
