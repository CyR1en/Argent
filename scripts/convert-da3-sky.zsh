#!/bin/zsh
# Builds Argent's Sky model: Depth Anything 3 Mono-Large, its sky and depth heads, Core AI fp16, one padded square 1 x 1 x 3 x 756 x 756
# (docs/masking-plan.md section 7; P0-S1b's recipe, moved here). Writes, beside the EoMT model:
#   build/models/da3-sky-sq756-f16.aimodel          a folder: main.mlirb, main.hash, metadata.json
#   build/models/da3-sky-sq756-f16.manifest.json    what made it, and its identity: recipe id, weights SHA-256, canary output hash
#   build/models/licences/                          the texts that travel with the models (scripts/models/licences/README.md)
# Pinned: the 29 hash-locked packages of scripts/models/requirements.lock, the weights, config and DA3 source by SHA-256, the graph in
# scripts/models/convert_da3_sky.py. A conversion is not byte-deterministic: random symbol suffixes in the last ~16 KB of main.mlirb differ from
# run to run, while every number the model computes is the same. So the model is named by its recipe id, its weights' SHA-256 and the hash of its
# outputs on the canary picture, which this script checks against the pinned one; main.mlirb's SHA-256 names one file, and the compiled copy.
#
#   scripts/convert-da3-sky.zsh [OUT]      OUT defaults to build/models
#   FORCE=1 rebuilds an existing model.  MODELS_WORK=DIR keeps the venv, downloads and source there instead of OUT/.work (about 2.4 GB, deletable).
# Needs macOS on Apple silicon, Homebrew Python 3.14 (brew install python@3.14) and the network once (PyPI, Hugging Face, GitHub). About two
# minutes from nothing: the venv from cached wheels, a 1.34 GB download, 5 s of conversion.
set -euo pipefail
zmodload zsh/datetime
here=${0:A:h}
recipe=$here/models
out=${1:-$here/../build/models}; mkdir -p "$out"; out=${out:A}
work=${MODELS_WORK:-$out/.work}; mkdir -p "$work"; work=${work:A}
venv=$work/venv
name=da3-sky-sq756-f16
RECIPE_ID=da3-mono-large-sq756-f16-sky-depth-1

# ---- pins ---------------------------------------------------------------------------------------------------------------
PYTHON=${MODELS_PYTHON:-/opt/homebrew/opt/python@3.14/bin/python3.14}          # tested: Homebrew Python 3.14.10 (the lock has cp314 wheels)
WEIGHTS_URL=https://huggingface.co/depth-anything/DA3MONO-LARGE/resolve/f465978e618db8cc79c83b8bbf24964857db1875   # Apache-2.0
WEIGHTS_SHA256=7a799a7f95eb8d4c404c2ca8be3dc3276b350a417ddc4420db72ba850cc0e960   # model.safetensors, 1336734448 bytes
CONFIG_SHA256=649809acdfe99631293430bfb8bcd85620a1bba47bb4e27689bd204c645a4204    # config.json
CODE_URL=https://codeload.github.com/ByteDance-Seed/Depth-Anything-3/tar.gz/3d835ec1a5802d64a8b8b15f817a1ab54809bfe4   # Apache-2.0
CODE_SHA256=98aa2dd53ab44b96cef5190ae4841c6ae51797d099b784e08e12a1a55bd3a69b      # the tarball (GitHub may re-compress archives; the tree digest is the real pin)
CODE_TREE_SHA256=69051391f696c5201ce47c9b7ec02318d0adb51fb1b4ceee2bb451f310240554  # sha256 of the sorted per-file sha256 lines of the extracted tree
CANARY_INPUT_SHA256=746a0694c301cc1355533f06a83c29b4e0430b4b5d6bb992d73ce35c77c2e21b   # the fp16 square canary_check.py makes from canary-DSC06673.png
CANARY_SHA256=4873a5f8b6c37fce6806ae33f77ef1ba067503011fe63d590ab5b394a597be26          # fp16 sky then depth on it: the same across conversions (two, 2026-11-07)

fail() { print -u2 "error: $*"; exit 1 }
sha() { shasum -a 256 "$1" | cut -d' ' -f1 }
fetch() {   # url dest sha256
  if [[ -f $2 && $(sha "$2") == $3 ]]; then return; fi
  rm -f "$2"; curl -L --fail --retry 3 -sS -o "$2" "$1"
  [[ $(sha "$2") == $3 ]] || fail "$2 does not match its pinned SHA-256 $3"
}

[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || fail "needs macOS on Apple silicon (the lock has macOS arm64 wheels)"
[[ -x $PYTHON ]] || fail "no $PYTHON (brew install python@3.14)"
[[ $($PYTHON -I -c 'import sys; print("%d.%d" % sys.version_info[:2])') == 3.14 ]] || fail "$PYTHON is not Python 3.14"
if [[ -d $out/$name.aimodel && ${FORCE:-0} != 1 ]]; then print "$out/$name.aimodel exists (FORCE=1 rebuilds)"; exit 0; fi

# ---- environment: exactly the locked packages ----------------------------------------------------------------------------
if [[ ! -x $venv/bin/python ]]; then $PYTHON -m venv "$venv"; fi
"$venv/bin/python" -I -m pip install -q --disable-pip-version-check --require-hashes --no-deps -r "$recipe/requirements.lock"
"$venv/bin/python" -I -m pip check

# ---- inputs, each in its own directory, verified ---------------------------------------------------------------------------
mkdir -p "$work/downloads/da3-weights" "$work/downloads/da3-code"
fetch "$WEIGHTS_URL/model.safetensors" "$work/downloads/da3-weights/model.safetensors" $WEIGHTS_SHA256
fetch "$WEIGHTS_URL/config.json" "$work/downloads/da3-weights/config.json" $CONFIG_SHA256
fetch "$CODE_URL" "$work/downloads/da3-code/da3-code.tar.gz" $CODE_SHA256
src=$work/da3-src
rm -rf "${src:?}"
mkdir -p "$src" && tar -xzf "$work/downloads/da3-code/da3-code.tar.gz" -C "$src" --strip-components=1
tree=$(cd "$src" && find . -type f -not -name '*.pyc' | LC_ALL=C sort | while read -r f; do shasum -a 256 "$f"; done | shasum -a 256 | cut -d' ' -f1)
[[ $tree == $CODE_TREE_SHA256 ]] || fail "DA3 source tree digest $tree is not the pinned $CODE_TREE_SHA256"
# DA3's LICENSE is kept in the recipes' folder as DA3-LICENSE, for the mask models' download and its licence screen, which are made without this
# conversion (scripts/build-mask-models.zsh, scripts/build-app.sh): that copy has to be the pinned tree's own. It goes out with the others below.
cmp -s "$src/LICENSE" "$recipe/licences/DA3-LICENSE" || fail "scripts/models/licences/DA3-LICENSE is not the LICENSE of the pinned DA3 source tree"

# ---- convert, from a folder of its own with a scrubbed environment -----------------------------------------------------------
tmp=$out/.$name.tmp.aimodel
t0=$EPOCHREALTIME
(cd "$work" && env -i HOME=$HOME PATH=/usr/bin:/bin SWIFT_DETERMINISTIC_HASHING=1 \
  "$venv/bin/python" -I -B "$recipe/convert_da3_sky.py" --weights-dir "$work/downloads/da3-weights" --code-dir "$src" --out "$tmp")
t1=$EPOCHREALTIME
mlirb=$tmp/main.mlirb
msha=$(sha "$mlirb")
[[ $msha == $(xxd -p -c 64 "$tmp/main.hash") ]] || fail "main.hash is not main.mlirb's SHA-256"

# ---- identity: the canary's output hash ------------------------------------------------------------------------------------
canary_out=$(cd "$work" && env -i HOME=$HOME PATH=/usr/bin:/bin USE_OS_COREAI=1 \
  "$venv/bin/python" -I -B "$recipe/canary_check.py" --kind da3 --model "$tmp" --picture "$recipe/canary-DSC06673.png" 2>/dev/null)
canary_input=${${(M)${(f)canary_out}:#INPUT *}#INPUT }
canary=${${(M)${(f)canary_out}:#CANARY *}#CANARY }
[[ $canary_input == $CANARY_INPUT_SHA256 ]] || fail "canary input $canary_input is not the pinned $CANARY_INPUT_SHA256"
[[ $canary == $CANARY_SHA256 ]] || fail "canary output hash $canary is not the pinned $CANARY_SHA256: this model computes something else"
rm -rf "$out/$name.aimodel"
mv "$tmp" "$out/$name.aimodel"

# ---- licences and record -----------------------------------------------------------------------------------------------------
mkdir -p "$out/licences"
cp "$recipe"/licences/*(.) "$out/licences/"
"$venv/bin/python" -I - "$out/$name.manifest.json" "$RECIPE_ID" "$msha" "$(stat -f %z "$out/$name.aimodel/main.mlirb")" "$(du -sk "$out/$name.aimodel" | cut -f1)" \
  "$(sha "$recipe/requirements.lock")" "$(sha "$recipe/convert_da3_sky.py")" "$WEIGHTS_SHA256" "$CONFIG_SHA256" "$tree" "$canary_input" "$canary" \
  "$(printf '%.1f' $((t1 - t0)))" "$(sw_vers -buildVersion)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" <<'PY'
import json, sys
(path, rid, sha, size, kb, lock, conv, w, c, tree, cin, cout, secs, build, when) = sys.argv[1:]
json.dump({"recipe id": rid, "weights sha256": w, "config sha256": c, "da3 source tree sha256": tree, "canary input sha256": cin, "canary output sha256": cout,
           "main.mlirb sha256": sha, "main.mlirb bytes": int(size), "bundle KiB": int(kb), "requirements.lock sha256": lock, "convert_da3_sky.py sha256": conv,
           "conversion seconds": float(secs), "converted on macOS build": build, "converted at": when,
           "note": "not byte-deterministic: random symbol suffixes in the last ~16 KB of main.mlirb; the numbers computed are identical across conversions (the canary hash)"},
          open(path, "w"), indent=1)
PY
rm -rf "${src:?}"
print "built $out/$name.aimodel  ($(stat -f %z "$out/$name.aimodel/main.mlirb") bytes in main.mlirb, sha256 $msha, canary $canary, conversion $(printf '%.1f' $((t1 - t0))) s)"
