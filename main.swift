// thockpad — make your MacBook's trackpad thock like a mechanical keyboard.
//
// Command-line entry: read the options, then run (or self-test). The click sounds are in clicks.swift, the
// keyboard listening in keys.swift, the talking in talk.swift, and the haptic motor in nospeaker/engine.swift.

import Darwin
import Foundation

func help() -> Never {
    print("""
    THOCKPAD · make your MacBook's trackpad thock like a mechanical keyboard
    A fork of nospeaker (a90.com) that drives the trackpad's haptic motor from your keystrokes.

      thockpad                      click on every keypress (default: “\(profileName)”)
      thockpad --list               the click profiles
      thockpad --profile blue       pick one
      thockpad --talk               it also says a word on space, finishes one on return
      thockpad --selftest           prove the click loop works without typing

    Options
      --profile <name>              \(profileOrder.joined(separator: ", "))
      --level <0.1-1>               how loud a click is (default \(String(format: "%.2f", gain)))
      --no-release                  press clicks only, no bottom-out tock
      --swallow                     your real typing goes nowhere: only the clicks (testing)
      --talk                        the trackpad talks while you type
      --verbose                     print each key as it clicks
      --chatter                     print a startup line (thockpad is silent by default)
      --selftest                      one synthetic keypress, then report
      --run <seconds>                 quit by itself after this long and print stats (for testing)
      --help, -h                    this

    Ctrl-C stops it. kill -USR1 <pid> prints how you're doing.

    It needs Input Monitoring: macOS asks on the first run, then start it again.
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

if let name = option("--profile", "blue") {
    guard profiles[name] != nil else { die("no click profile called “\(name)”: \(profileOrder.joined(separator: ", "))") }
    setProfile(name)
}
if let l = option("--level", "0.6") {
    guard let v = Float(l), v > 0, v <= 1 else { die("--level wants a number from 0.1 to 1, not “\(l)”") }
    gain = v
}
if takeFlag("--no-release") { releaseGain = 0 }
talkEnabled = takeFlag("--talk")
passThrough = !takeFlag("--swallow")
verbose = takeFlag("--verbose")
chatter = takeFlag("--chatter") || verbose
let wantsSelfTest = takeFlag("--selftest")
var runSeconds = 0.0
if let n = option("--run", "20") {
    guard let v = Double(n), v > 0, v <= 3600 else { die("--run wants seconds, like: --run 20") }
    runSeconds = v
}
if let unknown = args.first(where: { $0.hasPrefix("-") }) { die("“\(unknown)” isn't an option") }
if !args.isEmpty { die("thockpad doesn't take words — it clicks. (nospeaker is the one that talks)") }

if runSeconds > 0 { chatter = true; startTimer(runSeconds) }
exit(wantsSelfTest ? selfTest() : runThockpad())
