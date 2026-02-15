# CEDAR Retouch + REAPER Roundtrip

Send multitrack audio from REAPER to CEDAR Retouch for noise removal, get it back in the right place with one click.

## Quick Start

1. Install both scripts as REAPER actions (Actions > Show action list > Load)
2. Select items (or just make a time selection over them)
3. Run **Send to CEDAR Retouch** -- opens CEDAR with your audio
4. Remove noise in CEDAR, hit Save
5. Run **Return from CEDAR Retouch** -- done. Ctrl+Z to undo.

Re-edited something in CEDAR? Just save again and re-run Return. No undo needed.

## What It Does

**Send to CEDAR Retouch** (`Send to CEDAR Retouch.lua`)
- Exports selected items as a single multichannel WAV (one stereo/mono pair per track)
- Handles time selections (exports only the selected range)
- If nothing is selected, grabs all items under the time selection
- If there's no time selection, uses the items' range
- Launches CEDAR and opens the file

**Return from CEDAR Retouch** (`Return from CEDAR Retouch.lua`)
- Extracts the processed audio from CEDAR's multi-RIFF save format
- Replaces the original items at the correct positions
- Preserves clip gains and take names
- Splits items at time selection boundaries (non-destructive)
- Re-runnable without undo -- just save in CEDAR and run again

## Example

```
3 tracks, time selection from 10s-15s:

Track 1 (Vocals, stereo)  ----[======]----
Track 2 (Violin, stereo)  ----[======]----
Track 3 (Piano, mono)     ----[======]----

Send: exports 5-channel WAV (2+2+1), opens in CEDAR
CEDAR: remove clicks, save
Return: replaces the 10s-15s region on all 3 tracks
```

## Setup

Requires REAPER and [CEDAR Retouch](https://www.cedar-audio.com/products/retouch/retouch.shtml) on macOS. No SWS extension needed.

Register CEDAR as a WAV file handler (needed once, lets the script open files directly):

```sh
tools/cedar-register-filetypes
```

## macOS Keyboard Shortcuts

CEDAR's modifier-based hotkeys (Ctrl+Z, etc.) are broken on macOS.
Use [Hammerspoon](https://www.hammerspoon.org/) to translate standard Mac shortcuts.

| Shortcut       | Action    | Sends bare key |
|----------------|-----------|----------------|
| Cmd+Z          | Undo      | U              |
| Cmd+Shift+Z    | Redo      | W              |
| Cmd+S          | Save      | G              |
| Return         | Apply     | R              |

### CEDAR Bare-Key Shortcuts (via plist)

**Tools:** A=Rectangle, S=Polyline, D=Paint, F=Zoom, L=Toggle XY lock

**Processing:** 1=Interpolate, 2=Cleanse, 3=Erase, 4=Patch, 5=Copy, 6=Volume, 7=Revert, 8=Repair, X=Add, C=Subtract, E=Preview, R=Apply, Q=Apply all, Z=New

**Playback:** Space=Play/Stop

## Utilities

```sh
tools/cedar-audio-setup        # Select audio device, clear semaphore, relaunch
tools/cedar-register-filetypes # Register CEDAR as WAV handler (preserves code signature)
tools/sem_unlink               # Remove stale POSIX semaphore (fixes startup hang)
tools/list-audio-devices       # List PortAudio output devices with indices
```

Build from source (`brew install portaudio`):

```sh
cd tools
cc -o sem_unlink sem_unlink.c
cc -o list-audio-devices list-audio-devices.c $(pkg-config --cflags --libs portaudio-2.0)
```

## Known Issues

- CEDAR stores audio device as a PortAudio index, not by name. Breaks silently when hardware changes. Use `cedar-audio-setup` to fix.
- CEDAR leaks a POSIX semaphore (`/{9930E770E5BE}`) if force-killed. Next launch hangs. Use `sem_unlink` or `cedar-audio-setup`.
- CEDAR's `open -a` file association requires `cedar-register-filetypes` (modifies Info.plist temporarily, restores it to preserve iLok code signature).
- CEDAR saves processed audio as additional RIFF chunks appended to the original file. The Return script extracts the last chunk automatically.
- Modifier-based hotkeys broken on macOS (channel select, etc.).
