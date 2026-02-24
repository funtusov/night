# @funtusov/night

macOS CLI to enter a temporary "night mode":

1. start `caffeinate -i`
2. set keyboard brightness to `0`
3. set display brightness to `0`
4. wait for any key press
5. restore both brightness values and stop caffeinate

## Install

```bash
npm i -g @funtusov/night
night --help
```

Or run directly:

```bash
npx @funtusov/night --help
```

## Requirements

- macOS
- Node.js >= 18
- Xcode Command Line Tools (`swift` command available)

If `swift` is missing:

```bash
xcode-select --install
```

## Usage

```bash
night
```

Press any key to restore and exit.

### Options

```bash
night --no-display
night --no-keyboard
night --no-caffeinate
```

## Notes

- `night` is macOS-only.
- The CLI uses a bundled Swift helper (`native/macos_brightness.swift`) to read/write:
  - display brightness via active-display APIs (`DisplayServices`) with `AppleARMBacklight` fallback
  - keyboard brightness via `KeyboardBrightnessClient` (CoreBrightness)
- `Ctrl-C` also restores state before exit.
