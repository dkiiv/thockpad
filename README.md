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
                                      └────────────┘
```

```
[ mute your mac ]        it still clicks; that's the point
[ on a table ]           on your lap it's much quieter
```

## Run it

```sh
./build.sh                # builds ./build/thockpad (and ./build/nospeaker, the fork's parent)
./build/thockpad          # start clicking (silent start — just type)
```

macOS asks for **Input Monitoring** the first time: allow it in System Settings → Privacy & Security →
Input Monitoring, then start thockpad again (a fresh grant only applies to a new process). `./build.sh`
signs each build with a stable identifier (`com.dkiiv.thockpad`) so the grant survives recompiling —
without that, every rebuild asks again. `./scripts/permissions.sh --check` tells you where you stand.

## Play with it

```sh
./build/thockpad --list                # the click profiles
./build/thockpad --profile blue        # clicky: bright snap
./build/thockpad --profile thock       # deep marbly thock (the default)
./build/thockpad --level 0.6           # quieter clicks
./build/thockpad --no-release          # no bottom-out tock on key-up
./build/thockpad --talk                # it says a word on space, "done" on return (via nospeaker)
./build/thockpad --verbose             # print each key as it clicks
./build/thockpad --swallow             # your real typing goes nowhere, only clicks (testing!)
./build/thockpad --selftest            # one synthetic keypress, proves the click loop
./build/thockpad --run 60              # quit by itself after 60 s and print stats
```

Ctrl-C stops it. `kill -USR1 <pid>` prints how you're doing (presses, releases, keys/second).
It starts and runs **silently**: no startup sound, no terminal chatter unless you ask for it.

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
permission, stats), `talk.swift` (the `--talk` words, through nospeaker's voice engine).

## Tested on

```
MacBook Pro 14" (MacBookPro18,3)   M1 Pro   macOS 27.0.1   177 real keystrokes → clicks ✓ (5 keys/s, 12 throttled)
nospeaker (upstream show)          still builds and talks from the split engine        ✓
Input Monitoring grant             survives rebuilds with a new cdhash (signed id)     ✓
```

Not tested: Intel Macs, Magic Trackpad, other macOS versions — same caveats as upstream, since it's the
same private `MultitouchSupport` calls. If it doesn't work on your Mac, upstream's issue tracker is
probably the place anyway.

## Caveats

- `MultitouchSupport` is private and undocumented; a macOS update can break this. (Upstream's caveat,
  inherited whole.)
- thockpad needs Input Monitoring. It runs in the background and stores nothing; the stats are printed on
  request and live in memory only.
- The motor is never driven past its normal maximum strength — same rule as upstream.

## License

MIT, same as upstream — see `LICENSE`. nospeaker is © Cody Collier / a90.com;
`nospeaker/README.md` is its original readme.
