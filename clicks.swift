// thockpad — what one keystroke sounds like, and how it reaches the motor.
//
// A click is one or two sine tones a few milliseconds long, played through nospeaker's play(): the same
// mechanism that makes its heartbeat thump. nospeaker measured this motor to be loud from ~100 Hz to 4 kHz
// and cleanest near 1 kHz, so a click is a mid/high tone for the bevel snap, with a low body tone under it
// in the deep profiles for the thock.

import Foundation

// MARK: - Profiles

/// One tone of a click: Hz, relative strength (0…1), length in ms, offset in ms.
struct Tone { var hz: Double; var amp: Double; var ms: Double; var delay: Double = 0 }

/// A switch's personality.
struct Profile {
    let name: String
    let blurb: String
    let tones: [Tone]
    let release: Double   // strength of the bottom-out click on key-up (0 = press only)
}

let profileList: [Profile] = [
    Profile(name: "brown", blurb: "tactile bump: crisp mid click",
            tones: [Tone(hz: 1400, amp: 0.85, ms: 7), Tone(hz: 380, amp: 0.30, ms: 18, delay: 1)],
            release: 0.30),
    Profile(name: "blue", blurb: "clicky: bright snap",
            tones: [Tone(hz: 2200, amp: 0.95, ms: 5), Tone(hz: 240, amp: 0.25, ms: 14, delay: 1)],
            release: 0.45),
    Profile(name: "red", blurb: "linear: soft quiet tap",
            tones: [Tone(hz: 900, amp: 0.50, ms: 6)],
            release: 0.00),
    Profile(name: "thock", blurb: "deep marbly thock (the good one)",
            tones: [Tone(hz: 520, amp: 0.60, ms: 8), Tone(hz: 140, amp: 0.55, ms: 34, delay: 2)],
            release: 0.40),
    Profile(name: "click", blurb: "membrane keyboard: two-tone pop",
            tones: [Tone(hz: 1700, amp: 0.90, ms: 4), Tone(hz: 1050, amp: 0.45, ms: 7, delay: 5)],
            release: 0.25),
    Profile(name: "marble", blurb: "glassy high-pitched tock",
            tones: [Tone(hz: 1900, amp: 0.75, ms: 4), Tone(hz: 2800, amp: 0.30, ms: 6)],
            release: 0.25),
]
let profiles: [String: Profile] = Dictionary(uniqueKeysWithValues: profileList.map { ($0.name, $0) })
/// Menu order (and what --cycle walks), the way they are described in --list.
let profileOrder = profileList.map(\.name)

// MARK: - Settings (set from main.swift or the GUI; read per keystroke)

var profileName = "thock"
var currentProfile = profiles["thock"]!
var gain: Float = 0.85          // overall click loudness (motor is never driven past its normal maximum)
var releaseOn = true            // the bottom-out “tock” on key-up
var passThrough = true          // false = swallow key events (--swallow / the GUI checkbox)
var paused = false              // the GUI's pause: the tap keeps running, nothing clicks, keys stay normal
var throttleSeconds = 0.015     // actuations can't overlap: 15 ms is the floor for a clean click
var talkEnabled = false
var verbose = false
// thockpad starts silent: no click, no greeting, nothing on the terminal. --chatter opts in to the startup
// line, --verbose prints each key. Errors and the kill -USR1 status always print, through report().
var chatter = false
func report(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

func setProfile(_ name: String) { profileName = name; currentProfile = profiles[name]! }
var swallowKeys: Bool { get { !passThrough } set { passThrough = !newValue } }

/// Startup chatter only (--chatter / --verbose): the daemon must be silent without it.
func say(_ s: String) { if chatter { report(s) } }

// MARK: - Playing one click

/// Play a click: each tone as its own short actuation, fired at its offset. Blocks until the click is over
/// (a few ms) so callers can serialise them; nospeaker restarts the motor per actuation with no ramp, which
/// is exactly the sharp attack a click needs.
func playClick(_ tones: [Tone], at level: Float) {
    guard !tones.isEmpty, level > 0 else { return }
    let l = min(1, max(0, level))
    for tone in tones {
        let fireAt = now() + tone.delay / 1000
        while now() < fireAt && !stopRequested { usleep(100) }
        if stopRequested { return }
        play([(hz: tone.hz, amp: tone.amp)], ms: tone.ms, level: l)
    }
    let end = now() + (tones.map { $0.delay + $0.ms }.max() ?? 0) / 1000
    while now() < end && !stopRequested { usleep(400) }
}

/// The press click: the profile's tones plus a little life, so a run of keystrokes is a typewriter and not a
/// machine gun. Every physical key gets a fixed detune (like key-to-key variation on a real board), the whole
/// thing drifts slowly, and the big keys — space, returns, shifts — sound lower and longer.
func clickTones(for code: Int, at t: Double) -> [Tone] {
    let heavy: Double = [49, 36, 76, 56, 60].contains(code) ? 0.78 : 1
    let detune = (1 + (Double(code % 7) - 3) * 0.012 + sin(t * 37) * 0.04) * heavy
    return currentProfile.tones.map {
        Tone(hz: $0.hz * detune, amp: $0.amp, ms: $0.ms * (heavy < 1 ? 1.3 : 1), delay: $0.delay)
    }
}

/// The release "tock": the same click, a bit lower and much quieter.
func releaseTones() -> [Tone] {
    guard releaseOn, currentProfile.release > 0 else { return [] }
    return currentProfile.tones.map { Tone(hz: $0.hz * 0.82, amp: $0.amp * 0.6, ms: $0.ms, delay: $0.delay) }
}
