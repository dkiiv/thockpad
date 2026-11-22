// thockpad — the GUI: a window for tuning, and a menu bar item that keeps it alive.
//
// This is how thockpad is meant to be used: pick a click profile, set the level, hear it on the very next
// keystroke. The red close button does NOT quit — the window goes away, the Dock icon goes with it, and the
// app keeps clicking from the menu bar until you choose Exit there.
//
// Deliberately AppKit-only, no SwiftUI and no .xcodeproj: ./build.sh stays one swiftc call plus a bundle
// folder. The event tap is added to the main run loop, which NSApp.run() pumps — that is also what makes the
// tap deliver keys at all (see the note in runThockpad()).

import AppKit

// Held so the delegate is not released out from under NSApp.
var guiRetained: AnyObject?

func runGUI() -> Never {
    let app = NSApplication.shared
    let gui = GUIController()
    guiRetained = gui
    app.delegate = gui
    app.run()
    exit(0)
}

final class GUIController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!

    // Controls the engine settings bind to.
    var profilePopup: NSPopUpButton!
    var levelSlider: NSSlider!
    var levelLabel: NSTextField!
    var releaseCheck: NSButton!
    var talkCheck: NSButton!
    var swallowCheck: NSButton!
    var pauseCheck: NSButton!
    var statusLabel: NSTextField!
    var blurbLabel: NSTextField!
    var permButton: NSButton!
    var statsMenuItem: NSMenuItem!
    var profileMenuItems: [String: NSMenuItem] = [:]
    var levelMenuItems: [String: NSMenuItem] = [:]
    var pauseMenuItem: NSMenuItem!
    var releaseMenuItem: NSMenuItem!
    var talkMenuItem: NSMenuItem!

    var poll: Timer?

    /// Menu items and the "nearest" highlight share this.
    static let levels: [(String, Double)] = [("Quiet", 0.4), ("Medium", 0.65), ("Loud", 0.85), ("Maximum", 1.0)]

    // MARK: - Life cycle

    func applicationDidFinishLaunching(_ note: Notification) {
        loadSettings()
        NSApp.setActivationPolicy(.regular)     // Dock icon while the window is open
        buildStatusItem()
        buildWindow()
        showWindow(nil)

        motorProblem = motorCheck()
        // If macOS doesn't trust this app yet, ask properly: this shows the system prompt once and puts
        // Thockpad in the Input Monitoring list so it can be switched on. The window explains what to do.
        if !inputMonitoringGranted() {
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        }
        applySettingsToEngine()                 // start clicking if macOS already trusts us
        poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // Closing the window hides it and demotes the app to the menu bar; nothing else stops.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        window.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    // A second click on the Dock icon, or a re-open, brings the window back.
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow(nil) }
        return true
    }

    @objc func showWindow(_ sender: Any?) {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(sender)
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }

    // MARK: - Menu bar

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "thockpad")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "thockpad — your trackpad is a mechanical keyboard"
        }

        let menu = NSMenu()
        statsMenuItem = NSMenuItem(title: "thockpad", action: nil, keyEquivalent: "")
        statsMenuItem.isEnabled = false
        menu.addItem(statsMenuItem)
        menu.addItem(.separator())

        let profileMenu = NSMenu(title: "Click profile")
        for name in profileOrder {
            let item = NSMenuItem(title: name, action: #selector(pickProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.toolTip = profiles[name]?.blurb
            profileMenu.addItem(item)
            profileMenuItems[name] = item
        }
        let profilesItem = NSMenuItem(title: "Click profile", action: nil, keyEquivalent: "")
        profilesItem.submenu = profileMenu
        menu.addItem(profilesItem)

        let levels = NSMenu(title: "Level")
        for (label, value) in Self.levels {
            let item = NSMenuItem(title: label, action: #selector(pickLevel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            levels.addItem(item)
            levelMenuItems[label] = item
        }
        let levelsItem = NSMenuItem(title: "Level", action: nil, keyEquivalent: "")
        levelsItem.submenu = levels
        menu.addItem(levelsItem)
        menu.addItem(.separator())

        releaseMenuItem = toggleItem("Release “tock”", #selector(toggleRelease(_:)))
        menu.addItem(releaseMenuItem)
        talkMenuItem = toggleItem("Talk while typing", #selector(toggleTalk(_:)))
        menu.addItem(talkMenuItem)
        pauseMenuItem = toggleItem("Paused", #selector(togglePause(_:)))
        menu.addItem(pauseMenuItem)
        menu.addItem(.separator())

        menu.addItem(item("Open thockpad…", #selector(showWindow(_:))))
        menu.addItem(item("Restart thockpad", #selector(restartApp(_:))))
        menu.addItem(.separator())
        let quit = item("Exit thockpad", #selector(exitApp(_:)))
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(quit)

        statusItem.menu = menu
    }

    func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }
    func toggleItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = item(title, action)
        i.state = .off
        return i
    }

    // MARK: - Window

    func buildWindow() {
        let width: CGFloat = 420
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 420),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "thockpad"
        window.isReleasedWhenClosed = false
        window.delegate = self

        blurbLabel = label("", secondary: true)
        profilePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        profilePopup.addItems(withTitles: profileOrder)
        profilePopup.target = self
        profilePopup.action = #selector(pickProfilePopup(_:))

        levelSlider = NSSlider(value: Double(gain), minValue: 0.1, maxValue: 1.0,
                               target: self, action: #selector(slideLevel(_:)))
        levelLabel = label("", secondary: true)

        releaseCheck = check("Bottom-out “tock” on key release", #selector(toggleRelease(_:)))
        talkCheck = check("Talk: say a word on space (nospeaker)", #selector(toggleTalk(_:)))
        swallowCheck = check("Swallow my keystrokes (typing goes nowhere — testing)", #selector(toggleSwallow(_:)))
        pauseCheck = check("Paused", #selector(togglePause(_:)))

        let try_ = NSButton(title: "Try a click", target: self, action: #selector(tryClick(_:)))
        try_.bezelStyle = .rounded
        let settings = NSButton(title: "Open Input Monitoring…", target: self, action: #selector(openSettings(_:)))
        settings.bezelStyle = .rounded
        permButton = settings
        let quit = NSButton(title: "Exit thockpad", target: self, action: #selector(exitApp(_:)))
        quit.bezelStyle = .rounded

        statusLabel = label("", secondary: true)
        statusLabel.maximumNumberOfLines = 3

        let title = label("thockpad", secondary: false)
        title.font = .boldSystemFont(ofSize: 15)

        let stack = NSStackView(views: [
            title,
            blurbLabel,
            row("Click profile", profilePopup),
            row("Level", levelSlider, extra: levelLabel),
            releaseCheck,
            talkCheck,
            swallowCheck,
            pauseCheck,
            NSStackView(views: [try_, permButton]),
            statusLabel,
            quit,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            levelSlider.widthAnchor.constraint(equalToConstant: 200),
            profilePopup.widthAnchor.constraint(equalToConstant: 200),
        ])
        window.contentView = content
        window.center()
        refresh()
    }

    func label(_ s: String, secondary: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.textColor = secondary ? .secondaryLabelColor : .labelColor
        return l
    }
    func check(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: action)
        return b
    }
    func row(_ name: String, _ control: NSView, extra: NSTextField? = nil) -> NSStackView {
        let caption = NSTextField(labelWithString: name)
        caption.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        var views: [NSView] = [caption, control]
        if let extra { views.append(extra) }
        let r = NSStackView(views: views)
        r.orientation = .horizontal
        r.spacing = 10
        return r
    }

    // MARK: - Settings ↔ engine

    /// The engine reads its globals per keystroke, so assigning them here takes effect on the next key — no
    /// restart, and no lock is needed for a Float or a Bool.
    func applySettingsToEngine() {
        setProfile(profileName)
        throttleSeconds = 0.015
        if let problem = motorProblem {
            status(label: problem)
            return
        }
        openMotorIfNeeded()
        startClickWorkerIfNeeded()
        if inputMonitoringGranted() {
            if eventTap == nil { startClickWorkerIfNeeded(); _ = startTap() }
            status(label: tapRunning ? "Clicking — type on your Mac. Closing this window keeps it running in the menu bar."
                                     : "The keyboard tap wouldn’t open. Try Restart thockpad.")
        } else {
            status(label: "thockpad can’t hear your keyboard yet: allow it in Input Monitoring, then press "
                        + "“Restart thockpad” (a new grant only applies to a newly started process).")
        }
    }

    func persist() { saveSettings() }

    // MARK: - Actions

    @objc func pickProfilePopup(_ sender: NSPopUpButton) {
        setProfile(sender.titleOfSelectedItem ?? profileName)
        persist(); refresh()
    }
    @objc func pickProfile(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        setProfile(name); persist(); refresh()
    }
    @objc func pickLevel(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double { gain = Float(v); persist(); refresh() }
    }
    @objc func slideLevel(_ sender: NSSlider) { gain = Float(sender.doubleValue); persist() }
    @objc func toggleRelease(_ sender: Any?) { releaseOn.toggle(); persist(); refresh() }
    @objc func toggleTalk(_ sender: Any?) {
        talkEnabled.toggle(); persist()
        if talkEnabled { Thread { warmVoice(); DispatchQueue.main.async { [weak self] in self?.refresh() } }.start() }
        refresh()
    }
    @objc func toggleSwallow(_ sender: Any?) {
        swallowKeys.toggle()
        // listen-only vs filtering is a property of the tap itself: rebuild it.
        stopTap(); applySettingsToEngine(); persist(); refresh()
    }
    @objc func togglePause(_ sender: Any?) { paused.toggle(); persist(); refresh() }

    @objc func tryClick(_ sender: Any?) {
        enqueue(Click(tones: clickTones(for: spaceCode, at: now()), level: gain))
    }
    @objc func openSettings(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    @objc func restartApp(_ sender: Any?) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundleURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }
    @objc func exitApp(_ sender: Any?) { NSApp.terminate(nil) }

    func status(label s: String) { statusString = s }

    // MARK: - Refresh

    var statusString = ""
    var lastDown = 0

    /// Half-secondly: sync controls, menu checks, and the stats line. Cheap enough to leave running.
    func refresh() {
        statsLock.lock(); let s = stats; statsLock.unlock()
        let rate = s.active > 0 ? Double(s.down) / s.active : 0
        let state = paused ? "paused" : (tapRunning ? "clicking" : "not clicking")
        let line = "\(state) · \(profileName) · level \(String(format: "%.2f", gain)) · \(s.down) presses"
            + (s.throttled > 0 ? " · \(s.throttled) too fast" : "")
            + (rate > 0 ? String(format: " · %.1f keys/s", rate) : "")
        statsMenuItem.title = line

        profilePopup.selectItem(withTitle: profileName)
        blurbLabel.stringValue = currentProfile.blurb
        levelSlider.doubleValue = Double(gain)
        levelLabel.stringValue = String(format: "%.2f", gain)
        releaseCheck.state = releaseOn ? .on : .off
        talkCheck.state = talkEnabled ? .on : .off
        swallowCheck.state = swallowKeys ? .on : .off
        pauseCheck.state = paused ? .on : .off
        for (name, item) in profileMenuItems { item.state = name == profileName ? .on : .off }
        var nearest = Self.levels[0].0
        var best = Double.greatestFiniteMagnitude
        for (label, value) in Self.levels {
            let d = abs(value - Double(gain))
            if d < best { best = d; nearest = label }
        }
        for (label, item) in levelMenuItems { item.state = label == nearest ? .on : .off }
        releaseMenuItem.state = releaseOn ? .on : .off
        talkMenuItem.state = talkEnabled ? .on : .off
        pauseMenuItem.state = paused ? .on : .off
        statusItem.button?.appearsDisabled = paused
        if tapRunning {
            statusLabel.stringValue = "Clicking — type on your Mac. Closing this window keeps thockpad running in the menu bar."
        } else {
            statusLabel.stringValue = statusString.isEmpty ? "Not clicking yet." : statusString
        }
        // A grant can arrive while we run (it does on some macOS versions); notice it and start.
        if !tapRunning && motorProblem == nil && inputMonitoringGranted() { applySettingsToEngine() }
    }
}
