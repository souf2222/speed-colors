# SpeedColors

A companion app for the **DaVinci Resolve Speed Editor** keyboard on macOS.
SpeedColors takes ownership of the panel over USB or Bluetooth, detects which
Resolve page is active in real time, and gives you a fully configurable button
map on the Color page — while leaving Resolve's stock behavior untouched on
every other page.

**Highlights**

- Keep the Speed Editor's native Cut/Edit workflow and add your own macros on
  the Color page (or any custom binding you like)
- Bind buttons to calibrated screen targets, mouse clicks, keyboard shortcuts,
  or multi-step sequences
- Multiple profiles with per-profile bindings, dial sensitivity, and names
- Live hardware view: battery, jog/dial state, key capture, hardware layout
- Bluetooth and USB transports

## How it works

The Speed Editor is a strictly single-client HID device (VID `0x1EDB`, PID
`0xDA0E`): whoever holds it gets the buttons, and it authenticates with a
proprietary challenge/response handshake. SpeedColors exploits a nice property
of that design — the moment the daemon quits, Resolve reclaims the device on
its own and stock behavior resumes. No Resolve restart, no mode toggling.

The daemon installed by the app does the page-dependent work:

- **Cut / Edit / Media / Fairlight / Deliver pages** — it mirrors Resolve's
  native Speed Editor mapping by injecting the corresponding keyboard
  shortcuts into Resolve (PID-targeted: it only needs to be *running*, not
  frontmost).
- **Color page** — detected live via Resolve's scripting bridge; each button
  runs a configured **macro sequence** instead. Steps can be:
  - `goto` — park the cursor on a calibrated screen target (e.g. the Lift
    wheel), which you pick up with the search dial
  - `hold` — press the mouse down until the key is released (e.g. spin the
    dial to drag Lift in Wheel 1)
  - `click` — full mouse click
  - `key` — inject any keyboard shortcut (⌘/⌥/⇧/⌃ + keycode)
  - `wait` — pause for N ms

## Requirements

- macOS 13+ (Apple Silicon or Intel)
- [DaVinci Resolve](https://www.blackmagicdesign.com/products/davinciresolve)
  installed and running (needed for page detection and injection)
- [hidapi](https://github.com/libusb/hidapi): `brew install hidapi`
- [uv](https://docs.astral.sh/uv/): `brew install uv` — used by the tiny
  bundled Python sidecar that talks to Resolve's scripting bridge (stdlib
  only)

## Permissions

The app needs three privacy grants and **asks for all of them at launch**
(system dialogs for the first two; a System Settings pane for the third):

- **Accessibility** — injects keyboard and mouse events into Resolve
  (System Settings → Privacy & Security → Accessibility → add & enable
  **SpeedColors**, the app bundle or the raw binary you launch).
- **Screen Recording** — palette auto-detect reads the Color page's palette
  strip from the screen.
- **Input Monitoring** — the shortcut-recorder event tap captures combos
  system-wide (without it, capture falls back and keys may leak to the app
  behind).

Status lives in the menu bar panel (with **Grant…** buttons), Settings →
Permissions, and Diagnostics. Grants stick across rebuilds when you use the
packaged app (stable bundle id), but re-prompt if you run the raw build-tree
binary directly.

## Build

```sh
./dev.sh build
```

`dev.sh` is just a `swift` wrapper for machines with Command Line Tools only:
recent CLT SDKs ship SwiftUI macros without the corresponding compiler plugin,
so the script pins an older SDK until that's fixed. With full Xcode installed,
plain `swift build` works too.

## Run

### Development (raw binary)

```sh
./dev.sh run SpeedColors
```

Launches the menu bar app straight from the build tree (it self-registers as
an accessory app, no Dock icon).

### Packaged app

```sh
tools/make-app.sh            → dist/SpeedColors.app
open dist/SpeedColors.app    → launch into the menu bar
```

The .app bundle makes it a first-class macOS app: `LSUIElement` keeps it off
the Dock (the `MenuBarExtra` supplies the status item), and the stable bundle
id means Accessibility grants persist across rebuilds.

Once launched, SpeedColors appears in the menu bar — start/stop the daemon
from there, and everything else (profiles, targets, bindings, diagnostics)
lives in its panels.

## Configuration

All configuration lives in `~/.speedcolors/color.json` and is hand-editable;
the app edits it for you and watches for external changes. Key structure:

- `targets` — calibrated screen coordinates per named Color-page target
- `bindings` → the active profile's macro sequences (per hardware key)
- `dialSensitivity` / `pixelsPerUnit` — search-dial feel
- `jogUnitsPerArrow` — jog units accumulated per arrow-key tap
- `storedProfiles` / `activeProfile` — snapshot-based profile storage

Profiles are snapshot-based: the active profile's data sits in the flat
fields (so the daemon reads it with zero overhead), everything else is
snapshotted into `storedProfiles` and swapped out on switching.

Diagnostic logs end up in `~/.speedcolors/ui.log`.

## Project layout

```
Sources/
  CHid/            module map + shim for hidapi
  SpeedColorsCore/ HID transport, auth, daemon, macros, OCR autocalibration,
                   Resolve bridge, BLE exploration
  SpeedColors/     SwiftUI menu bar app (daemon control, profiles, targets,
                   bindings, diagnostics)
tools/
  make-app.sh             package the debug build as dist/SpeedColors.app
  resolve_page_agent.py   Python sidecar for Resolve's scripting bridge
  pdfsearch.swift         helper used during reverse engineering
```

## Status

Reverse-engineered against real hardware: the auth handshake, LED control,
jog modes, and the page-watcher bridge are working. Treat the protocol details
as unofficial — this project is not affiliated with Blackmagic Design, and a
DaVinci update could shift the ground under it. Bluetooth transport is rougher
than USB at this point.
