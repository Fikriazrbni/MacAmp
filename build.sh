#!/bin/sh
set -eu
cd "$(dirname "$0")"
bundle="MacAmp.app"
mkdir -p "$bundle/Contents/MacOS"
mkdir -p "$bundle/Contents/Resources"
cp -R FxSound "$bundle/Contents/Resources/"
cp Art/MacAmp.icns "$bundle/Contents/Resources/AppIcon.icns"
cp Art/MacAmp.png "$bundle/Contents/Resources/MacAmp.png"
cp Info.plist "$bundle/Contents/Info.plist"
xcrun clang++ -std=c++17 -O2 -fobjc-arc -mmacosx-version-min=14.2 -ffp-contract=off -framework JavaScriptCore -framework Cocoa -framework CoreAudio MacAmp.mm -o "$bundle/Contents/MacOS/MacAmp"
touch "$bundle"
codesign --force --sign - "$bundle"
"$bundle/Contents/MacOS/MacAmp" --test-dsp
