// thockpad — the optional party trick: your trackpad talks while you type.
//
// With --talk, space says a random word and return finishes one, using nospeaker's voice engine (say →
// formants → two tones on the motor). Words are synthesised once and cached, and spoken on one background
// queue, so a keystroke never waits on `say` and clicks keep playing while a word is mid-sentence.

import Foundation

let wordBank = """
thock thocky clack clackety click tock boop yes no hello trackpad keyboard motor glass thump tap
rattle snap knock bonk tickety clickety
""".split(separator: " ").map(String.init)

let finishers = ["done", "finished", "sent", "ok", "there we go", "nice", "clack"]

let talkLock = NSLock()
var wordQueue: [String] = []
var talkBusy = false

func queueWord(_ text: String) {
    guard talkEnabled else { return }
    talkLock.lock()
    wordQueue.append(text)
    let startWorker = !talkBusy
    talkBusy = true
    talkLock.unlock()
    guard startWorker else { return }
    Thread {
        while true {
            talkLock.lock(); let next = wordQueue.first; talkLock.unlock()
            guard let w = next else { talkLock.lock(); talkBusy = false; talkLock.unlock(); return }
            speakWord(w)
            talkLock.lock(); if !wordQueue.isEmpty { wordQueue.removeFirst() }; talkLock.unlock()
        }
    }.start()
}

var wordCache: [String: [Frame]] = [:]
let wordCacheLock = NSLock()

func speakWord(_ w: String) {
    wordCacheLock.lock()
    let frames: [Frame]
    if let f = wordCache[w] { frames = f } else { frames = render(w); wordCache[w] = frames }
    wordCacheLock.unlock()
    statsLock.lock(); stats.spoken += 1; statsLock.unlock()
    talk(frames, text: w)
}

/// Synthesise every word in the bank once, up front: the first space bar shouldn't pay for `say`, and this
/// doubles as a check that macOS's voice actually works before thockpad starts clicking.
/// (A machine with a broken `say` exits inside render(), with nospeaker's own explanation.)
func warmVoice() {
    guard talkEnabled else { return }
    say("thockpad: warming the voice (a second, once per word)…")
    for w in Set(wordBank + finishers) {
        let frames = render(w)
        wordCacheLock.lock(); wordCache[w] = frames; wordCacheLock.unlock()
    }
    let longest = Double(wordCache.values.map { $0.count }.max() ?? 0) * hop
    say("thockpad: voice ready — \(wordCache.count) words, longest \(String(format: "%.1f", longest))s.")
}
