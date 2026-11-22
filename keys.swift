// thockpad — listening to the keyboard, and the click worker behind it.
//
// A CGEventTap watches key down/up events. The callback does as little as possible (timestamp, shape the
// tones, push them onto a queue) and a single worker thread plays them, so typing latency never depends on
// the motor. With --swallow the callback returns nil instead of the event, so the Mac never sees the key;
// without it (the default) events pass through untouched and thockpad only adds sound.
//
// Needs Input Monitoring (Accessibility): macOS prompts on first run, and a fresh grant only applies to a
// newly started process.

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

/// The worker thread: play one whole click at a time, honouring each tone's offset inside it.
func startClickWorker() {
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

// MARK: - The tap

var eventTap: CFMachPort?
var lastClickAt = -1.0

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    // macOS disables a tap that takes too long in the callback: re-arm and carry on.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard !stopRequested else { return Unmanaged.passUnretained(event) }

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
        enqueue(Click(tones: tones, level: gain * Float(currentProfile.release) * releaseGain))
        statsLock.lock(); stats.up += 1; statsLock.unlock()
        return Unmanaged.passUnretained(event)

    default:
        return Unmanaged.passUnretained(event)
    }
}

// MARK: - Input Monitoring

/// Stop with instructions unless macOS already trusts this binary. AXIsProcessTrustedWithOptions prompts the
/// first time; the grant only takes effect in a new process, so thockpad has to exit.
func requireInputMonitoring() {
    if AXIsProcessTrusted() { return }
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
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = ["x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"]
    try? task.run()
    exit(77)
}

// MARK: - Status

func printStatus() {
    statsLock.lock(); let s = stats; statsLock.unlock()
    let rate = s.active > 0 ? Double(s.down) / s.active : 0
    report("""
    thockpad · “\(profileName)” (\(currentProfile.blurb)) · level \(String(format: "%.2f", gain))\(talkEnabled ? " · talking" : "")\(passThrough ? "" : " · SWALLOWING KEYS")
    \(s.down) presses, \(s.up) releases, \(s.throttled) too fast, \(s.spoken) words · \(String(format: "%.1f", rate)) keys/second
    ctrl-c stops it (or kill -USR1 \(getpid()) prints this).
    """)
}

// MARK: - Running

func openMotorIfNeeded() {
    if motor == nil {
        motor = openMotor()
        motorPointer = Unmanaged.passUnretained(motor! as AnyObject).toOpaque()
    }
}

func runThockpad() -> Int32 {
    openMotorIfNeeded()
    requireInputMonitoring()
    warmVoice()   // synthesise the word bank up front, so the first space bar is not slow

    let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                      options: passThrough ? .listenOnly : .defaultTap,
                                      eventsOfInterest: mask, callback: tapCallback, userInfo: nil) else {
        report("thockpad couldn't open the keyboard tap. Quit any other thockpad and start it again; if that fails, ./scripts/permissions.sh")
        return 1
    }
    eventTap = tap
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    startClickWorker()
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
    if !AXIsProcessTrusted() {
        report("self-test: not trusted yet — allow thockpad under Input Monitoring, then run it again (exit 3).")
        return 3
    }
    let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                      options: .listenOnly, eventsOfInterest: mask,
                                      callback: tapCallback, userInfo: nil) else {
        report("self-test: trusted, but the tap wouldn't open (exit 3).")
        return 3
    }
    eventTap = tap
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    startClickWorker()

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
