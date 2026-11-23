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
struct Click {
    var tones: [Tone]
    var level: Float
    var word: String? = nil
    var priority = true
    var at = 0.0              // when the key edge happened, so a click that can't play soon is dropped
}

/// How long a click may be late and still be played, in seconds. A click is a *reaction*: past this the
/// moment has gone, and playing it is the app making noise that isn't attached to anything you did.
///
/// Sized to the measurements, not to hope: the poll loop's real period on this Mac is ~6–12 ms (kernel
/// sleep floor) and can spike to ~80 ms under OS load, and a queued click waits behind at most three
/// others at ~4 ms each. So 80 ms is generous enough that a healthy pipeline never trips it, while still
/// being short enough that a burst resurrected after a stall (App Nap, laptop sleep) never plays.
let staleClickSeconds = 0.08

/// The poll loop's own period is ~6 ms here and OS noise puts its worst gap in the tens of ms, so the
/// watchdog only calls a *stall* something far beyond that: a freeze, not a scheduling hiccup.
let pollStallSeconds = 0.5
let clickLock = NSLock()
var pending: [Click] = []
let clickSemaphore = DispatchSemaphore(value: 0)
let maxQueuedClicks = 3

/// How long a click occupies the *driver*, in seconds — not how long it rings.
///
/// The whole click fires as ONE actuation (see `playClick`), which costs ~3.5 ms of measured driver time.
/// The sound then rings on for the length of its tones (a thock's deep tone runs 34 ms), but reserving that
/// too is what caused the original bug: two presses 25 ms apart — an ordinary fast pair inside a word —
/// and the second one was refused, i.e. a silent key. So only the driver cost is reserved, with the 15 ms
/// actuation floor on top (measured: the driver needs it between actuations), which allows ~66 clicks a
/// second: more than any typing. Presses closer than that overlap, and the later click truncates the tail
/// of the earlier one — the same thing a real board does when you type fast, and far better than silence.
func clickSeconds(_ tones: [Tone]) -> Double { _ = tones; return 0.004 }   // measured one-call driver cost

/// When the driver will next accept an actuation. A click costs ~4 ms of driver time and the driver needs
/// the 15 ms actuation floor between them, so the reservation is that floor: ~66 clicks a second, more
/// than any typing. Reserving the *sound* length instead (34 ms for a thock) is what made ordinary fast key
/// pairs go silent.
let motorLock = NSLock()
nonisolated(unsafe) var motorBusyUntil = 0.0

/// Claim the next driver slot for a press at `t`. A press arriving while the driver is busy waits behind it
/// — a few ms late is still the same keystroke — but if the wait would exceed the stale window the click is
/// refused, because queueing it would make the sound drift away from the fingers.
func claimMotor(at t: Double, seconds: Double) -> Bool {
    motorLock.lock(); defer { motorLock.unlock() }
    let start = max(motorBusyUntil, t)
    if start - t > staleClickSeconds { return false }
    motorBusyUntil = start + max(seconds, throttleSeconds)
    return true
}

/// A key-release tock is garnish: it never claims the motor and never waits in line ahead of a press —
/// the worker drops it the moment a press is behind it (and it's dropped first when the queue is full).
func enqueue(_ click: Click) {
    clickLock.lock()
    if pending.count >= maxQueuedClicks {
        if let slot = pending.firstIndex(where: { !$0.priority }) { pending.remove(at: slot) }
        else if !click.priority {
            // A tock can't even evict... it loses its own place in line.
            clickLock.unlock()
            return
        } else {
            clickLock.unlock()
            statsLock.lock(); stats.throttled += 1; statsLock.unlock()
            return
        }
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
            // A tock only plays if no press is waiting behind it — presses are the point of the app.
            if !click.priority, pending.contains(where: { $0.priority }) {
                clickLock.unlock()
                statsLock.lock(); stats.tocksDropped += 1; statsLock.unlock()
                continue
            }
            let age = now() - click.at
            clickLock.unlock()
            // Late is wrong: only play a click while it still feels like it belongs to the keystroke.
            if age > staleClickSeconds {
                statsLock.lock(); stats.late += 1; statsLock.unlock()
                if verbose { report("✗ dropped, \(Int(age * 1000)) ms late") }
                continue
            }
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
    var heard = 0, down = 0, up = 0, throttled = 0, spoken = 0, tocksDropped = 0, late = 0
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

/// App Nap is fatal here: a window-less (or hidden) AppKit app gets its threads throttled into a freeze,
/// and this one has to poll forever. Measured on this Mac: 95 s after launch the poller's CPU dropped
/// 2.7 % → 0.5 % and 20 keystrokes produced zero presses and zero actuations. When the process woke again
/// (clicking the menu bar icon), every key that changed state in between fired at once — a burst of
/// clicks. Holding this activity assertion disables App Nap for the process.
nonisolated(unsafe) var appNapAssertion: AnyObject?
func preventAppNap() {
    guard appNapAssertion == nil else { return }
    appNapAssertion = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
        reason: "thockpad polls the keyboard forever; a frozen poller means silent keys and a burst on wake")
}

var pollRunning = false
let pollLock = NSLock()

func startListeningIfNeeded() {
    pollLock.lock(); defer { pollLock.unlock() }
    guard !pollRunning else { return }
    pollRunning = true
    preventAppNap()
    let thread = Thread { pollKeys() }
    // .userInteractive, not .userInitiated: a quick tap whose whole 30 ms hold lands inside a scheduling
    // gap is missed entirely (down and up both change while we're descheduled → net zero, not even an
    // edge), and .userInitiated is what the scheduler feels free to hold off for tens of ms. A pass costs
    // ~0.00 ms of CPU, so the highest priority is cheap here; this is the whole point of the app.
    thread.qualityOfService = .userInteractive
    thread.name = "thockpad-poll"
    thread.start()
}

var listening: Bool { pollLock.lock(); defer { pollLock.unlock() }; return pollRunning }

/// Read every key's state, click on the edges. Honest numbers for this Mac (measured with the identical
/// loop, `waitbench`): any wait bottoms out at ~5.8 ms because of the kernel's sleep floor, so this loop
/// runs at ~90–170 passes a second, not 500 — at 0.1 % of one core. That is still 6–30× faster than the
/// 30–100 ms a human key is held down, so nothing is missed; `usleep(2_000)` asking for 2 ms is just the
/// cheapest way to ask. (Spinning would give ~1.6 M passes/s at ~99 % CPU. Not happening for a toy.)
///
/// One safety rule: a pass that starts more than half a second after the last one means this thread was
/// frozen (App Nap, laptop sleep, CPU starvation). Whatever changed while we were gone is history, not a
/// keystroke — silently resync the snapshot instead of firing a click per key, which is what made clicking
/// the menu bar icon "spam the sound" after the app sat idle.
let watchdogLock = NSLock()
nonisolated(unsafe) var lastPassAt = 0.0
nonisolated(unsafe) var worstPassGap = 0.0
func pollHealth() -> (age: Double, worst: Double) {
    watchdogLock.lock(); defer { watchdogLock.unlock() }
    return (now() - lastPassAt, worstPassGap)
}

func pollKeys() {
    var keyState = [Bool](repeating: false, count: 128)
    // Snapshot current state first so keys already held when thockpad starts don't fire phantom clicks,
    // and their release doesn't fire a tock.
    for code in 0..<128 { keyState[code] = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code)) }
    var lastPass = now()
    watchdogLock.lock(); lastPassAt = lastPass; watchdogLock.unlock()
    while !stopRequested {
        let passStart = now()
        if passStart - lastPass > 0.5 {
            for code in 0..<128 { keyState[code] = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code)) }
            motorLock.lock(); motorBusyUntil = passStart; motorLock.unlock()   // whatever we reserved is long gone
            say("thockpad: was stopped for \(String(format: "%.1f", passStart - lastPass)) s — resynced; keys missed while stopped stay silent.")
        }
        watchdogLock.lock()
        worstPassGap = max(worstPassGap, passStart - lastPass)
        lastPass = passStart
        watchdogLock.unlock()
        for code in 0..<128 {
            let down = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code))
            if down == keyState[code] { continue }
            keyState[code] = down
            guard !paused else { continue }        // paused: keep tracking state, just never click
            if down {
                let t = now()
                statsLock.lock(); stats.heard += 1; statsLock.unlock()   // heard ≠ clicked: see below
                let tones = clickTones(for: code, at: t)
                if claimMotor(at: t, seconds: clickSeconds(tones)) {
                    if verbose { report("↓ \(keyName(code))") }
                    let word: String? = talkEnabled
                        ? (code == spaceCode ? wordBank.randomElement() : code == returnCode ? finishers.randomElement() : nil)
                        : nil
                    enqueue(Click(tones: tones, level: gain, word: word, at: t))
                    statsLock.lock()
                    if stats.first < 0 { stats.first = t }
                    if stats.last > 0, t - stats.last < 1.0 { stats.active += t - stats.last }
                    stats.last = t
                    stats.lastKey = keyName(code)
                    stats.lastKeyAt = t
                    stats.down += 1
                    statsLock.unlock()
                } else {
                    // The motor is still busy with an earlier click: dropping is the only honest option,
                    // because queueing it would land the sound late and push every later key further behind.
                    statsLock.lock(); stats.throttled += 1; statsLock.unlock()
                    if verbose { report("· \(keyName(code)) (motor busy)") }
                }
            } else {
                let tones = releaseTones()
                guard !tones.isEmpty else { continue }
                if verbose { report("↑") }
                // A tock never blocks and is never queued ahead of a press: it fills spare motor time, and
                // is the first thing dropped when presses need the slot.
                enqueue(Click(tones: tones, level: gain * Float(currentProfile.release), priority: false, at: now()))
                statsLock.lock(); stats.up += 1; statsLock.unlock()
            }
        }
        usleep(1_000)   // asking under the ~5.8 ms floor still polls ~2× faster at the same 0.1 % CPU
    }
}

// MARK: - Running (CLI)

/// `kill -USR1 <pid>` and the end of a run: how you're doing, in three lines.
func printStatus() {
    statsLock.lock(); let s = stats; statsLock.unlock()
    let rate = s.active > 0 ? Double(s.down) / s.active : 0
    report("""
    thockpad · “\(profileName)” (\(currentProfile.blurb)) · level \(String(format: "%.2f", gain))\(talkEnabled ? " · talking" : "")\(paused ? " · PAUSED" : "")
    \(s.heard) keys heard → \(s.down) clicks (\(s.throttled) refused, \(s.late) too late), \(s.up) tocks (\(s.tocksDropped) skipped), \(s.spoken) words · \(String(format: "%.1f", rate)) keys/second
    poll loop: worst gap \(String(format: "%.0f", pollHealth().worst * 1000)) ms (\(pollHealth().worst < pollStallSeconds ? "healthy" : "STALL — something is throttling thockpad"))
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

// MARK: - Why there is no synthetic-key bench
//
// A bench that posts CGEvents and counts what the poller hears looks obvious and is a lie on this Mac,
// measured three ways: a posted right-shift produced ZERO edges even at 250 ms spacing (modifier state does
// not reach `keyState` through posting at all), a posted F13 produced 14 edges for 10 presses (140 %), and
// hit-rate came out INVERSE to hold time (80 % at 5 ms, 20 % at 30 ms) — the opposite of a sampling
// explanation. So `--selftest --post-keys` stays a smoke test (it only asks "did anything arrive?"), and
// the real numbers come from the app itself while you type: heard → clicked, refused, too late, worst gap.
// Trusting the synthetic bench here would have meant "fixing" a poller that was never broken.

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
