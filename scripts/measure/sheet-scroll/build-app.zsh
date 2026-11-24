#!/bin/zsh
# Builds the contact sheet's scroll measuring app (docs/M2-shell.md, The contact sheet's scrolling):
# scripts/build-app.sh release's -O code with the drive hook added (-DDEBUG). Under its own bundle identifier,
# camera.argent.Argent.scroll, with its own container and caches, it runs beside the app in use.
# get-task-allow is added so xctrace can attach. Goes into OUT, which a second build under another
# name can share, to compare a change with what came before.
#
#   scripts/measure/sheet-scroll/build-app.zsh OUT [NAME]    (NAME: Argent-scroll)
set -euo pipefail
cd "$(dirname "$0")/../../.."

out=${1:?usage: build-app.zsh OUT [NAME]}
name=${2:-Argent-scroll}
mkdir -p $out

if [[ $(xcode-select -p) == */CommandLineTools && -z ${DEVELOPER_DIR:-} ]]; then
  for xcode in /Applications/Xcode*.app(N); do export DEVELOPER_DIR=$xcode/Contents/Developer; break; done
fi
[[ -f build/stocks/.stamp && $(<build/stocks/.stamp) == $(scripts/stocks-stamp.sh) ]] \
  || { echo "error: build/stocks is missing or baked from another bake/; run scripts/build-app.sh first" >&2; exit 1 }
[[ -f build/Argent.app/Contents/Resources/Assets.car ]] \
  || { echo "error: build/Argent.app has no compiled icon; run scripts/build-app.sh first" >&2; exit 1 }

scratch=.build/sheet-scroll
flags=(-c release -Xswiftc -DDEBUG --scratch-path $scratch)
swift build $flags --product Argent
bin=$(swift build $flags --show-bin-path)

app=$out/$name.app
rm -rf $app
mkdir -p $app/Contents/MacOS $app/Contents/Resources
cp $bin/Argent $app/Contents/MacOS/Argent
scripts/embed-sparkle.sh $app $bin
cp App/Info.plist $app/Contents/Info.plist
plutil -replace CFBundleIdentifier -string camera.argent.Argent.scroll $app/Contents/Info.plist
for bundle in $bin/*.bundle(N); do
  cp -R $bundle $app/Contents/Resources/
done
cp build/Argent.app/Contents/Resources/Assets.car build/Argent.app/Contents/Resources/*.icns(N) $app/Contents/Resources/
mkdir -p $app/Contents/Resources/Stocks
for stock in build/stocks/*(/N); do
  mkdir -p $app/Contents/Resources/Stocks/${stock:t}
  cp $stock/stock.json $stock/*.lut3d $app/Contents/Resources/Stocks/${stock:t}/
done
entitlements=$out/$name.entitlements
cp App/Argent.entitlements $entitlements
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.get-task-allow bool true' $entitlements
scripts/sign-app.sh $app - --entitlements $entitlements

xcrun swiftc -O -o $out/argent-drive scripts/measure/develop-memory/drive.swift
{
  print "commit $(git rev-parse HEAD)"
  [[ -z $(git status --porcelain -- Sources Package.swift App) ]] && print "Sources, Package.swift and App as committed" \
    || print "UNCOMMITTED CHANGES in Sources, Package.swift or App: $(git diff --stat -- Sources | tail -1)"
  print "release -DDEBUG"
  print "$(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(sysctl -n hw.model), $(sysctl -n machdep.cpu.brand_string), $(( $(sysctl -n hw.memsize) >> 30 )) GB"
} > $out/$name.built-from.txt
print "built $app"
cat $out/$name.built-from.txt
