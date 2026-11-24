#!/bin/zsh
# Builds the develop-memory measuring app (docs/manual-development-validation.md, "Develops started
# with the frame view open"): an optimized build with the drive hook compiled in (-DDEBUG), under its
# own bundle identifier, camera.argent.Argent.m3mem, so it has its own container and recipe library
# and answers only camera.argent.Argent.m3mem.drive. It is assembled with the six baked stocks and
# signed ad hoc with the app's entitlements as scripts/build-app.sh does, so it runs sandboxed. Also
# builds argent-drive, which posts the hook's commands. Both go into EVIDENCE/build, beside a note of
# the commit they were built from.
#
#   scripts/measure/develop-memory/build-measure-app.sh EVIDENCE
set -euo pipefail
cd "$(dirname "$0")/../../.."

evidence=${1:?usage: build-measure-app.sh EVIDENCE}
out=$evidence/build
mkdir -p $out

# Xcode's toolchain, as build-app.sh's actool fallback finds it, when xcode-select points at the
# Command Line Tools, which lack SwiftUI's macros.
if [[ $(xcode-select -p) == */CommandLineTools && -z ${DEVELOPER_DIR:-} ]]; then
  for xcode in /Applications/Xcode*.app(N); do export DEVELOPER_DIR=$xcode/Contents/Developer; break; done
fi
# The stocks as scripts/build-app.sh bakes them from bake/ as it is now.
[[ -f build/stocks/.stamp && $(<build/stocks/.stamp) == $(scripts/stocks-stamp.sh) ]] \
  || { echo "error: build/stocks is missing or baked from another bake/; run scripts/build-app.sh first" >&2; exit 1 }

scratch=.build/measure
swift build -c release -Xswiftc -DDEBUG --scratch-path $scratch --product Argent
bin=$(swift build -c release -Xswiftc -DDEBUG --scratch-path $scratch --show-bin-path)

app=$out/Argent-m3mem.app
rm -rf $app
mkdir -p $app/Contents/MacOS $app/Contents/Resources
cp $bin/Argent $app/Contents/MacOS/Argent
scripts/embed-sparkle.sh $app $bin
cp App/Info.plist $app/Contents/Info.plist
plutil -replace CFBundleIdentifier -string camera.argent.Argent.m3mem $app/Contents/Info.plist
for bundle in $bin/*.bundle(N); do
  cp -R $bundle $app/Contents/Resources/
done
$(xcrun --find actool) App/Argent.icon --compile $app/Contents/Resources --app-icon Argent \
  --platform macosx --minimum-deployment-target 27.0 --target-device mac \
  --output-partial-info-plist $out/icon-partial.plist --errors --warnings --output-format human-readable-text > /dev/null
for stock in build/stocks/*(/N); do
  mkdir -p $app/Contents/Resources/Stocks/${stock:t}
  cp $stock/stock.json $stock/*.lut3d $app/Contents/Resources/Stocks/${stock:t}/
done
scripts/sign-app.sh $app -

xcrun swiftc -O -o $out/argent-drive scripts/measure/develop-memory/drive.swift

{
  print "commit $(git rev-parse HEAD)"
  # Untracked files too, which git diff leaves out.
  [[ -z $(git status --porcelain -- Sources Package.swift App) ]] && print "Sources, Package.swift and App as committed" \
    || print "UNCOMMITTED CHANGES in Sources, Package.swift or App"
  print "stocks $(<build/stocks/.stamp)"
  print "$(xcodebuild -version | tr '\n' ' ')"
  print "$(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(sysctl -n hw.model), $(sysctl -n machdep.cpu.brand_string), $(( $(sysctl -n hw.memsize) >> 30 )) GB"
} > $out/built-from.txt
print "built $app and $out/argent-drive"
cat $out/built-from.txt
