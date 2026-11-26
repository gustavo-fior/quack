#!/bin/sh
# Builds build/Quack.app. Pass --run to launch it afterwards.
set -e
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Quack"

APP=build/Quack.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Quack"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/Sounds "$APP/Contents/Resources/Sounds"

if [ ! -f build/AppIcon.icns ]; then
    ICONSET=build/AppIcon.iconset
    mkdir -p "$ICONSET"
    swift scripts/make-icon.swift build/icon-1024.png
    for s in 16 32 128 256 512; do
        sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        d=$((s * 2))
        sips -z $d $d build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature. Set QUACK_SIGN_IDENTITY to a real identity to keep the
# Input Monitoring grant across rebuilds.
codesign --force --sign "${QUACK_SIGN_IDENTITY:--}" "$APP"

# A rebuilt ad-hoc app no longer matches its old Input Monitoring grant, and the stale
# entry would stop macOS from asking again.
if [ -z "$QUACK_SIGN_IDENTITY" ]; then
    tccutil reset ListenEvent app.quack.Quack >/dev/null 2>&1 || true
fi

echo "Built $APP"
if [ "$1" = "--run" ]; then
    pkill -x Quack 2>/dev/null || true
    open "$APP"
fi
