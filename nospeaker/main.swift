// nospeaker · a90.com — command-line entry point.
//
// The engine (motor, speech analysis, the show) is nospeaker.swift; this file is argument parsing and the
// choice of what to play. They compile together:  swiftc -O nospeaker.swift main.swift -o nospeaker
// Split out verbatim from the upstream single file so nospeaker.swift holds only declarations and can be
// compiled with thockpad/ instead.

import AVFoundation
import CoreAudio
import Darwin
import IOKit
import Foundation

// MARK: - Main

startClock()   // before anything touches now() / ticksPerSecond

var args = Array(CommandLine.arguments.dropFirst())
/// The value after `flag` (and removes both), or nil if the flag isn't there. A flag with no value is a mistake.
func option(_ flag: String, example: String) -> String? {
    guard let i = args.firstIndex(of: flag) else { return nil }
    guard i + 1 < args.count, !args[i + 1].hasPrefix("-") else { usageError("\(flag) needs a value, like: \(flag) \(example)") }
    let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
}
func flag(_ f: String) -> Bool { if let i = args.firstIndex(of: f) { args.remove(at: i); return true }; return false }

if flag("--help") || flag("-h") {
    print("""
    NO SPEAKER · a90.com presents
    Your MacBook's trackpad has no speaker. This makes it talk anyway, through its haptic motor.

      nospeaker                         the show (space skips a part, q goes to the end)
      nospeaker "any words"             just say something
      nospeaker --sweep                 a rising tone, 100 Hz to 4 kHz
      --voice Daniel                    any voice from `say -v '?'`
      --dark                            white on black instead of black on white
      --plain                           no visuals

    Mute your Mac: it still talks. Put it on a table, and keep your hands off the trackpad until it asks.
    a90.com · x.com/codycollier
    """)
    exit(0)
}

voiceName = option("--voice", example: "Daniel")
if let v = voiceName, !voiceExists(v) {
    fail("There's no voice called \"\(v)\" on this Mac.\nList the voices you have with: say -v '?'", headline: "nospeaker can't use that voice.", code: 64)
}
applyTheme(light: !flag("--dark"))
let plain = flag("--plain")
let wantsSweep = flag("--sweep")
if let unknown = args.first(where: { $0.hasPrefix("-") }) { usageError("\"\(unknown)\" isn't an option.") }

signal(SIGINT) { _ in requestEnd() }
signal(SIGTERM) { _ in stopRequested = true }
atexit { restoreTerminal() }

motor = openMotor()
motorPointer = Unmanaged.passUnretained(motor! as AnyObject).toOpaque()

if wantsSweep || !args.isEmpty {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
    if wantsSweep { print("sweeping 100 Hz → 4 kHz…"); sweep(seconds: 5) }
    if !args.isEmpty {
        let text = args.joined(separator: " ")
        let frames = render(text)
        print("trackpad: “\(text)”")
        talk(frames, text: text)
    }
} else {
    let interactive = isatty(STDOUT_FILENO) == 1 && isatty(STDIN_FILENO) == 1
    // Too small a window: say so, and start by itself as soon as it's big enough.
    if !plain && interactive {
        var size = terminalSize()
        if size.w < 80 || size.h < 24 {
            print("\n  nospeaker needs a slightly bigger window: at least 80 × 24.")
            print("  Drag the window's corner to make it bigger, and it starts by itself.  (ctrl-c to stop)\n")
            while (size.w < 80 || size.h < 24) && !stopRequested && !jumpToCredits {
                usleep(200_000)
                size = terminalSize()
            }
            if stopRequested || jumpToCredits { exit(0) }
        }
    }
    let size = terminalSize()
    let visuals = !plain && interactive && size.w >= 80 && size.h >= 24
    show(visuals: visuals)
}
usleep(120_000)
if let motor { _ = actuatorClose?(motor) }
