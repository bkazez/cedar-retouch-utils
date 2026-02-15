# CEDAR Retouch macOS Keyboard Shortcuts

CEDAR Retouch's modifier-based hotkeys (Ctrl+Z, etc.) are broken on macOS.
This setup uses Hammerspoon to translate standard Mac shortcuts into bare keys,
plus custom plist remappings for the CEDAR hotkey config.

## Requirements

- [Hammerspoon](https://www.hammerspoon.org/) (`brew install --cask hammerspoon`)
- Config: `~/.hammerspoon/init.lua`
- Plist: `~/Library/Preferences/com.CEDARAudioLtd.All.plist`

## Mac-standard shortcuts (via Hammerspoon)

| Shortcut       | Action    | Sends bare key |
|----------------|-----------|----------------|
| Cmd+Z          | Undo      | U              |
| Cmd+Shift+Z    | Redo      | W              |
| Cmd+S          | Save      | G              |
| Return         | Apply     | R              |

These only activate when CEDAR Retouch is the frontmost app.

## CEDAR bare-key shortcuts (via plist)

### Tools

| Key   | Action      |
|-------|-------------|
| A     | Rectangle   |
| S     | Polyline    |
| D     | Paint       |
| F     | Zoom        |
| L     | Toggle XY lock |

### Processing

| Key   | Action      |
|-------|-------------|
| 1     | Interpolate |
| 2     | Cleanse     |
| 3     | Erase       |
| 4     | Patch       |
| 5     | Copy        |
| 6     | Volume      |
| 7     | Revert      |
| 8     | Repair      |
| X     | Add         |
| C     | Subtract    |
| E     | Preview     |
| R     | Apply       |
| Q     | Apply all   |
| Z     | New         |

### Playback

| Key   | Action      |
|-------|-------------|
| Space | Play / Stop |

### Navigation

| Action              | Method                    |
|---------------------|---------------------------|
| Horizontal zoom     | Scroll wheel on X axis    |

## Utilities

```sh
tools/cedar-audio-setup   # Select audio device, clear semaphore, relaunch
tools/sem_unlink           # Remove stale POSIX semaphore (fixes startup hang)
tools/list-audio-devices   # List PortAudio output devices with indices
```

Build tools from source (requires `brew install portaudio`):

```sh
cd tools
cc -o sem_unlink sem_unlink.c
cc -o list-audio-devices list-audio-devices.c $(pkg-config --cflags --libs portaudio-2.0)
```

## Known issues

- CEDAR stores the audio device as a PortAudio index, not by name. It can
  silently break when hardware changes. Use `cedar-audio-setup` to fix.
- CEDAR leaks a POSIX semaphore (`/{9930E770E5BE}`) if force-killed. The next
  launch will hang on `sem_wait`. Use `sem_unlink` or `cedar-audio-setup`.
- Channel select hotkeys (modifier=8) are broken on macOS like all other
  modifier-based hotkeys.
