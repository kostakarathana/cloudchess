# CloudChess

An on-device SwiftUI, SceneKit and Metal chess puzzle app for iPhone and iPad.
Puzzle generation, Stockfish analysis and adaptive coaching run on the device.
Optional public-game imports connect directly to Chess.com or Lichess.

## License

Application source and original artwork: GPL-3.0-or-later. Stockfish and its
network retain their GPLv3 license. Lichess opening/game data retain CC0.
See `COPYING`, `NOTICE`, and the notices bundled with the resources.

## Build

Requirements: macOS, Xcode with the iOS 17+ SDK (the verified build uses Xcode
26.6 / iOS 26.5 SDK), Python 3, and approximately 2 GB of free build space.

1. Download `CloudChess-source.tar.gz` and `SHA256SUMS` from the matching GitHub
   release. Verify with `shasum -a 256 -c SHA256SUMS` in that download directory.
2. Extract the archive. It includes all engine and app sources, the exact neural
   network, calibrated data, authored meshes/textures, icon and privacy manifest.
3. Run `python3 scripts/build_native_engine.py --sdk iphonesimulator` for Simulator
   or `--sdk iphoneos` for a device. Both baseline and dot-product variants build.
4. Open `CloudChess.xcodeproj`, choose the CloudChess scheme and a destination.
   For a device, select your own development team in Signing & Capabilities.
5. Build and run. The app does not require a private backend, API key or account.

The Git repository contains code and the smaller assets. The release archive
also includes the larger `CloudChess/EngineResources` directory; obtain it from
the same release if starting from a Git clone. Compiled native libraries are
rebuilt from the included sources rather than supplied as opaque binaries.

The C++ bridge, proof engine and exact compile flags are included. Detailed art
can be regenerated using `scripts/build_atelier.py` with Blender. Published
meshes and textures are already included, so Blender is not required to build or
run the app. Automated iOS UI tests are in `CloudChessUITests`.

No signing identities, provisioning profiles, personal game databases, developer
machine configuration or Git history are included in the release archive.

Support and privacy: https://kostakarathana.github.io/cloudchess-support/
