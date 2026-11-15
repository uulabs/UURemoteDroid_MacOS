# Third-party notices

## scrcpy

UU RemoteDroid bundles the official, unmodified `scrcpy-server` binary from
scrcpy 5.0.1 and runs it on each connected Android device to capture its
screen and inject input. UU RemoteDroid's macOS client is its own
implementation of the scrcpy protocol.

- Project: https://github.com/Genymobile/scrcpy
- Copyright (C) 2018 Genymobile
- Copyright (C) 2018-2026 Romain Vimont
- License: Apache License, Version 2.0

The full license text is in `Resources/SCRCPY-LICENSE.txt` in the source tree
and at `UU RemoteDroid.app/Contents/Resources/SCRCPY-LICENSE.txt` in every
build. scrcpy does not ship a NOTICE file.

UU RemoteDroid is not affiliated with or endorsed by Genymobile or the scrcpy
authors.

## Apple frameworks

Video decoding and rendering use Apple's AVFoundation, VideoToolbox,
CoreMedia, CoreGraphics, AppKit and SwiftUI frameworks under the macOS SDK
terms.
