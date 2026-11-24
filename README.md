# InstantFn

A tiny native menu-bar utility: a short press of **Fn/🌐** switches to the **next input source** immediately
(EN → RU → ES → … → EN, through everything enabled in Keyboard Settings; with two sources it's a toggle),
using `TISSelectInputSource` directly. No keystrokes are injected and nothing else on the keyboard is touched.

## Build

| How | Command |
|---|---|
| Command Line Tools only | `./build.sh` (Debug, shows latency diagnostics) · `./build.sh release` |
| Xcode | open `InstantFn.xcodeproj`, scheme InstantFn, Run |

Output: `build/<config>/InstantFn.app`. For daily use, copy the Release build to `/Applications`
(Launch at Login works best from there).

**Code signing and the permission:** macOS ties the Input Monitoring grant to the app's code signature.
An ad-hoc ("Sign to Run Locally") build gets a new signature every time you rebuild, so you have to grant
the permission again after each rebuild. For a stable grant, sign with a fixed identity
(an Apple Development certificate in Xcode, or a self-signed code-signing certificate from Keychain Access):
`SIGN_ID="Your Cert Name" ./build.sh release`.

## One-time setup

1. **System Settings → Keyboard → "Press 🌐 key to" → Do Nothing.**
   If it is set to *Change Input Source* (as it is on this Mac right now: `AppleFnUsageType = 1`), macOS switches
   too, so every press switches twice and nothing seems to happen. InstantFn detects this, **pauses switching**,
   and shows `⚠︎` in the menu bar until you change the setting. InstantFn only *reads* this setting and never changes it.
2. **Grant Input Monitoring** when prompted (or: Privacy & Security → Input Monitoring → enable InstantFn).
3. Enable the input sources you want in Keyboard Settings → Text Input. InstantFn reads them live
   (here: `com.apple.keylayout.US` and `com.apple.keylayout.RussianWin`) and cycles in the order macOS
   reports them, which normally matches the list in Keyboard Settings. The menu shows the order ("Fn cycles: EN → RU").
   Input methods with several modes (for example Japanese Kana/Romaji) count as one source per enabled mode.

## How it works (and why it's safe)

```
HID → WindowServer ──(copy)──► listen-only CGEventTap on its own thread (FnTapMonitor)
                                   │  Fn released, nothing else happened, held < 600 ms
                                   ▼
                              main queue → TISSelectInputSource(target)   (InputSourceSwitcher)
```

- **Detection.** Fn is a modifier, so pressing or releasing it produces a `flagsChanged` event with keycode
  `kVK_Function` (0x3F), and `maskSecondaryFn` tells you up from down. The flag alone is *not* used: macOS also sets it
  on arrow, F-row, Home and End key events.
- **What counts as a tap.** InstantFn switches on Fn **release**, and only when, while Fn was held:
  - no key went down,
  - no other modifier changed (Shift, Ctrl, Opt, Cmd, Caps Lock),
  - no mouse button was pressed,
  - and it was held for less than 600 ms.

  That leaves every Fn+key shortcut (F-keys, arrows, Fn+E/F/C/A/N/Q…) to macOS. Holding Fn can't repeat-switch,
  because `flagsChanged` doesn't auto-repeat and there is exactly one release.
- **Why on release?** On press, it's impossible to know yet whether you're starting a combo. So the time Fn is
  held is part of the user-perceived delay. The latency below starts from the release.
- **Correctness under rapid presses.** All switching is serialized on the main queue, and each toggle reads the live
  current source instead of a cached guess, so it never drifts out of sync.
- **Resync.** If the tap is disabled by the system (timeout or user input), or the Mac wakes, or the session changes,
  any half-finished press is dropped and the tap is re-enabled. A keyDown without the Fn bit also proves Fn is up.
  Keyboard reconnects need no special handling: the tap is per-session, not per-device.
- **Input-source changes** (sources added or removed) arrive as TIS distributed notifications, which trigger a reload.
  A stale source reference is reloaded and retried once.
- **No polling, no timers** in the normal path. Settings are re-checked when the menu opens and when you leave
  System Settings.

### Permissions — exactly why

| Permission | Used? | Why |
|---|---|---|
| **Input Monitoring** | Yes | Required by macOS for any `CGEventTap` that observes keyboard events. InstantFn needs to see Fn press/release, and whether another key or modifier was pressed in between (to keep Fn+key combos untouched). Only event *type*, *modifier flags* and the keycode of *modifier* events are read. Characters are never read, logged or stored. |
| Accessibility | **No** | Needed only to post or modify events. InstantFn's tap is **listen-only**: it cannot block, delay, change or inject input. |
| Network | No | No networking code at all. No telemetry. |
| Root / SIP / system files | No | Nothing outside the app's own `UserDefaults` and a lock file in `~/Library/Caches` is written. |

The app is not sandboxed: it needs to read `com.apple.HIToolbox`'s `AppleFnUsageType` to warn you about double
switching. It is built with the Hardened Runtime and has an empty entitlements file.

**Crash and quit safety:** a listen-only tap is a passive copy of the event stream. If InstantFn hangs, the keyboard keeps
working. If it quits or crashes, the system removes the tap. InstantFn never posts events, so it can't cause a stuck modifier.

### Restoring standard macOS behavior

Menu → **Restore Standard macOS Behavior…** removes the tap and opens Keyboard Settings. Set "Press 🌐 key to" back to
*Change Input Source*. Optionally turn off Launch at Login, remove InstantFn from Input Monitoring, and delete the app.

## Measured latency (this Mac, macOS 26.6 25G72, Apple Silicon)

From `InstantFn --benchmark`, which runs the same path a Fn tap takes (background-thread timestamp → main queue →
`TISSelectInputSource`), 40 toggles per run, 3 runs (2 Release, 1 Debug):

| | median | p95 | max |
|---|---|---|---|
| Fn detected → `TISSelectInputSource` returned | 2.3–2.7 ms | 3.8–5.2 ms | 12–20 ms |
| Fn detected → system "source changed" broadcast received back | 7.1–8.3 ms | 9–12 ms | 16–41 ms |

Not covered by these numbers:
- The time from the physical key release until the event reaches the tap (HID → WindowServer). Apps don't have a
  reliable way to observe it.
- **A real Fn press has not been measured yet.** The benchmark process couldn't get Input Monitoring. In a Debug build,
  open the menu after a few real Fn presses to see the live `Fn→select` and `Fn→confirmed` stats from actual Fn events.

Resources: about 0% CPU when idle, about 46 MB RSS (mostly shared AppKit pages), 190 KB binary.

## Known limitations / to verify

- **Secure Keyboard Entry** (Terminal → Secure Keyboard Entry, password fields): macOS hides keyboard events from taps
  while it's on. Whether Fn `flagsChanged` still arrives in that mode is untested. See test 11.
- **Fn + letter rollover in fast typing:** if a letter is pressed before Fn is released, the press counts as a combo
  and doesn't switch. This is intentional: Fn+letter are system shortcuts on macOS 15+.
- macOS may show its small input-source indicator near the text cursor on *any* source change, including programmatic
  ones. That's system UI, not InstantFn. If you want it gone, run this yourself (untested here, may need a logout):
  `defaults write kCFPreferencesAnyApplication TSMLanguageIndicatorEnabled 0`
- Caps Lock: InstantFn ignores it completely. The separate macOS option "Use Caps Lock to switch to and from ABC" is
  yours to keep or turn off.

## Test plan

Run the **Debug** build so the latency and duplicate counters show in the menu. Before starting, confirm that the
menu bar shows no `⚠︎` and that Permissions Status shows everything ✓.

| # | Test | Steps | Pass criteria |
|---|---|---|---|
| 1 | Rapid Fn presses | Tap Fn 10× fast (about 5/s), then 11×. | Final source = start source after 10, the other after 11. Menu: `Duplicates: 0`. |
| 2 | Fast RU/EN typing | In TextEdit, type a sentence, Fn, type, Fn… at full speed for 1 min. | Every word in the intended script. No missed or extra switches (rollover cases excepted, see limitations). |
| 3 | Fn + other keys | Fn+←/→ (Home/End), Fn+Delete, Fn+F1…F12, Fn+E (emoji), Fn+F (full screen), Fn+A/N/C/Q. | Each does its normal macOS action. Input source unchanged. |
| 4 | Caps Lock | Toggle Caps Lock and type in both languages. Hold Fn, tap Caps Lock, release Fn. | Caps Lock works and its LED is correct. The Fn+Caps case doesn't switch the language. |
| 5 | System shortcuts | Mission Control (F3 / Ctrl+↑), App Exposé, Cmd+Tab, Cmd+Space, Ctrl+←/→ between Spaces, screenshots (Cmd+Shift+4). | All behave normally. No switch unless plain Fn was tapped. |
| 6 | Full-screen apps | Switch with Fn inside a full-screen Chrome / VS Code window. | Switch works, the app stays focused and full-screen, no Space change. |
| 7 | Multiple Spaces | Different apps on 3 Spaces; switch Spaces, tap Fn in each. | Works in every Space. Focus is unchanged. |
| 8 | Roblox Studio | Script editor, Explorer rename field, and the Play-mode chat box: Fn then type. | Correct script immediately. Fn tap doesn't move the camera or trigger Studio shortcuts. |
| 9 | Sleep / wake | Hold Fn, close the lid, wake while released. Then tap Fn normally. Repeat with a Bluetooth keyboard off and on. | No stray switch on wake. The first normal tap works. |
| 10 | Login startup | Enable Launch at Login, log out and in (or reboot). | One InstantFn instance (`pgrep -l InstantFn`). It works without opening anything. |
| 11 | Terminal / secure input | Terminal with Secure Keyboard Entry off, then on. A browser password field. | Document whether Fn works while secure input is on. Nothing breaks either way. |
| 12 | Chrome, VS Code, Terminal | Fn + type in the address bar, editor and integrated terminal, shell prompt. | Correct script immediately in each. |
| 13 | **Stuck modifier** | Hold Fn and Shift, quit InstantFn from Activity Monitor (Force Quit), release both keys. Then type and use Fn+arrows. Also: hold Fn, toggle InstantFn off and on in the menu. | No key or modifier stays logically held (try Shift+letters, Fn+arrows). After relaunch, the first Fn tap works. |
| 14 | Crash safety | `kill -9 $(pgrep InstantFn)` while typing. | Typing keeps working without interruption. |
| 15 | Long hold | Hold Fn for 2 s, release. | No switch. |
| 16 | Source config change | Add a third layout (e.g. Spanish), then remove and re-add one, while InstantFn runs. | Fn cycles through all of them immediately, and the menu's "Fn cycles" line updates. |
| 17 | Restore | Menu → Restore Standard macOS Behavior…, set Globe back to Change Input Source. | Fn switches exactly as stock macOS. InstantFn shows as disabled. |

## Source map

- `InstantFn/FnTapMonitor.swift` — listen-only event tap and Fn tap state machine (the only code that sees events)
- `InstantFn/InputSourceSwitcher.swift` — enabled sources, next-source `TISSelectInputSource`, duplicate detection
- `InstantFn/AppDelegate.swift` — menu bar UI, lifecycle, sleep/wake, benchmark
- `InstantFn/SystemSettings.swift` — settings, Globe-key setting reader, Input Monitoring, `SMAppService`
- `InstantFn/LatencyStats.swift` — debug latency stats
- `InstantFn/main.swift` — single-instance lock (`flock`), no Dock icon
