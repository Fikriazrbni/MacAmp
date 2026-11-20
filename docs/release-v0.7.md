## Power Audio v0.7 for macOS

The first public release includes 25 FxSound presets, preset comparison, and output controls in the menu bar.

- Choose from 13 built-in presets and 12 bonus presets, or adjust the intensity of the prototype effect.
- Switch between speakers and headphones from the main window or menu bar. Active effects follow the Mac’s default output.
- View each preset’s ten-band EQ and switch back to the previous preset to compare them.

### Installation

Download **PowerAudio-v0.7-macos-arm64.zip** for an Apple Silicon Mac running macOS 14.2 or later. Unzip it, move **Power Audio.app** to **Applications**, and open it. Enable effects and allow system audio recording when prompted. This build is ad hoc signed and has not been notarized by Apple.

### Verify the download

Save **SHA256SUMS.txt** alongside the ZIP and run this command in the same folder:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

The source code is available at the **v0.7** tag. See the [release README](https://github.com/Fikriazrbni/MacAmp/blob/v0.7/README.md) for build instructions, usage, privacy, and credits.
