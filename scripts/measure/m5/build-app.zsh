#!/bin/zsh
# Builds the app-level M5 measuring app (T1, T2, T3, T7 in docs/SPEC.md#performance-targets). The drive
# hook is compiled only with DEBUG, so the measured app is the optimized build of scripts/build-app.sh
# release with -DDEBUG added: the same -O code, plus the hook and its probes (FrameShowProbe,
# SheetProbe). It goes under its own bundle identifier, camera.argent.Argent.m5, with its own container,
# caches and recipe library, answering only camera.argent.Argent.m5.drive; it is assembled with the six
# baked stocks and signed ad hoc with the app's entitlements, so it runs sandboxed. First runs
# scripts/build-app.sh release, which bakes build/stocks when bake/ changed and checks the plain
# optimized build. Also builds argent-drive (scripts/measure/develop-memory/drive.swift). Both go into
# EVIDENCE/build, beside a note of the commit and machine.
#
#   scripts/measure/m5/build-app.zsh EVIDENCE
set -euo pipefail
cd "$(dirname "$0")/../../.."

evidence=${1:?usage: build-app.zsh EVIDENCE}
out=$evidence/build
mkdir -p $out

# Xcode's toolchain when xcode-select points at the Command Line Tools, which lack SwiftUI's macros.
if [[ $(xcode-select -p) == */CommandLineTools && -z ${DEVELOPER_DIR:-} ]]; then
  for xcode in /Applications/Xcode*.app(N); do export DEVELOPER_DIR=$xcode/Contents/Developer; break; done
fi

scripts/build-app.sh release

scratch=.build/m5-app
swift build -c release -Xswiftc -DDEBUG --scratch-path $scratch --product Argent
bin=$(swift build -c release -Xswiftc -DDEBUG --scratch-path $scratch --show-bin-path)

app=$out/Argent-m5.app
rm -rf $app
mkdir -p $app/Contents/MacOS $app/Contents/Resources
cp $bin/Argent $app/Contents/MacOS/Argent
cp App/Info.plist $app/Contents/Info.plist
plutil -replace CFBundleIdentifier -string camera.argent.Argent.m5 $app/Contents/Info.plist
for bundle in $bin/*.bundle(N); do
  cp -R $bundle $app/Contents/Resources/
done
# The compiled icon and the stocks as scripts/build-app.sh put them into build/Argent.app.
cp build/Argent.app/Contents/Resources/Assets.car build/Argent.app/Contents/Resources/*.icns(N) $app/Contents/Resources/
cp -R build/Argent.app/Contents/Resources/Stocks $app/Contents/Resources/
codesign --force --sign - --options runtime --entitlements App/Argent.entitlements $app
codesign --verify --strict $app

xcrun swiftc -O -o $out/argent-drive scripts/measure/develop-memory/drive.swift

{
  print "commit $(git rev-parse HEAD)"
  # Untracked files too, which git diff leaves out.
  [[ -z $(git status --porcelain -- Sources Package.swift App) ]] && print "Sources, Package.swift and App as committed" \
    || print "UNCOMMITTED CHANGES in Sources, Package.swift or App"
  print "release -DDEBUG, scratch $scratch"
  print "stocks $(<build/stocks/.stamp)"
  print "$(xcodebuild -version | tr '\n' ' ')"
  print "$(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(sysctl -n hw.model), $(sysctl -n machdep.cpu.brand_string), $(( $(sysctl -n hw.memsize) >> 30 )) GB"
} > $out/built-from.txt
print "built $app and $out/argent-drive"
cat $out/built-from.txt
