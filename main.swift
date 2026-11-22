// thockpad — command-line entry point: parse the options and choose the mode.
//
// No flags opens the GUI — that's the normal way (double-clicking Thockpad.app arrives here too). Any flag
// runs the plain CLI engine instead: good for scripts, testing, and running headless. Settings you dial in
// the GUI are remembered (settings.swift) and shared with the CLI, flags on top win.

import Darwin
import Foundation

func help() -> Never {
    print("""
    THOCKPAD · make your MacBook's trackpad thock like a mechanical keyboard
    A fork of nospeaker (a90.com) that drives the trackpad's haptic motor from your keystrokes.

      thockpad                      open the app (window + menu bar item — the normal way)
      thockpad --cli                no window: click in the terminal until ctrl-c
      thockpad --profile blue …     the CLI, tuned by flags

    CLI options
      --cli                           run in the terminal instead of opening the app
      --profile <name>                \(profileOrder.joined(separator: ", ")) (default “thock”)
      --level <0.1-1>                 how loud a click is
      --no-release                    press clicks only, no bottom-out tock
      --swallow                       your real typing goes nowhere: only the clicks (testing)
      --talk                          the trackpad talks while you type
      --verbose                       print each key as it clicks
      --chatter                       print a startup line (silent otherwise)
      --selftest                      one synthetic keypress, then report
      --run <seconds>                 quit by itself after this long and print stats (for testing)
      --list                          the click profiles
      --help, -h                      this

    Ctrl-C stops the CLI. kill -USR1 <pid> prints how you're doing.
    Needs Input Monitoring: macOS asks on the first run, then start thockpad again.
    Mute the Mac — the sound comes out of the trackpad glass. A table beats a lap.
    """)
    exit(0)
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(("\n  thockpad: " + message + "\n\n  See thockpad --help.\n").data(using: .utf8)!)
    exit(64)
}

extension String {
    func padded(to n: Int) -> String { count >= n ? self : self + String(repeating: " ", count: n - count) }
}

startClock()   // before anything touches now() / ticksPerSecond

var args = Array(CommandLine.arguments.dropFirst())
// An old-style LaunchServices argument, if the app is ever started with one: never a real option.
args.removeAll { $0.hasPrefix("-psn_") }
if args.contains("--help") || args.contains("-h") { help() }

func option(_ flag: String, _ example: String) -> String? {
    guard let i = args.firstIndex(of: flag) else { return nil }
    guard i + 1 < args.count, !args[i + 1].hasPrefix("-") else { die("\(flag) needs a value, like: \(flag) \(example)") }
    let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
}
func takeFlag(_ f: String) -> Bool { if let i = args.firstIndex(of: f) { args.remove(at: i); return true }; return false }

if args.contains("--list") {
    print("\n  click profiles (a click is one or two tones on the motor)\n")
    for name in profileOrder {
        let p = profiles[name]!
        let tones = p.tones.map { "\(Int($0.hz)) Hz/\(Int($0.ms)) ms" }.joined(separator: " + ")
        print("  \(name.padded(to: 8)) \(p.blurb.padded(to: 38)) \(tones)\(p.release > 0 ? "  (+tock)" : "")")
    }
    print("\n  thockpad --profile thock\n")
    exit(0)
}

// Remembered GUI settings are the starting point; flags below win.
loadSettings()
let bare = args.isEmpty

if let name = option("--profile", "blue") {
    guard profiles[name] != nil else { die("no click profile called “\(name)”: \(profileOrder.joined(separator: ", "))") }
    setProfile(name)
}
if let l = option("--level", "0.6") {
    guard let v = Float(l), v > 0, v <= 1 else { die("--level wants a number from 0.1 to 1, not “\(l)”") }
    gain = v
}
if takeFlag("--no-release") { releaseOn = false }
if takeFlag("--talk") { talkEnabled = true }
if takeFlag("--swallow") { swallowKeys = true }
verbose = takeFlag("--verbose")
chatter = takeFlag("--chatter") || verbose
let wantsSelfTest = takeFlag("--selftest")
var runSeconds = 0.0
if let n = option("--run", "20") {
    guard let v = Double(n), v > 0, v <= 3600 else { die("--run wants seconds, like: --run 20") }
    runSeconds = v
}
let cli = takeFlag("--cli")
if let unknown = args.first(where: { $0.hasPrefix("-") }) { die("“\(unknown)” isn't an option") }
if !args.isEmpty { die("thockpad doesn't take words — it clicks. (nospeaker is the one that talks)") }

// No flags at all: open the app window (and the menu bar item it hides into). runGUI never returns.
if bare { runGUI() }

if runSeconds > 0 { chatter = true; startTimer(runSeconds) }
exit(wantsSelfTest ? selfTest() : runThockpad())
