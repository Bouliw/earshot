#!/bin/zsh
# Builds Earshot.app into build/. Usage: scripts/build.sh [--install | --dmg]
set -e
cd "${0:A:h}/.."
# Local builds sign with an Apple Development certificate when one is available, so macOS keeps
# privacy permissions across rebuilds (an ad hoc signature changes with every build).
# Release DMGs stay ad hoc: a development certificate carries the developer's personal name.
SIGN=-
if [[ "$1" != "--dmg" ]]; then
  SIGN=${EARSHOT_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}
  SIGN=${SIGN:--}
fi
swift build -c release --arch arm64
BIN=$(swift build -c release --arch arm64 --show-bin-path)
APP=build/Earshot.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Earshot" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns Resources/kyutai-stt.py Resources/install-kyutai.sh "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
ditto "$BIN/whisper.framework" "$APP/Contents/Frameworks/whisper.framework"
codesign --force --sign "$SIGN" "$APP/Contents/Frameworks/whisper.framework"
codesign --force --sign "$SIGN" "$APP"
if [[ "$SIGN" == "-" ]]; then echo "Built $APP (ad hoc signature)"; else echo "Built $APP (signed: $SIGN)"; fi
if [[ "$1" == "--install" ]]; then
  pkill -x Earshot 2>/dev/null || true
  rm -rf /Applications/Earshot.app
  ditto "$APP" /Applications/Earshot.app
  echo "Installed /Applications/Earshot.app"
fi
if [[ "$1" == "--dmg" ]]; then
  rm -rf build/dmg build/Earshot.dmg
  mkdir -p build/dmg
  ditto "$APP" build/dmg/Earshot.app
  ln -s /Applications build/dmg/Applications
  hdiutil create -quiet -volname Earshot -srcfolder build/dmg -format UDZO build/Earshot.dmg
  rm -rf build/dmg
  echo "Built build/Earshot.dmg"
fi
