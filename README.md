# thockpad

**Make your MacBook's trackpad thock like a mechanical keyboard.**

thockpad listens to your real keystrokes and fires the trackpad's haptic motor once per press — the Force
Touch "click" motor — tuned into the sound of a mechanical keyboard. It's a fork of
[nospeaker](https://github.com/os6/nospeaker), which showed that the trackpad motor, driven up to 4 kHz,
can make *sounds*, not just clicks. thockpad uses that as an engine: no sample files, no speakers, no audio
device. One or two sine tones, a few milliseconds each, straight to the motor.

```
        ┌────────────┐  key state ~6 ms ┌────────────┐   MultitouchSupport   ┌─────────┐
keys ──▶│ your Mac   │─────────────────▶│ thockpad   │──────────────────────▶│ motor   │──▶ thock
        └────────────┘  polls, no tap   │drvr budget │   2 tones / click     └─────────┘
```

**thockpad needs no permissions at all.** It reads Apple's key-state API (`CGEventSource.keyState`) and
clicks on the edges — that query is not Input Monitoring, so nothing to allow in System
Settings, nothing that can break between rebuilds, nothing that touches your keystrokes. Install and type.

## Download

**The compiled app lives in [Releases →](https://github.com/dkiiv/thockpad/releases/latest)** —
download `Thockpad.zip`, unzip, and open **Thockpad.app**.

> The build is signed ad-hoc (no Apple Developer ID), so macOS won't open it with a double-click the first
> time: **right-click the app → Open → Open**. That's a one-time thing for this build — the *only* prompt
> thockpad ever gives you.
> Needs a MacBook with a Force Touch trackpad (2015+) on macOS 12 or newer.

## Run it

Open **Thockpad.app**. A window appears and your next keystroke clicks.

- **The red X does not quit.** The window closes, the Dock icon disappears, and thockpad keeps clicking
  from the **menu bar** (a small keyboard icon, top right). Open the menu there to switch profiles, set the
  level, pause, or **Exit thockpad** — the only way it stops.
- No permission prompts, then or ever. If the window says it can't find a trackpad motor, that's hardware,
  not settings.
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
./build/thockpad --verbose --chatter      # print each key + startup line
./build/thockpad --selftest               # start listening, prove a keypress clicks, then report
./build/thockpad --run 60                 # quit by itself after 60 s and print stats
./build/nospeaker "hello"                 # the parent project: the trackpad talks
```

Ctrl-C stops the CLI; `kill -USR1 <pid>` prints how you're doing (keys heard, clicks played, and why any
were dropped).
Both modes start **silently**: no startup sound, no terminal chatter unless you ask for it.
Flags override saved GUI settings; without flags the binary opens the app.

## If it misbehaves

| symptom                       | cause and fix                                                                                              |
|-------------------------------|------------------------------------------------------------------------------------------------------------|
| **every key thocks twice**    | two engines running — the usual cause is keeping both the downloaded `Thockpad.app` and a `build/` copy. Only one launches per bundle now (a second launch wakes the first), so check for a stale copy in `/Applications` **and** `~/Downloads`, and quit them all. |
| **a burst of thocks after the app sat idle, or when you open its window** | the machine slept or the process was frozen; those keys are history, not keystrokes, and clicks over 80 ms late are dropped. Thockpad now runs with App Nap disabled, which is what used to cause it. |
| **some keys silent while typing very fast** | that's the sound budget, not the listener: the window/menu counts `heard`, `clicked` and `refused` separately, so if `heard` matches your keystrokes the keyboard side is fine and the motor was simply still busy. A quieter profile (`red`, `click`) has a shorter click and allows a faster rate. |
| **no sound at all**           | the menu says `not listening` → press *Restart thockpad*. If it says a motor can't be found, that's a trackpad without Force Touch. Otherwise: mute the Mac and put it on a table — the sound is tiny and comes out of the glass. |

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

- **The motor has a budget.** One click is ONE actuation (all tones in one dictionary, like nospeaker's
  formants) and costs ~4 ms of driver time; the driver wants 15 ms between actuations, so ~66 clicks a
  second — more than any typing. Presses faster than that overlap and the later click truncates the earlier
  tail, the way a real board blurs at speed. What a click must never do is queue: a click over 80 ms old is
  dropped, because late sound reads as the app making noise on its own.
- **Watching, not tapping.** `CGEventSource.keyState` answers "is this key down right now?" for every
  physical key without Input Monitoring, and it can't interfere with typing — thockpad only reads state.
  Measured on this M1: the 128 queries cost ~0.00 ms, but *waiting* is the floor — macOS sleeps never wake
  faster than ~5.8 ms whatever you ask for, so the loop really runs ~170 passes a second (not the 500 the
  first version's comments claimed), about 1 % of one core, and still 6–30× faster than the 30–100 ms a key
  is held. The window says what it's doing: keys heard, clicks played, and why any were dropped.

## The fork

`nospeaker/engine.swift` is upstream's `nospeaker.swift` with two changes, and everything under
`nospeaker/` is upstream:

1. its `// MARK: - Main` block moved to `nospeaker/main.swift`, so the engine is declarations-only and
   compiles into two programs (`thockpad`, `nospeaker`);
2. the clock globals (`timebase`, `ticksPerSecond`, `t0`) became plain `nonisolated(unsafe)` vars set by
   `startClock()`, called first thing by each entry point. Reason found the hard way: on Swift 6.1, a
   *lazy* global in a non-`main.swift` file traps (SIGTRAP, no message) on first read — reproduced in a
   20-line two-file case; eager init from the entry point works.

thockpad's own files: `clicks.swift` (profiles, tone math, `playClick`), `keys.swift` (the key-state poller,
the click queue, motor probe, stats), `talk.swift` (the `--talk` words, through nospeaker's voice engine),
`settings.swift` (remembered settings) and `gui.swift` (the window and the menu bar item — plain AppKit, no
Xcode project; `scripts/make-app.sh` wraps the binary into `Thockpad.app`, and `scripts/release.sh`
publishes it to Releases).

> **Why polling, not an event tap.** The first version of thockpad used `CGEvent.tapCreate`, which needs
> Input Monitoring. In practice that turned out to be a trap: ad-hoc-signed binaries are pinned to a cdhash
> that changes every build, so grants strand on every recompile, prompts get suppressed after a few cycles,
> and the box ticks without ever working. Apple's key-state query does the same job — know every key that
> goes down and up — with no permission, no prompt, and no state that can go stale between builds.

## Tested on

```
MacBook Pro 14" (MacBookPro18,3)  M1 Pro  macOS 27.0.1  app clicks keystrokes with zero permissions ✓
poll loop                         ~170 passes/s (5.8 ms kernel sleep floor), ~1 % of one core ✓
the app (window + menu bar)       close → menu bar, Try a click ✓, Exit ✓; second launch wakes the
                                  first instead of stacking a second engine ✓
App Nap                           NSAppSleepDisabled + .latencyCritical (a napped poller = silent keys) ✓
settings you change               persist to disk and reload ✓
nospeaker (upstream show)         still builds and talks from the split engine ✓
Input Monitoring                  not needed, not asked for, not in the code anymore
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
- thockpad stores only the settings you set in the window (profile, level, tocks, talk, paused) in
  `~/Library/Preferences/com.dkiiv.thockpad.settings.plist`. It cannot see what you type: key-state
  polling answers "which keys are down right now?" for at most a 2 ms slice of time, nothing is logged,
  and stats live in memory only.
- The motor is never driven past its normal maximum strength — same rule as upstream.

## License

MIT, same as upstream — see `LICENSE`. nospeaker is © Cody Collier / a90.com;
`nospeaker/README.md` is its original readme.
