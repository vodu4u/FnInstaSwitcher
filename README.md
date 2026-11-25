<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="InstantFn icon">
</p>

<h1 align="center">InstantFn</h1>

<p align="center">
  <b>Switch keyboard languages on macOS instantly with the Fn / 🌐 key.</b><br>
  No delay, no popup, no lost first letter. A tiny native menu-bar app.
</p>

<p align="center">
  <a href="https://github.com/vodu4u/FnInstaSwitcher/releases/latest/download/InstantFn.zip"><b>⬇︎ Download InstantFn for macOS</b></a>
  &nbsp;·&nbsp; macOS 13+ · Apple Silicon &amp; Intel · free &amp; open source
</p>

---

macOS can switch input sources with the Fn/Globe key, but there's a noticeable lag, and the first character you type
after switching often comes out in the old language. **InstantFn** switches the moment you release Fn: about 2–3 ms on
an Apple Silicon Mac.

- ⚡️ **Instant.** It calls the system input-source API directly. No simulated keystrokes.
- 🔁 **Next language.** It cycles through every input source you've enabled (EN → RU → ES → …).
  With two sources, it's a simple toggle.
- ⌨️ **Doesn't get in the way.** Fn+arrows, F-keys, Fn+E, Fn+F and other Fn shortcuts work as usual.
  Caps Lock and every other modifier key are untouched. Holding Fn does nothing.
- 🔒 **Private by design.** It never reads what you type, has no network code and no telemetry.
  It can only observe the keyboard, never change or block it.
- 🪶 **Lightweight.** About 0% CPU when idle, no Dock icon, under 1 MB to download.

Works on macOS 13 Ventura or newer, on Apple Silicon and Intel.

## Install

1. **[Download InstantFn.zip](https://github.com/vodu4u/FnInstaSwitcher/releases/latest/download/InstantFn.zip)** (latest version, under 1 MB), unzip it, and move **InstantFn.app** to
   **Applications**. Older versions and release notes are on the [Releases](../../releases) page.
2. Open it. InstantFn isn't notarized by Apple (it's a free hobby project), so the first time macOS shows a warning:
   click **Done**, then go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
   <details><summary>Or use Terminal</summary>

   ```bash
   xattr -dr com.apple.quarantine /Applications/InstantFn.app
   ```
   </details>
3. Allow **Input Monitoring** when asked. If you miss the prompt, enable InstantFn under
   **System Settings → Privacy & Security → Input Monitoring**.
4. Set **System Settings → Keyboard → "Press 🌐 key to" → Do Nothing**, so macOS doesn't switch or show the emoji
   picker at the same time. InstantFn shows ⚠︎ in the menu bar until this is done.
5. *(Optional)* Turn on **Launch at Login** in the InstantFn menu.

That's it: tap **Fn** to switch.

## Menu

```
INPUT SOURCES          ← the order Fn cycles through (✓ = current, click to select)
✓ U.S.
  Russian
───────────
✓ Switch on Fn         ← turn InstantFn on/off
✓ Launch at Login
  Custom Language Indicator  ← optional: correct language bubble at the text cursor
  Hide macOS Language Indicator  ← or: just hide the macOS bubble (no extra permission)
───────────
Advanced ▸             ← permission status, settings shortcuts, restore defaults
Quit InstantFn
```

To change which languages are in the cycle, or their order, add, remove or reorder input sources in
**System Settings → Keyboard → Text Input**. InstantFn picks the change up immediately.

## Why does it need Input Monitoring?

macOS requires this permission for any app that observes key presses, including just the Fn key. InstantFn uses it
only to see:

- when Fn is pressed and released;
- whether another key was pressed in between (so Fn shortcuts keep working).

It never reads characters, never stores anything, and uses a *listen-only* event tap that cannot block, delay or
change your input. If InstantFn crashes or quits, the keyboard just keeps working. **Accessibility access is not
needed** unless you turn on the optional Custom Language Indicator (see FAQ). All of the code is in [`InstantFn/`](InstantFn): about 1,100 lines of Swift, with no dependencies.

## Uninstall / restore macOS behavior

**Advanced → Restore Standard macOS Behavior…**, then set "Press 🌐 key to" back to *Change Input Source*.
Quit InstantFn, delete it from Applications, and remove it from Input Monitoring.

## FAQ

**Fn sometimes doesn't switch while I type fast.** If a letter key goes down before Fn comes up, InstantFn treats it
as an Fn+key shortcut and leaves it alone. Release Fn first.

**After updating, Fn stopped working.** Unsigned builds get a new code signature with every version, so macOS asks for
Input Monitoring again. Remove InstantFn from the Input Monitoring list, then allow it again.

**The little language bubble next to the text cursor shows the wrong language.** This is a macOS limitation: when
another app switches the input source, the bubble often shows the *previous* language, even though typing already uses
the new one. Turn on **Custom Language Indicator** in the menu: InstantFn then draws its own bubble with the correct
language exactly over the macOS one. It's off by default because it needs **Accessibility**, used only to find where
the text cursor is (InstantFn never reads the text). If you'd rather not grant it, choose **Hide macOS Language
Indicator** instead; macOS then shows only a small grey label with the correct language. Only one of the two can be on.

**Does it work in games and secure fields?** It works in normal apps (browsers, editors, Terminal, IDEs, game editors and
so on). While *Secure Keyboard Entry* is on (password fields, or the Terminal option of that name), macOS hides keyboard
events from all apps, so InstantFn may not see Fn there.

## Build from source

Needs only the Xcode Command Line Tools (`xcode-select --install`):

```bash
git clone https://github.com/vodu4u/FnInstaSwitcher.git
cd FnInstaSwitcher
./build.sh release
open build/release/InstantFn.app
```

Or open `InstantFn.xcodeproj` in Xcode. Architecture, measurements and the full test plan are in
[docs/TECHNICAL.md](docs/TECHNICAL.md).

## License

[MIT](LICENSE)
