// thockpad — listening to the keyboard, and the click worker behind it.
//
// A CGEventTap watches key down/up events. The callback does as little as possible (timestamp, shape the
// tones, push them onto a queue) and a single worker thread plays them, so typing latency never depends on
// the motor. With --swallow the callback returns nil instead of the event, so the Mac never sees the key;
// without it (the default) events pass through untouched and thockpad only adds sound.
//
// Needs Input Monitoring (Accessibility): macOS prompts on first run, and a fresh grant only applies to a
// newly started process.
//
// The GUI drives the same functions (startTap/stopTap/motorCheck); runThockpad() is the CLI's loop.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Names for --verbose

let keyNames: [Int: String] = [
    0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b", 12: "q",
    13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
    24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "o", 32: "u", 33: "[", 34: "i",
    35: "p", 37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "n", 46: "m",
    47: ".", 50: "`", 49: "space", 36: "return", 48: "tab", 51: "delete", 53: "esc",
    54: "cmd-r", 55: "cmd", 56: "shift", 57: "caps", 58: "option", 59: "control", 60: "shift-r",
    76: "enter", 123: "left", 124: "right", 125: "down", 126: "up",
]
func keyName(_ code: Int) -> String { keyNames[code] ?? "key\(code)" }
let spaceCode = 49, returnCode = 36

// MARK: - The click queue

/// Whole clicks waiting to be played. One worker plays them in order (the motor can't mix two actuations),
/// and the queue is deliberately shallow: past a few clicks, newer keys are dropped rather than queued, so
/// thockpad never falls behind a paste or a held key.
struct Click { var tones: [Tone]; var level: Float; var word: String? }
let clickLock = NSLock()
var pending: [Click] = []
let clickSemaphore = DispatchSemaphore(value: 0)
let maxQueuedClicks = 3

func enqueue(_ click: Click) {
    clickLock.lock()
    if pending.count >= maxQueuedClicks {
        clickLock.unlock()
        statsLock.lock(); stats.throttled += 1; statsLock.unlock()
        return
    }
    pending.append(click)
    clickLock.unlock()
    clickSemaphore.signal()
}

var workerStarted = false
let workerLock = NSLock()

/// The worker thread: play one whole click at a time, honouring each tone's offset inside it.
func startClickWorkerIfNeeded() {
    workerLock.lock(); defer { workerLock.unlock() }
    guard !workerStarted else { return }
    workerStarted = true
    Thread {
        while !stopRequested {
            clickSemaphore.wait()
            if stopRequested { return }
            clickLock.lock()
            guard !pending.isEmpty else { clickLock.unlock(); continue }
            let click = pending.removeFirst()
            clickLock.unlock()
            playClick(click.tones, at: click.level)
            if let word = click.word { queueWord(word) }
        }
    }.start()
}

// MARK: - Stats

struct Stats {
    var down = 0, up = 0, throttled = 0, spoken = 0
    var first = -1.0, last = -1.0, active = 0.0
}
let statsLock = NSLock()
var stats = Stats()

// MARK: - The motor, checked without exiting

/// Why the trackpad can't click, or nil when it can. openMotor() (from nospeaker) explains problems well
/// but exits the process — right for the CLI, wrong for a GUI window, so this mirrors its probe and reports
/// instead of exiting. Opens the actuator as a side effect.
func motorCheck() -> String? {
    if motor != nil { return nil }
    guard createList != nil, getID != nil, isBuiltIn != nil, actuatorCreate != nil, actuatorOpen != nil,
          actuationCreate != nil, actuationPlay != nil else {
        return "This version of macOS doesn't have the trackpad functions thockpad needs."
    }
    guard let list = createList?()?.takeRetainedValue(), CFArrayGetCount(list) > 0 else {
        return "No trackpad found. thockpad needs a Force Touch trackpad (a MacBook from 2015 on, or a Magic Trackpad 2 or newer)."
    }
    deviceList = list
    var ids: [(id: UInt64, builtIn: Bool)] = []
    for i in 0..<CFArrayGetCount(list) {
        guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
        let dev = UnsafeMutableRawPointer(mutating: raw)
        var id: UInt64 = 0
        if getID!(dev, &id) == 0 { ids.append((id, isBuiltIn?(dev) ?? false)) }
    }
    for d in ids.sorted(by: { $0.builtIn && !$1.builtIn }) {
        if let ref = actuatorCreate!(d.id)?.takeRetainedValue(), actuatorOpen!(ref) == 0 {
            motorDeviceID = d.id
            motorBuiltIn = d.builtIn
            motor = ref
            motorPointer = Unmanaged.passUnretained(ref as AnyObject).toOpaque()
            return nil
        }
    }
    return "Found a trackpad, but it has no haptic motor (Force Touch), so it can't click."
}

/// nil when the motor is open and ready; sets motorProblem so callers (and the GUI) can say why not.
var motorProblem: String?
func openMotorIfNeeded() {
    if motor == nil { motorProblem = motorCheck() }
}

// MARK: - The tap

var eventTap: CFMachPort?
var tapSource: CFRunLoopSource?
var tapRunning: Bool { eventTap != nil }
var lastClickAt = -1.0

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    // macOS disables a tap that takes too long in the callback: re-arm and carry on.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard !stopRequested, !paused else { return Unmanaged.passUnretained(event) }

    let t = now()
    switch type {
    case .keyDown, .flagsChanged:
        if t - lastClickAt < throttleSeconds {
            statsLock.lock(); stats.throttled += 1; statsLock.unlock()
            return passThrough ? Unmanaged.passUnretained(event) : nil
        }
        lastClickAt = t
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if verbose { report("↓ \(keyName(code))") }
        let word: String? = talkEnabled
            ? (code == spaceCode ? wordBank.randomElement() : code == returnCode ? finishers.randomElement() : nil)
            : nil
        enqueue(Click(tones: clickTones(for: code, at: t), level: gain, word: word))
        statsLock.lock()
        if stats.first < 0 { stats.first = t }
        if stats.last > 0, t - stats.last < 1.0 { stats.active += t - stats.last }
        stats.last = t
        stats.down += 1
        statsLock.unlock()
        return passThrough ? Unmanaged.passUnretained(event) : nil

    case .keyUp:
        // Never swallow a release: a lost key-up leaves keys and modifiers stuck down.
        let tones = releaseTones()
        guard !tones.isEmpty else { return Unmanaged.passUnretained(event) }
        if verbose { report("↑") }
        enqueue(Click(tones: tones, level: gain * Float(currentProfile.release)))
        statsLock.lock(); stats.up += 1; statsLock.unlock()
        return Unmanaged.passUnretained(event)

    default:
        return Unmanaged.passUnretained(event)
    }
}

/// Create the tap, add it to this thread's run loop (its callback fires from there), and enable it.
func startTap() -> Bool {
    guard eventTap == nil else { return true }
    let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                      options: passThrough ? .listenOnly : .defaultTap,
                                      eventsOfInterest: mask, callback: tapCallback, userInfo: nil) else {
        return false
    }
    eventTap = tap
    tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
}

func stopTap() {
    guard let tap = eventTap else { return }
    CGEvent.tapEnable(tap: tap, enable: false)
    if let source = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    eventTap = nil
    tapSource = nil
}

// MARK: - Input Monitoring

func inputMonitoringGranted() -> Bool { AXIsProcessTrusted() }

func openInputMonitoringPane() {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = ["x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"]
    try? task.run()
}

/// Exit with instructions unless macOS already trusts this binary (CLI path; the GUI shows the same text in
/// its window instead). A fresh grant only applies to a new process, so the current one is useless.
func requireInputMonitoring() {
    if inputMonitoringGranted() { return }
    let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    report("""

      thockpad can't hear your keyboard yet.

        1. System Settings → Privacy & Security → Input Monitoring
        2. switch thockpad on  (if it's not in the list, start it once from a terminal and try again)
        3. start thockpad again — a brand-new grant only applies to a new process

      If it's in the list, ticked, and still not working: the binary changed since you ticked it
      (a rebuild, or a different copy). Run ./scripts/permissions.sh to give it a stable identity.
    """)
    openInputMonitoringPane()
    exit(77)
}

// MARK: - Status

func printStatus() {
    statsLock.lock(); let s = stats; statsLock.unlock()
    let rate = s.active > 0 ? Double(s.down) / s.active : 0
    report("""
    thockpad · “\(profileName)” (\(currentProfile.blurb)) · level \(String(format: "%.2f", gain))\(talkEnabled ? " · talking" : "")\(passThrough ? "" : " · SWALLOWING KEYS")\(paused ? " · PAUSED" : "")
    \(s.down) presses, \(s.up) releases, \(s.throttled) too fast, \(s.spoken) words · \(String(format: "%.1f", rate)) keys/second
    ctrl-c stops it (or kill -USR1 \(getpid()) prints this).
    """)
}

// MARK: - Running (CLI)

func runThockpad() -> Int32 {
    openMotorIfNeeded()
    if let problem = motorProblem { report("thockpad: \(problem)"); return 2 }
    requireInputMonitoring()
    warmVoice()   // synthesise the word bank up front, so the first space bar is not slow

    guard startTap() else {
        report("thockpad couldn't open the keyboard tap. Quit any other thockpad and start it again; if that fails, ./scripts/permissions.sh")
        return 1
    }
    startClickWorkerIfNeeded()
    installExitSignals()

    // Silent by design: no click, no greeting — you will hear it when you type.
    if chatter {
        report("thockpad: “\(profileName)” — \(currentProfile.blurb). Ctrl-C stops.")
        report(passThrough ? "  keys pass through to the Mac (--swallow to mute your real typing)."
                           : "  keys are SWALLOWED — nothing you type reaches the Mac. Ctrl-C takes the keyboard back.")
    }

    // Pump this thread's run loop: the event tap's callback fires from it, so a plain sleep loop here means
    // the tap never delivers a single key (silent, zero presses — it looks like the tap is dead). Short
    // slices so ctrl-c, which only sets a flag in the handler, ends it promptly.
    while !stopRequested { CFRunLoopRunInMode(.defaultMode, 0.05, false) }
    printStatus()
    if let motor { _ = actuatorClose?(motor) }
    return 0
}

// MARK: - Timed run (for testing)

/// Stop after N seconds — what `--run 20` uses: start thockpad, drive it from another process (or real
/// fingers), and it reports its stats and exits on its own.
func startTimer(_ seconds: Double) {
    Thread {
        let end = now() + seconds
        while now() < end && !stopRequested { usleep(50_000) }
        stopRequested = true
    }.start()
}

// MARK: - Self-test

/// Without waiting for a human: post one synthetic key press and check it comes back through the tap and
/// clicks. A trusted process can't see its own events at the HID tap but can at the session tap — which is
/// also why thockpad listens at the session tap.
func selfTest() -> Int32 {
    openMotorIfNeeded()
    if let problem = motorProblem { report("self-test: \(problem)"); return 2 }
    if !inputMonitoringGranted() {
        report("self-test: not trusted yet — allow thockpad under Input Monitoring, then run it again (exit 3).")
        return 3
    }
    guard startTap() else { report("self-test: trusted, but the tap wouldn't open (exit 3)."); return 3 }
    startClickWorkerIfNeeded()

    statsLock.lock(); let before = stats.down; statsLock.unlock()
    let src = CGEventSource(stateID: .privateState)
    if let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(spaceCode), keyDown: true) {
        down.post(tap: .cgSessionEventTap)
    }
    let deadline = now() + 1.5
    while now() < deadline {
        statsLock.lock(); let seen = stats.down > before; statsLock.unlock()
        if seen { break }
        CFRunLoopRunInMode(.defaultMode, 0.02, false)
    }
    statsLock.lock(); let seen = stats.down > before; statsLock.unlock()
    if seen {
        report("self-test: OK — heard a synthetic space, clicked the trackpad (you should have felt/heard one click).")
        if let motor { _ = actuatorClose?(motor) }
        return 0
    }
    report("self-test: FAILED — trusted and tapping, but the synthetic key never came back. Type a key while `thockpad --verbose` runs to see what your Mac delivers.")
    return 5
}

// MARK: - Signals

func installExitSignals() {
    signal(SIGINT) { _ in stopRequested = true }
    signal(SIGTERM) { _ in stopRequested = true }
    signal(SIGUSR1) { _ in printStatus() }
}
