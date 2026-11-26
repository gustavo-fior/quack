# Quack

A macOS menu bar app that plays mechanical keyboard sounds as you type.

## Send to your clanker

Copy this into Claude Code, Codex or any other coding agent on your Mac:

````text
Install Quack, a macOS menu bar app that plays mechanical keyboard sounds as I type.

1. Check that this is a Mac running macOS 26 or later with Xcode command line tools (`xcode-select -p`). If the tools are missing, run `xcode-select --install` and wait for it to finish.
2. Clone https://github.com/gustavo-fior/quack into ~/Developer/quack, or pull the latest if it already exists.
3. From that folder, run `./scripts/build-app.sh --run`. This builds build/Quack.app and opens it.
4. Quack needs Input Monitoring to hear key presses. If it isn't listed or switched on under System Settings → Privacy & Security → Input Monitoring, tell me to turn it on there. Don't change that setting yourself.
5. When it's done, tell me the switch pack that's selected and how to turn Quack on and off (⌃⌥⌘K by default).
````

## Build and run

```sh
./scripts/build-app.sh --run
```

This builds `build/Quack.app` and opens it. On first launch Quack asks for
Input Monitoring (System Settings, Privacy & Security, Input Monitoring), which
is how it knows a key moved.

The app is signed ad hoc, so macOS treats every rebuild as a new app and asks
for Input Monitoring again (the build script clears the stale grant so the
prompt comes back cleanly). To avoid that, sign with a real identity:

```sh
QUACK_SIGN_IDENTITY="Apple Development: …" ./scripts/build-app.sh --run
```

## What it does

- Thirteen recorded switches: Gateron Black Ink and Red Ink, NovelKeys Cream,
  Cherry MX Black, Brown and Blue, Alpaca, Turquoise Tealios, Holy Panda, Topre,
  Kailh Box Navy, Alps Blue and Buckling Spring. Plus a synthesized duck.
- Separate press and release recordings, a different one for each keyboard row,
  and dedicated ones for space, return and backspace.
- Stereo placement by key position, random pitch variation, and a tone pad to
  tune each switch's pitch and brightness.
- Optional mouse click and scroll sounds.
- Sleeps while the microphone is in use or while chosen apps are in front.
- Global shortcut to turn it on and off (⌃⌥⌘K by default), open at login,
  output device selection, and daily typing stats.

Quack counts key presses for the stats. It never stores or sends which keys
you press.

## Checking it without the speakers

```sh
# run from the project folder so the recordings are found
.build/release/Quack --selftest            # recording and mixer checks
.build/release/Quack --selftest /some/dir  # also writes a WAV per switch
.build/release/Quack --bench               # silent latency benchmark of key press to sound
.build/release/Quack --bench --device "MacBook Pro Speakers"   # same, on a named output
```

## Layout

| File | Role |
| --- | --- |
| `Packs.swift` | Switch list, loading and levelling of the recordings |
| `Synth.swift` | The duck |
| `Resources/Sounds` | Switch recordings from [kbsim](https://github.com/tplai/kbsim), MIT licensed |
| `AudioMixer.swift` | Audio engine with a hand-written voice mixer |
| `KeyTap.swift` | Listen-only event tap on its own thread |
| `Player.swift` | Maps input events to sounds |
| `AppState.swift` | Settings, permission, sleep triggers |
| `MenuPanel.swift`, `SettingsView.swift`, `App.swift` | Interface |
