#!/bin/zsh
# Build, install to ~/Applications, and activate the Quick Look extensions.
set -e
cd "$(dirname "$0")"
xcodegen generate >/dev/null
xcodebuild -project ThreeMFPreview.xcodeproj -scheme ThreeMFPreview -configuration Release \
  -derivedDataPath build build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
APP=~/Applications/ThreeMFPreview.app
rm -rf "$APP"
ditto build/Build/Products/Release/ThreeMFPreview.app "$APP"
rm -rf build/Build/Products/Release/ThreeMFPreview.app   # avoid duplicate registrations
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R "$APP"
pluginkit -a "$APP"/Contents/PlugIns/*.appex
# Extensions won't launch until the host app has been opened once.
open -g "$APP"; sleep 2; osascript -e 'quit app "ThreeMFPreview"' 2>/dev/null || true
qlmanage -r >/dev/null 2>&1; qlmanage -r cache >/dev/null 2>&1
echo "Installed."
