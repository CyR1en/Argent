#!/bin/zsh
# Embeds Sparkle.framework from a SwiftPM build into an assembled .app bundle's Contents/Frameworks
# and ensures Contents/MacOS/Argent carries @executable_path/../Frameworks in LC_RPATH.
#
#   scripts/embed-sparkle.sh path/to/Argent.app [SWIFT_BIN_DIR]
set -euo pipefail

if (( $# < 1 || $# > 2 )); then
  print -u2 "usage: scripts/embed-sparkle.sh APP_BUNDLE [SWIFT_BIN_DIR]"
  exit 2
fi

app=${1:A}
root=${0:A:h:h}
bin=${2:-}
[[ -n $bin ]] && bin=${bin:A}

[[ -d $app ]] || { print -u2 "error: app bundle not found: $app"; exit 1; }
binary=$app/Contents/MacOS/Argent
[[ -f $binary ]] || { print -u2 "error: app binary not found: $binary"; exit 1; }

# Locate Sparkle.framework: SwiftPM copies binary frameworks beside the built executables in $bin,
# and also keeps the extracted XCFramework under the scratch directory's artifacts/.
candidates=()
if [[ -n $bin ]]; then
  candidates+=("$bin/Sparkle.framework")
  scratch=${bin:h:h}
  candidates+=("$scratch/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework")
fi
candidates+=("$root/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework")

sparkle_src=""
for candidate in $candidates; do
  if [[ -d $candidate ]]; then
    sparkle_src=$candidate
    break
  fi
done
if [[ -z $sparkle_src ]]; then
  print -u2 "error: Sparkle.framework not found; checked: ${(j:, :)candidates}"
  exit 1
fi

mkdir -p "$app/Contents/Frameworks"
rm -rf "$app/Contents/Frameworks/Sparkle.framework"
# ditto preserves framework symlinks (Versions/Current, Sparkle, Resources, XPCServices).
ditto "$sparkle_src" "$app/Contents/Frameworks/Sparkle.framework"

# Add @executable_path/../Frameworks to LC_RPATH idempotently before codesign seals the binary.
rpath='@executable_path/../Frameworks'
if ! otool -l "$binary" | grep -Fq "path $rpath "; then
  install_name_tool -add_rpath "$rpath" "$binary"
fi
