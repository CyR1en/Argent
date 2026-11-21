#!/bin/zsh
# Builds Argent.app from the SwiftPM ArgentApp target: the binary, its resource bundles,
# App/Info.plist, the icon compiled from App/Argent.icon, the baked stocks, the smart masks' four models
# when build/models holds them, Remove's helper (argent-remove) and its four graphs when build/models holds them, the version from
# the newest v* tag, and a signature with App/Argent.entitlements, so the app runs sandboxed, the helper with
# App/ArgentRemoveHelper.entitlements. The signature is the self-signed "Argent Self-Signed" when a keychain holds it, else ad-hoc
# (scripts/sign-identity.sh); there is no Developer ID signing or notarization (docs/deferred.md).
#
# The stocks are baked with the Python bake tool at 65 cubed into build/stocks, and baked
# again only when bake/ changes. Only the manifests and the binary LUTs go into the bundle;
# the .cube text stays in build/stocks for inspection. The bake needs .venv with NumPy:
#   python3 -m venv .venv && .venv/bin/pip install numpy
#
#   scripts/build-app.sh            debug build into build/Argent.app
#   scripts/build-app.sh release    optimized build
#   scripts/build-app.sh debug open build, then launch it
set -euo pipefail
cd "$(dirname "$0")/.."

configuration=${1:-debug}

# The build needs Xcode: the Command Line Tools have neither actool, which compiles the icon,
# nor the SwiftUI macro plugin behind @State. Use an installed Xcode when xcode-select points
# at the tools. actool stands in for the whole toolchain here.
if ! xcrun --find actool >/dev/null 2>&1; then
  for xcode in /Applications/Xcode*.app(N); do
    if [[ -x $xcode/Contents/Developer/usr/bin/actool ]]; then
      export DEVELOPER_DIR=$xcode/Contents/Developer
      break
    fi
  done
fi
actool=$(xcrun --find actool 2>/dev/null || true)
if [[ -z $actool ]]; then
  echo "error: Xcode not found; install Xcode 27 or later to build the app" >&2
  exit 1
fi

# Bake the stocks when the bake tool, a profile or a paper has changed.
python=.venv/bin/python
if [[ ! -x $python ]]; then
  echo "error: $python is missing; create it with: python3 -m venv .venv && .venv/bin/pip install numpy" >&2
  exit 1
fi
stamp=$(scripts/stocks-stamp.sh)
if [[ ! -f build/stocks/.stamp || $(<build/stocks/.stamp) != "$stamp" ]]; then
  rm -rf build/stocks
  (cd bake && "../$python" -m argent_bake bake --all --size 65 --out ../build/stocks)
  echo "$stamp" > build/stocks/.stamp
fi

swift build -c "$configuration" --product Argent
swift build -c "$configuration" --product argent-remove
bin=$(swift build -c "$configuration" --show-bin-path)

app=build/Argent.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Argent" "$app/Contents/MacOS/Argent"
# Remove's helper, beside the app's binary: the app starts it as its child when the model is wanted (docs/remove-plan.md, 4.5).
cp "$bin/argent-remove" "$app/Contents/MacOS/argent-remove"
cp App/Info.plist "$app/Contents/Info.plist"
# The version, from the tag (.github/workflows/release.yml): ARGENT_VERSION when set (CI sets it from the v* tag it builds), else
# the highest well-formed vN.N.N[-suffix] tag behind HEAD without its v (a pre-release below its release; a malformed tag is
# passed over), else App/Info.plist's. CFBundleShortVersionString takes its numbers only (0.2.0 of 0.2.0-beta.1); ArgentVersion
# keeps the whole. CFBundleVersion is the commit count, which only grows along main. ArgentChannel is release, nightly or dev
# (ARGENT_CHANNEL, dev by default), and ArgentCommit the commit built; AboutView shows them.
version=${ARGENT_VERSION:-}
if [[ -z $version ]]; then
  for tag in ${(f)"$(git -c versionsort.suffix=- tag --merged HEAD --list 'v[0-9]*' --sort=-version:refname 2>/dev/null)"}; do
    if [[ $tag =~ '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' ]]; then
      version=${tag#v}
      break
    fi
  done
fi
[[ -n $version ]] || version=$(plutil -extract CFBundleShortVersionString raw App/Info.plist)
short=${version%%-*}
[[ $short =~ '^[0-9]+(\.[0-9]+){0,2}$' ]] || { echo "error: version $version is not N.N.N, optionally with a -suffix" >&2; exit 1; }
build_number=$(git rev-list --count HEAD 2>/dev/null || plutil -extract CFBundleVersion raw App/Info.plist)
commit=$(git rev-parse --short=7 HEAD 2>/dev/null || echo unknown)
[[ $commit == unknown ]] || git diff --quiet HEAD -- 2>/dev/null || commit+="-dirty"
channel=${ARGENT_CHANNEL:-dev}
plist=$app/Contents/Info.plist
plutil -replace CFBundleShortVersionString -string "$short" "$plist"
plutil -replace CFBundleVersion -string "$build_number" "$plist"
plutil -replace ArgentVersion -string "$version" "$plist"
plutil -replace ArgentChannel -string "$channel" "$plist"
plutil -replace ArgentCommit -string "$commit" "$plist"
# Develops to HEIC stay under 2 GB only with malloc's large cache off (docs/M2-shell.md section 10).
[[ $(plutil -extract LSEnvironment.MallocLargeCache raw "$app/Contents/Info.plist") == 0 ]] \
  || { echo "error: Info.plist lacks LSEnvironment MallocLargeCache 0" >&2; exit 1; }
for bundle in "$bin"/*.bundle(N); do
  cp -R "$bundle" "$app/Contents/Resources/"
done
# The icon is an Icon Composer document; actool compiles it into the Liquid Glass asset
# catalog and a flat .icns for older surfaces.
# Whole paths: actool hands its work to an agent that outlives it, and that agent resolves a relative path in the
# folder it was started from, which may be another checkout's (seen 2026-11-10: the icon compiled into a worktree's build).
"$actool" "$PWD/App/Argent.icon" --compile "$PWD/$app/Contents/Resources" --app-icon Argent \
  --platform macosx --minimum-deployment-target 27.0 --target-device mac \
  --output-partial-info-plist "$PWD/build/icon-partial.plist" --errors --warnings --output-format human-readable-text
[[ -f $app/Contents/Resources/Assets.car ]] || { echo "error: actool did not compile App/Argent.icon" >&2; exit 1; }
for stock in build/stocks/*(/N); do
  mkdir -p "$app/Contents/Resources/Stocks/${stock:t}"
  cp "$stock"/stock.json "$stock"/*.lut3d "$app/Contents/Resources/Stocks/${stock:t}/"
done
# The smart masks' models (docs/masking-plan.md section 7), built once by scripts/convert-da3-sky.zsh, scripts/convert-eomt.zsh,
# scripts/convert-s3od.zsh and scripts/convert-vitmatte.zsh into build/models, never in Git, and cloned here: cp -c shares the
# 1.5 GB of blocks with build/models (2 ms, no new disk), where a copy took 0.25 to 0.45 s a model and its size again. Signing
# seals them (about 3 s more). Without them the app builds and runs: Sky says it is unavailable, and Subject and Background offer the Subject models' download.
models=(da3-sky-sq756-f16 eomt-sq768-f16 s3od-sod-sq1024-f16 vitmatte-s-c1k-sq1024-f16)
missing=()
for model in $models; do
  if [[ -f build/models/$model.aimodel/main.hash && -f build/models/$model.manifest.json ]]; then
    mkdir -p "$app/Contents/Resources/Models"
    cp -c -R build/models/$model.aimodel "$app/Contents/Resources/Models/"
    cp build/models/$model.manifest.json "$app/Contents/Resources/Models/"
  else
    missing+=$model
  fi
done
if [[ -d $app/Contents/Resources/Models && -d build/models/licences ]]; then
  cp -R build/models/licences "$app/Contents/Resources/Models/Licences"
fi
# The Subject models' user-facing licence texts, in every build: the licence screen shows them before the user agrees to download them
# (SubjectModelsSheet), so they are there in a build without the models too. Internal notes (README.md) and Remove's ObjectClear licence stay out.
rm -rf "$app/Contents/Resources/Model Licences"
mkdir -p "$app/Contents/Resources/Model Licences"
subject_licences=(
  NOTICE.txt
  DINOv3-LICENSE.md
  S3OD-LICENSE-MIT.txt
  EoMT-LICENSE-MIT.txt
  ViTMatte-LICENSE-MIT.txt
  ADE20K-terms.txt
  FLUX1-Krea-dev-LICENSE.md
  S3OD-sod-model-card.md
  ViTMatte-S-Composition1k-model-card.md
)
for licence in $subject_licences; do
  cp "scripts/models/licences/$licence" "$app/Contents/Resources/Model Licences/$licence"
done
if (( ${#missing} )); then
  echo "note: not in build/models: ${(j:, :)missing}. The app builds; Sky says it is unavailable, and Subject and Background offer the Subject models' download." >&2
  echo "      Build the models with scripts/convert-da3-sky.zsh, scripts/convert-eomt.zsh, scripts/convert-s3od.zsh and scripts/convert-vitmatte.zsh (scripts/README.md)." >&2
fi
# Remove's four graphs and the prompt's fixed states (docs/remove-plan.md, 4.5), built once by scripts/convert-objectclear.zsh into
# build/models and cloned here as the mask models are: 5.9 GB shared with build/models, no new disk. All or none: without them the
# helper is not used, and Remove says it has no model.
remove_graphs=(objectclear-object-encoder objectclear-vae-encoder objectclear-unet objectclear-vae-decoder)
remove_whole=1
for graph in $remove_graphs; do
  [[ -f build/models/$graph.aimodel/main.hash && -f build/models/$graph.manifest.json ]] || remove_whole=0
done
[[ -f build/models/objectclear-text-states.f16 && -f build/models/objectclear-text-states.json ]] || remove_whole=0
if (( remove_whole )); then
  mkdir -p "$app/Contents/Resources/Models"
  for graph in $remove_graphs; do
    cp -c -R build/models/$graph.aimodel "$app/Contents/Resources/Models/"
    cp build/models/$graph.manifest.json "$app/Contents/Resources/Models/"
  done
  cp build/models/objectclear-text-states.f16 build/models/objectclear-text-states.json "$app/Contents/Resources/Models/"
else
  echo "note: Remove's graphs are not all in build/models (scripts/convert-objectclear.zsh makes them). The app builds, and Remove says it has no model." >&2
  echo "      Build them with scripts/convert-objectclear.zsh." >&2
fi
# The helper first: the app's signature seals it. Sandboxed and inheriting, it runs in the app's sandbox and container.
# The identity is "Argent Self-Signed" when a keychain holds it, else ad-hoc (scripts/sign-identity.sh).
identity=$(scripts/sign-identity.sh)
codesign --force --sign "$identity" --options runtime --entitlements App/ArgentRemoveHelper.entitlements "$app/Contents/MacOS/argent-remove"
codesign --force --sign "$identity" --options runtime --entitlements App/Argent.entitlements "$app"
codesign --verify --strict "$app"
[[ $identity == - ]] && signed_by="ad-hoc" || signed_by="signed by $identity"
echo "built $app ($configuration, $version $channel, build $build_number, $commit, $signed_by)"

if [[ ${2:-} == open ]]; then
  open "$app"
fi
