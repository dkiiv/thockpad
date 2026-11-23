// thockpad — hearing the keyboard WITHOUT asking for anything.
//
// CGEventSource.keyState(.combinedSessionState, key:) answers “is this key down right now?” for every
// physical key — and unlike a CGEventTap, it is not gated behind Input Monitoring (proven on this Mac:
// real typing seen from an ungranted, ad-hoc-signed process). So thockpad polls all 128 keycodes every
// 2 ms and clicks on the edges: down → click, up → optional tock. That means: no system settings, no
// checkboxes, no cdhash grief, nothing to approve — install and type.
//
// Polling also improves the feel: one click per physical press (holding a key never auto-repeats the
// click), and thockpad cannot interfere with your typing at all — it only watches state.
//
// The click worker, stats, and motor plumbing are the same as before; the event tap and Input Monitoring
// code are gone for good. (--swallow went with them: thockpad never touches your keystrokes now.)

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
    63: "fn", 76: "enter", 123: "left", 124: "right", 125: "down", 126: "up",
]
func keyName(_ code: Int) -> String { keyNames[code] ?? "key\(code)" }
let spaceCode = 49, returnCode = 36, deleteCode = 51

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
    let thread = Thread {
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
    }
    thread.qualityOfService = .userInteractive
    thread.name = "thockpad-clicks"
    thread.start()
}

// MARK: - Stats

struct Stats {
    var down = 0, up = 0, throttled = 0, spoken = 0
    var first = -1.0, last = -1.0, active = 0.0
    var lastKey = ""            // name of the most recent key press seen
    var lastKeyAt = 0.0
}
let statsLock = NSLock()
var stats = Stats()

// MARK: - The motor, checked without exiting

/// Why the trackpad can't click, or nil when it can. nospeaker's openMotor() explains problems well but
/// exits the process — right for a CLI error, wrong for a GUI window — so this mirrors its probe and
/// reports instead. Opens the actuator as a side effect. (Driving the motor needs no approval — the
/// private MultitouchSupport calls are not a TCC service.)
func motorCheck() -> String? {
    if motor != nil { return nil }
    guard createList != nil, getID != nil, actuatorCreate != nil, actuatorOpen != nil,
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

// MARK: - Listening: poll the key state

var lastClickAt = -1.0
var pollRunning = false
let pollLock = NSLock()

func startListeningIfNeeded() {
    pollLock.lock(); defer { pollLock.unlock() }
    guard !pollRunning else { return }
    pollRunning = true
    let thread = Thread { pollKeys() }
    thread.qualityOfService = .userInitiated
    thread.name = "thockpad-poll"
    thread.start()
}

var listening: Bool { pollLock.lock(); defer { pollLock.unlock() }; return pollRunning }

/// Read every key's state 500× a second, click on the edges. 128 boolean queries per pass costs ~2.7 % of
/// one M1 core (top, idle); measured, not hoped (a probe tracked live typing on this Mac with transitions
/// matching keystroke-for-keystroke, and saw injected System Events keys with no permission granted).
func pollKeys() {
    var keyState = [Bool](repeating: false, count: 128)
    // Snapshot current state first so keys already held when thockpad starts don't fire phantom clicks,
    // and their release doesn't fire a tock.
    for code in 0..<128 { keyState[code] = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code)) }
    while !stopRequested {
        for code in 0..<128 {
            let down = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code))
            if down == keyState[code] { continue }
            keyState[code] = down
            guard !paused else { continue }        // paused: keep tracking state, just never click
            if down {
                let t = now()
                if t - lastClickAt < throttleSeconds {
                    statsLock.lock(); stats.throttled += 1; statsLock.unlock()
                } else {
                    lastClickAt = t
                    if verbose { report("↓ \(keyName(code))") }
                    let word: String? = talkEnabled
                        ? (code == spaceCode ? wordBank.randomElement() : code == returnCode ? finishers.randomElement() : nil)
                        : nil
                    enqueue(Click(tones: clickTones(for: code, at: t), level: gain, word: word))
                    statsLock.lock()
                    if stats.first < 0 { stats.first = t }
                    if stats.last > 0, t - stats.last < 1.0 { stats.active += t - stats.last }
                    stats.last = t
                    stats.lastKey = keyName(code)
                    stats.lastKeyAt = t
                    stats.down += 1
                    statsLock.unlock()
                }
            } else {
                let tones = releaseTones()
                guard !tones.isEmpty else { continue }
                if verbose { report("↑") }
                enqueue(Click(tones: tones, level: gain * Float(currentProfile.release)))
                statsLock.lock(); stats.up += 1; statsLock.unlock()
            }
        }
        usleep(2_000)
    }
}

// MARK: - Running (CLI)

/// `kill -USR1 <pid>` and the end of a run: how you're doing, in three lines.
func printStatus() {
    statsLock.lock(); let s = stats; statsLock.unlock()
    let rate = s.active > 0 ? Double(s.down) / s.active : 0
    report("""
    thockpad · “\(profileName)” (\(currentProfile.blurb)) · level \(String(format: "%.2f", gain))\(talkEnabled ? " · talking" : "")\(paused ? " · PAUSED" : "")
    \(s.down) presses, \(s.up) releases, \(s.throttled) too fast, \(s.spoken) words · \(String(format: "%.1f", rate)) keys/second
    ctrl-c stops it (or kill -USR1 \(getpid()) prints this).
    """)
}

func runThockpad() -> Int32 {
    openMotorIfNeeded()
    if let problem = motorProblem { report("thockpad: \(problem)"); return 2 }
    warmVoice()   // synthesise the word bank up front, so the first space bar is not slow
    startClickWorkerIfNeeded()
    startListeningIfNeeded()
    installExitSignals()

    // Silent by design: no click, no greeting — you will hear it when you type.
    if chatter { report("thockpad: “\(profileName)” — \(currentProfile.blurb). Type. Ctrl-C stops.") }

    // The poller and the worker are their own threads; the main thread just waits. (A run loop was only
    // ever needed for the event tap, which is gone.)
    while !stopRequested { usleep(50_000) }
    printStatus()
    if let motor { _ = actuatorClose?(motor) }
    return 0
}

// MARK: - Timed run (for testing)

/// Stop after N seconds — what `--run 20` uses.
func startTimer(_ seconds: Double) {
    Thread {
        let end = now() + seconds
        while now() < end && !stopRequested { usleep(50_000) }
        stopRequested = true
    }.start()
}

// MARK: - Self-test

/// Start everything and prove the loop is alive. thockpad no longer injects or intercepts anything, so
/// --selftest doesn't either: it starts listening, waits, and reports whether ANY key state changed.
/// `--selftest --post-keys` (opt-in) additionally posts a space + delete pair through the HID system —
/// they cancel out in any text field — to prove the poll sees even synthetic keys.
func selfTest(postKeys: Bool = false) -> Int32 {
    openMotorIfNeeded()
    if let problem = motorProblem { report("self-test: \(problem)"); return 2 }
    startClickWorkerIfNeeded()
    startListeningIfNeeded()

    statsLock.lock(); let before = stats.down; statsLock.unlock()
    if postKeys {
        Thread {
            usleep(300_000)
            let src = CGEventSource(stateID: .combinedSessionState)
            CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(spaceCode), keyDown: true)?.post(tap: .cghidEventTap)
            usleep(60_000)
            CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(spaceCode), keyDown: false)?.post(tap: .cghidEventTap)
            usleep(30_000)
            CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(deleteCode), keyDown: true)?.post(tap: .cghidEventTap)
            usleep(60_000)
            CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(deleteCode), keyDown: false)?.post(tap: .cghidEventTap)
        }.start()
    }
    report("self-test: listening — press a key now (2 s)…")
    let deadline = now() + 2
    var sawKey = false
    while now() < deadline {
        statsLock.lock(); sawKey = stats.down > before; statsLock.unlock()
        if sawKey { break }
        usleep(20_000)
    }
    statsLock.lock(); let seen = stats.down > before; statsLock.unlock()
    stopRequested = true
    if let motor { _ = actuatorClose?(motor) }
    if seen {
        report("self-test: OK — heard a key press and clicked the trackpad.")
        return 0
    }
    report(postKeys
        ? "self-test: listening, but the synthetic keys never registered — tell the developer, this one's interesting."
        : "self-test: listening (motor open, poller running) — no key arrived in 2 s. Type and retry; it will click.")
    return seen ? 0 : 4
}

// MARK: - Signals

func installExitSignals() {
    signal(SIGINT) { _ in stopRequested = true }
    signal(SIGTERM) { _ in stopRequested = true }
    signal(SIGUSR1) { _ in printStatus() }
}
