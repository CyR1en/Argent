#!/bin/zsh
# shellcheck disable=SC2076,SC2086,SC2231
# Builds a lane's copy of the app with the drive hook (Sources/ArgentApp/Automation.swift), and Remove's helper beside it: the optimized build of
# scripts/build-app.sh release with -DDEBUG added, under the bundle identifier camera.argent.Argent.LANE, so it has its
# own container and answers only camera.argent.Argent.LANE.drive. Also builds argent-drive
# (scripts/measure/develop-memory/drive.swift), which posts a command to it.
#
#   scripts/lane-app.zsh LANE      for example ac1-3; prints the app, its bundle identifier and argent-drive
set -euo pipefail
setopt null_glob
cd "$(dirname "$0")/.."

lane=${1:?usage: lane-app.zsh LANE}
[[ $lane =~ '^[A-Za-z0-9-]+$' ]] || { print -u2 "error: a lane id is letters, digits and hyphens: $lane"; exit 2; }
id=camera.argent.Argent.$lane

if [[ $(xcode-select -p) == */CommandLineTools && -z ${DEVELOPER_DIR:-} ]]; then
  for xcode in /Applications/Xcode*.app; do export DEVELOPER_DIR=$xcode/Contents/Developer; break; done
fi

if [[ ! -x .venv/bin/python ]]; then
  python3 -m venv .venv && .venv/bin/pip install --quiet numpy
fi

base=build/Argent.app
base_app_stale() {
  [[ ! -f $base/Contents/Resources/Assets.car || ! -f build/stocks/.stamp || $(<build/stocks/.stamp) != $(scripts/stocks-stamp.sh) ]] ||
    [[ -n $(find App/Argent.icon build/models -newer $base/Contents/Resources/Assets.car -print -quit 2>/dev/null) ]]
}
if base_app_stale; then
  scripts/build-app.sh release
fi

# The -DDEBUG build has its own scratch folder, so SwiftPM rebuilds it only when the sources change.
scratch=.build/lane-app
swift build -c release -Xswiftc -DDEBUG --scratch-path $scratch --product Argent
swift build -c release -Xswiftc -DDEBUG --scratch-path $scratch --product argent-remove
bin=$(swift build -c release -Xswiftc -DDEBUG --scratch-path $scratch --show-bin-path)

app=build/lanes/$lane/Argent.app
rm -rf $app
mkdir -p $app:h
cp -c -R $base $app
cp $bin/Argent $app/Contents/MacOS/Argent
# Remove's helper from the same sources, not the base app's, which is built again only when its resources change.
cp $bin/argent-remove $app/Contents/MacOS/argent-remove
cp App/Info.plist $app/Contents/Info.plist
plutil -replace CFBundleIdentifier -string $id $app/Contents/Info.plist
rm -rf $app/Contents/Resources/*.bundle
for bundle in $bin/*.bundle; do
  cp -R $bundle $app/Contents/Resources/
done
codesign --force --sign - --options runtime --entitlements App/ArgentRemoveHelper.entitlements $app/Contents/MacOS/argent-remove
codesign --force --sign - --options runtime --entitlements App/Argent.entitlements $app
codesign --verify --strict $app

drive=build/lanes/argent-drive
if [[ ! -x $drive || scripts/measure/develop-memory/drive.swift -nt $drive ]]; then
  xcrun swiftc -O -o $drive scripts/measure/develop-memory/drive.swift
fi

print "app $PWD/$app"
print "bundle id $id"
print "argent-drive $PWD/$drive"
