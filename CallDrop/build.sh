#!/bin/zsh
# Build CallDrop.app from the SPM package and install to ~/Applications.
set -e
cd "$(dirname "$0")"

swift build -c release 2>&1 | tail -3

APP=~/Applications/CallDrop.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/CallDrop "$APP/Contents/MacOS/CallDrop"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
echo "installed: $APP"
