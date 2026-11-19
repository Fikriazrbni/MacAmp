#!/bin/sh
set -eu
cd "$(dirname "$0")"
bundle="Power Audio.app"
mkdir -p "$bundle/Contents/MacOS"
mkdir -p "$bundle/Contents/Resources"
cp -R FxSound "$bundle/Contents/Resources/"
cp Art/PowerAudio.icns "$bundle/Contents/Resources/AppIcon.icns"
cp Art/PowerAudio.png "$bundle/Contents/Resources/PowerAudio.png"
cp Info.plist "$bundle/Contents/Info.plist"
xcrun clang++ -std=c++17 -O2 -fobjc-arc -mmacosx-version-min=14.2 -ffp-contract=off -framework JavaScriptCore -framework Cocoa -framework CoreAudio PowerAudio.mm -o "$bundle/Contents/MacOS/PowerAudio"
touch "$bundle"
codesign --force --sign - "$bundle"
"$bundle/Contents/MacOS/PowerAudio" --test-dsp
