// thockpad — remembered settings.
//
// The GUI is the front door, so what you dial in (profile, level, tocks, talk, paused) has to be there when
// you open the app again. The CLI picks the same store up, and flags on top win.

import Foundation

// A suite name of our own — deliberately NOT the bundle id: UserDefaults refuses to use a running app's own
// identifier as a suite (it traps with “does not make sense and will not work”). This lands in
// ~/Library/Preferences/com.dkiiv.thockpad.settings.plist and is shared by the app and the bare CLI binary.
let settingsDomain = "com.dkiiv.thockpad.settings"

func loadSettings() {
    let d = UserDefaults(suiteName: settingsDomain)!
    if let p = d.string(forKey: "profile"), profiles[p] != nil { setProfile(p) }
    if d.object(forKey: "level") != nil { gain = Float(max(0.1, min(1, d.double(forKey: "level")))) }
    if d.object(forKey: "release") != nil { releaseOn = d.bool(forKey: "release") }
    if d.object(forKey: "talk") != nil { talkEnabled = d.bool(forKey: "talk") }
    if d.object(forKey: "paused") != nil { paused = d.bool(forKey: "paused") }
}

func saveSettings() {
    let d = UserDefaults(suiteName: settingsDomain)!
    d.set(profileName, forKey: "profile")
    d.set(Double(gain), forKey: "level")
    d.set(releaseOn, forKey: "release")
    d.set(talkEnabled, forKey: "talk")
    d.set(paused, forKey: "paused")
}
