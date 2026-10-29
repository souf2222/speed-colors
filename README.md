# speedcolors

A companion tool for the **DaVinci Resolve Speed Editor** keyboard on macOS:
it takes ownership of the panel over USB/Bluetooth, shows which Resolve page is
active, and gives you a fully configurable button map on the Color page — while
leaving stock behavior untouched on everything else.

## How it works

The Speed Editor is a strictly single-client HID device (VID `0x1EDB`, PID
`0xDA0E`): whoever holds it gets the buttons, and it authenticates with a
proprietary challenge/response handshake. speedcolors exploits a nice property
of that design — the moment the daemon quits, Resolve reclaims the device on
its own and stock behavior resumes. No Resolve restart, no mode toggling.

- **Cut / Edit / Media / Fairlight / Deliver pages** → the daemon mirrors
  Resolve's native Speed Editor mapping by injecting the corresponding keyboard
  shortcuts into Resolve (PID-targeted: it only needs to be *running*, not
  frontmost).
- **Color page** (detected live via Resolve's scripting bridge) → each button
  runs a configured **macro sequence**. Steps can:
  - `goto` — park the cursor on a calibrated screen target (e.g. the Lift wheel)
  - `click` — full mouse click
  - `hold` — press the mouse down until the key is released, so the search dial
    drags the control (e.g. spin the dial to pull Lift in Wheel 1)
  - `key` — inject any keyboard shortcut (⌘/⌥/⇧/⌃ + keycode)
  - `wait` — pause for N ms

Configuration lives in `~/.speedcolors/color.json` and is hand-editable; the
bundled SwiftUI app edits it for you.

## Requirements

- macOS 13+ (Apple Silicon or Intel)
- [hidapi](https://github.com/libusb/hidapi): `brew install hidapi`
- [uv](https://docs.astral.sh/uv/): `brew install uv` — used by the tiny Python
  sidecar that talks to Resolve's scripting bridge (only stdlib is used)
- **Accessibility permission** for the process running the daemon (System
  Settings → Privacy & Security → Accessibility) — needed to inject input
  events. The CLI prints instructions and exits if it's missing.

## Build

```sh
./dev.sh build
```

`dev.sh` is just a `swift` wrapper for machines with Command Line Tools only:
recent CLT SDKs ship SwiftUI macros without the corresponding compiler plugin,
so the script pins an older SDK until that's fixed (with full Xcode installed,
plain `swift build` works too).

## Usage

### Daemon (the main command)

```sh
./dev.sh run speedcolors run            # start the daemon (Ctrl-C to stop)
./dev.sh run speedcolors run --jog-step 800
```

While running: keys are mirrored on Cut/Edit-type pages, and your configured
macros fire on the Color page. Quitting instantly hands the panel back to
Resolve.

### Calibration (Color page targets)

```sh
./dev.sh run speedcolors autocal        # OCR the Resolve window, auto-detect wheels/curves…
./dev.sh run speedcolors autocal --debug
./dev.sh run speedcolors coords --list  # show saved targets
./dev.sh run speedcolors coords --save lift   # record cursor position under a name (3 s countdown)
./dev.sh run speedcolors coords --remove lift
```

Run `autocal` with the Color page open and the primaries palette visible; it
saves targets to `~/.speedcolors/color.json` plus an annotated screenshot so
you can verify the detected boxes. Anything it misses can be recorded manually
with `coords --save <name>`.

Tune the search-dial feel with `--jog-step` (jog units accumulated per
arrow-key tap).

### Diagnostics & exploration

| Command | What it does |
|---|---|
| `speedcolors status` | find the panel, authenticate, report battery |
| `speedcolors events [-d SECONDS]` | print live key / dial / battery events |
| `speedcolors leds-demo` | chase every panel and jog-mode LED to verify the mapping |
| `speedcolors hold -s 12` | hold the device exclusively for N s (handoff experiment) |
| `speedcolors list-hid` | enumerate all HID devices via IOKit/hidapi |
| `speedcolors probe-hid` | try opening every Speed Editor interface |
| `speedcolors ble-scan` / `ble-dump` | Bluetooth LE discovery / GATT dump |
| `speedcolors page` | ask the running Resolve which page is active |

### GUI

```sh
./dev.sh run SpeedColorsUI
```

A SwiftUI app that runs the same daemon core: manage binding macros per
profile, edit and test targets, inspect captured keys, view hardware layout
and live dial/battery state.

## Project layout

```
Sources/
  CHid/            module map + shim for hidapi
  SpeedColorsCore/ HID transport, auth, daemon, macros, OCR autocalibration,
                   Resolve bridge, BLE exploration
  speedcolors/     CLI (swift-argument-parser)
  SpeedColorsUI/   SwiftUI settings/control app
tools/
  resolve_page_agent.py   Python sidecar for Resolve's scripting bridge
  pdfsearch.swift         helper used during reverse engineering
```

## Status

Reverse-engineered against real hardware: the auth handshake, LED control,
jog modes, and the page-watcher bridge are working; treat the protocol details
as unofficial, and expect Bluetooth transport to be rougher than USB.
Requires Resolve to be installed and running for page detection and injection.
