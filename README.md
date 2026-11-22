# thockpad

**Make your MacBook's trackpad thock like a mechanical keyboard.**

thockpad listens to your real keystrokes and fires the trackpad's haptic motor once per press — the Force
Touch "click" motor — tuned into the sound of a mechanical keyboard. It's a fork of
[nospeaker](https://github.com/os6/nospeaker), which showed that the trackpad motor, driven up to 4 kHz,
can make *sounds*, not just clicks. thockpad uses that as an engine: no sample files, no speakers, no audio
device. One or two sine tones, a few milliseconds each, straight to the motor.

```
        ┌────────────┐   CGEventTap   ┌────────────┐   MultitouchSupport   ┌─────────┐
keys ──▶│ your Mac   │───────────────▶│ thockpad   │──────────────────────▶│ motor   │──▶ thock
        └────────────┘  key down/up   │ 15 ms gate │   2 tones / click     └─────────┘
```

## Download

**The compiled app lives in [Releases →](https://github.com/dkiiv/thockpad/releases/latest)** —
download `Thockpad.zip`, unzip, and open **Thockpad.app**.

> The build is signed ad-hoc (no Apple Developer ID), so macOS won't open it with a double-click the first
> time: **right-click the app → Open → Open**. That's a one-time thing for this build.
> Needs an Apple Silicon MacBook with a Force Touch trackpad (2015+) on macOS 12 or newer.

## Run it

Open **Thockpad.app**. A window appears and your next keystroke clicks.

- **The red X does not quit.** The window closes, the Dock icon disappears, and thockpad keeps clicking
  from the **menu bar** (a small keyboard icon, top right). Open the menu there to switch profiles, set the
  level, pause, or **Exit thockpad** — the only way it stops.
- The first launch asks for **Input Monitoring**: allow it in the System Settings pane that opens, then
  *Restart thockpad* from the menu bar item (a fresh grant only applies to a new process).
- Everything you set is remembered for the next launch.
- Mute the Mac — the sound comes out of the trackpad glass. On a table it's much louder than on your lap.

From source:

```sh
git clone https://github.com/dkiiv/thockpad
cd thockpad
./build.sh                # builds ./build/thockpad, ./build/nospeaker, ./build/Thockpad.app
open build/Thockpad.app   # or right-click → Open the first time
```

## The CLI

The same engine without a window, for scripts and testing:

```sh
./build/thockpad --cli                    # click in the terminal until ctrl-c
./build/thockpad --list                   # the click profiles
./build/thockpad --profile blue           # pick one
./build/thockpad --level 0.6              # quieter
./build/thockpad --no-release             # no bottom-out tock
./build/thockpad --talk                   # says a word on space, "done" on return (via nospeaker)
./build/thockpad --swallow                # your real typing goes nowhere, only clicks (testing!)
./build/thockpad --verbose --chatter      # print each key + startup line
./build/thockpad --selftest               # one synthetic keypress, proves the click loop
./build/thockpad --run 60                 # quit by itself after 60 s and print stats
./build/nospeaker "hello"                 # the parent project: the trackpad talks
```

Ctrl-C stops the CLI; `kill -USR1 <pid>` prints how you're doing (presses, releases, keys/second).
Both modes start **silently**: no startup sound, no terminal chatter unless you ask for it.
Flags override saved GUI settings; without flags the binary opens the app.

## How a click is made

A profile is a list of tones — frequency, strength, length, offset — played through nospeaker's
`play()`:

| profile  | the idea                  | tones                                   |
|----------|---------------------------|-----------------------------------------|
| brown    | tactile bump              | 1400 Hz / 7 ms + 380 Hz / 18 ms         |
| blue     | clicky                    | 2200 Hz / 5 ms + 240 Hz / 14 ms         |
| red      | linear, quiet             | 900 Hz / 6 ms                           |
| thock    | deep marbly (the good one)| 520 Hz / 8 ms + 140 Hz / 34 ms          |
| click    | membrane pop              | 1700 Hz / 4 ms + 1050 Hz / 7 ms         |
| marble   | glassy tock               | 1900 Hz / 4 ms + 2800 Hz / 6 ms         |

nospeaker measured this motor to be loud from ~100 Hz to 4 kHz and cleanest near 1 kHz, which is the
register a keyboard click lives in. Every key gets a fixed detune from its keycode plus slow drift, so a
burst of typing sounds like a board, not a machine gun; space bars and shifts drop ~22 % in pitch and
stretch, because big keys sound bigger. A key-up adds a quieter, lower "tock".

Two engineering notes:

- **15 ms floor.** The motor can't mix two actuations, and nospeaker restarts it per call. Anything within
  15 ms of the previous click is dropped rather than queued (the queue itself is capped at 3 clicks) —
  holding a key or pasting a paragraph stays in time and never backs up.
- **The tap is passive by default.** thockpad listens at the session event tap and passes every event
  through, so typing latency is untouched and nothing about your Mac changes. `--swallow` (which drops
  key-downs so only the clicks happen — good for hearing a single profile cleanly) never drops key-*up*s:
  a lost release sticks modifiers.

## The fork

`nospeaker/engine.swift` is upstream's `nospeaker.swift` with two changes, and everything under
`nospeaker/` is upstream:

1. its `// MARK: - Main` block moved to `nospeaker/main.swift`, so the engine is declarations-only and
   compiles into two programs (`thockpad`, `nospeaker`);
2. the clock globals (`timebase`, `ticksPerSecond`, `t0`) became plain `nonisolated(unsafe)` vars set by
   `startClock()`, called first thing by each entry point. Reason found the hard way: on Swift 6.1, a
   *lazy* global in a non-`main.swift` file traps (SIGTRAP, no message) on first read — reproduced in a
   20-line two-file case; eager init from the entry point works.

thockpad's own files: `clicks.swift` (profiles, tone math, `playClick`), `keys.swift` (event tap,
permission, stats), `talk.swift` (the `--talk` words, through nospeaker's voice engine),
`settings.swift` (remembered settings) and `gui.swift` (the window and the menu bar item — plain AppKit, no
Xcode project; `scripts/make-app.sh` wraps the binary into `Thockpad.app`, and `scripts/release.sh`
publishes it to Releases).

## Tested on

```
MacBook Pro 14" (MacBookPro18,3)   M1 Pro   macOS 27.0.1   177 real keystrokes → clicks ✓ (5 keys/s, 12 throttled)
the app (window + menu bar)        close → menu bar, Try a click → 2 actuations ✓, Exit → quit ✓
settings you change                persist to disk and reload ✓
nospeaker (upstream show)          still builds and talks from the split engine        ✓
Input Monitoring grant             survives rebuilds with a new cdhash (signed id)     ✓
```

Not tested: Intel Macs, Magic Trackpad, other macOS versions — same caveats as upstream, since it's the
same private `MultitouchSupport` calls. If it doesn't work on your Mac, upstream's issue tracker is
probably the place anyway.

## Building a release

```sh
VERSION=1.0 ./scripts/release.sh     # builds, bundles, zips, uploads Thockpad.zip to the GitHub release
```

It needs a GitHub token with repo access (from `GH_TOKEN` or your git credential store). The app is ad-hoc
signed with the stable identifier `com.dkiiv.thockpad`; notarization (a Developer ID) is a possible
upgrade that would remove the right-click→Open step for downloaded builds.

## Caveats

- `MultitouchSupport` is private and undocumented; a macOS update can break this. (Upstream's caveat,
  inherited whole.)
- thockpad needs Input Monitoring to hear the keyboard. It stores only the settings you set in the window
  (profile, level, tocks, talk, swallow, paused) in `~/Library/Preferences/com.dkiiv.thockpad.settings.plist`;
  keystrokes and stats live in memory only.
- The motor is never driven past its normal maximum strength — same rule as upstream.

## License

MIT, same as upstream — see `LICENSE`. nospeaker is © Cody Collier / a90.com;
`nospeaker/README.md` is its original readme.
