// thockpad — the GUI: a window for tuning, and a menu bar item that keeps it alive.
//
// This is how thockpad is meant to be used: pick a click profile, set the level, hear it on the very next
// keystroke. The red close button does NOT quit — the window goes away, the Dock icon goes with it, and the
// app keeps clicking from the menu bar until you choose Exit there.
//
// Deliberately AppKit-only, no SwiftUI and no .xcodeproj: ./build.sh stays one swiftc call plus a bundle
// folder. Nothing here asks macOS for anything: key-state polling needs no permission, so there is no
// grant dance, no "Restart after allowing" button, no status text about System Settings. Open it and type.

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
    var pauseCheck: NSButton!
    var statusLabel: NSTextField!
    var blurbLabel: NSTextField!
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

        startEngine()
        poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    /// Open the motor and start listening. Idempotent — safe to call again if the first attempt failed
    /// (sleep/wake, trackpad unplug/replug).
    func startEngine() {
        if motorProblem == nil { openMotorIfNeeded() }
        if motorProblem == nil {
            startClickWorkerIfNeeded()
            startListeningIfNeeded()
            Thread { warmVoice() }.start()   // synthesise the talk words off the main thread
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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 380),
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
        pauseCheck = check("Paused", #selector(togglePause(_:)))

        let try_ = NSButton(title: "Try a click", target: self, action: #selector(tryClick(_:)))
        try_.bezelStyle = .rounded

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
            pauseCheck,
            try_,
            statusLabel,
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
    @objc func togglePause(_ sender: Any?) { paused.toggle(); persist(); refresh() }

    @objc func tryClick(_ sender: Any?) {
        enqueue(Click(tones: clickTones(for: spaceCode, at: now()), level: gain, at: now()))
    }
    @objc func restartApp(_ sender: Any?) {
        // Relaunch this same bundle — but only after this process is gone, so the new instance can never
        // stack on top of the old one (two pollers = every key thocks twice) and can never see the old one
        // still running and refuse to start. `open -n` used to force exactly that overlap.
        let wait = "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.05; done; /usr/bin/open '\(Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "'\\''"))'"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", wait]
        try? task.run()
        NSApp.terminate(nil)
    }
    @objc func exitApp(_ sender: Any?) { NSApp.terminate(nil) }

    // MARK: - Refresh

    var lastDown = 0

    /// Half-secondly: sync controls, menu checks, and the stats line. Cheap enough to leave running.
    func refresh() {
        applySettingsToEngine()
        statsLock.lock(); let s = stats; statsLock.unlock()
        let rate = s.active > 0 ? Double(s.down) / s.active : 0
        let state = paused ? "paused" : (listening ? "listening" : "not listening")
        let health = pollHealth()
        let line = "\(state) · \(profileName) · level \(String(format: "%.2f", gain)) · \(s.heard) keys heard"
            + (s.throttled > 0 ? " · \(s.throttled) motor-busy" : "")
            + (health.worst > pollStallSeconds ? String(format: " · ⚠ poll stalled %.0f ms", health.worst * 1000) : "")
            + (rate > 0 ? String(format: " · %.1f keys/s", rate) : "")
        statsMenuItem.title = line

        profilePopup.selectItem(withTitle: profileName)
        blurbLabel.stringValue = currentProfile.blurb
        levelSlider.doubleValue = Double(gain)
        levelLabel.stringValue = String(format: "%.2f", gain)
        releaseCheck.state = releaseOn ? .on : .off
        talkCheck.state = talkEnabled ? .on : .off
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

        if let problem = motorProblem {
            statusLabel.stringValue = problem + "  (Fix it and press Restart thockpad.)"
            startEngine()          // retry: cheap, and heals sleep/wake and replug
        } else if s.heard > 0 {
            statusLabel.stringValue = "Clicking — heard \(s.heard) keystrokes (\(s.down) clicked\(s.throttled > 0 ? ", \(s.throttled) motor-busy" : "")), last was “\(s.lastKey)”. "
                + "Closing this window keeps thockpad running in the menu bar."
        } else {
            statusLabel.stringValue = "Clicking — type on your Mac and the trackpad thocks. "
                + "Closing this window keeps thockpad running in the menu bar."
        }
        lastDown = s.down
    }
}
