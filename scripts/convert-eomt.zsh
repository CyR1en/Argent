#!/bin/zsh
# Builds Argent's water model for the Sky mask's reflection veto: EoMT-DINOv3-L/16 (ADE20K-150 semantic), Core AI fp16, one padded square
# 1 x 3 x 768 x 768, output "maps" 1 x 3 x 192 x 192: water, sky, class index (docs/masking-plan.md sections 3 and 7; P0-S5's recipe, moved here).
# Writes, beside the Sky model:
#   build/models/eomt-sq768-f16.aimodel          a folder: main.mlirb, main.hash, metadata.json
#   build/models/eomt-sq768-f16.manifest.json    what made it, and its identity: recipe id, weights SHA-256, canary output hash
#   build/models/licences/                       the texts that travel with the models (scripts/models/licences/README.md)
# Pinned: exactly the 29 hash-locked packages of the Sky model's recipe (scripts/models/requirements.lock, nothing added), the weights and config
# by SHA-256, the graph in scripts/models/eomt_port.py. Plain fp16 gives NaN (DINOv3's residual stream reaches 132,118, past fp16's 65,504): the
# graph folds a constant 1/8 into every weight that writes the stream, an exact re-parametrisation (eomt_port.py, point 5). A conversion is not
# byte-deterministic (random symbol suffixes in the last ~16 KB of main.mlirb); what it computes is, and the canary output hash checks it.
#
#   scripts/convert-eomt.zsh [OUT]      OUT defaults to build/models
#   FORCE=1 rebuilds an existing model.  MODELS_WORK=DIR keeps the venv and downloads there instead of OUT/.work (shared with the Sky model's).
# Needs macOS on Apple silicon, Homebrew Python 3.14 and the network once (PyPI, Hugging Face). About 95 s from nothing, 5 to 8 s of conversion.
set -euo pipefail
zmodload zsh/datetime
here=${0:A:h}
recipe=$here/models
out=${1:-$here/../build/models}; mkdir -p "$out"; out=${out:A}
work=${MODELS_WORK:-$out/.work}; mkdir -p "$work"; work=${work:A}
venv=$work/venv
name=eomt-sq768-f16
RECIPE_ID=eomt-dinov3-l-ade150-sq768-f16-maps3-1

# ---- pins ---------------------------------------------------------------------------------------------------------------
PYTHON=${MODELS_PYTHON:-/opt/homebrew/opt/python@3.14/bin/python3.14}     # tested: Homebrew Python 3.14.10
WEIGHTS_URL=https://huggingface.co/tue-mps/eomt-dinov3-ade-semantic-large-512/resolve/1d1f172700ab69371df7afe778fe133fff7dd521   # card: license mit; the weights are a DINOv3 derivative (licences/README.md)
WEIGHTS_SHA256=319c72ee001fad0f81876fab96ae7148d13c259cd433a7326746e85e6b89d482   # model.safetensors, 1259835392 bytes
CONFIG_SHA256=a061170347144a5a1e7877e583ef55996bd57fbc847c33bddec6db59a54aa1a3    # config.json (the water and sky class ids are read from it)
CANARY_INPUT_SHA256=3af48f152d7e420b07d568b36cc18d4f6e20639ac664521011d843f7ea59f032   # P0-S5's canary_sq768.f16, rebuilt by canary_check.py from canary-DSC06673.png
CANARY_SHA256=63bdb66c474ed611e32d5ddcc274da3acae07a00b6270fbbcb136dcfd77e7a46          # fp16 maps on it: the same across conversions, runtimes and processes (P0-S5)
STREAM_SCALE=0.125

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

# ---- inputs, in their own directory, verified -------------------------------------------------------------------------------
mkdir -p "$work/downloads/eomt-weights"
fetch "$WEIGHTS_URL/model.safetensors" "$work/downloads/eomt-weights/model.safetensors" $WEIGHTS_SHA256
fetch "$WEIGHTS_URL/config.json" "$work/downloads/eomt-weights/config.json" $CONFIG_SHA256

# ---- convert, from a folder of its own with a scrubbed environment -----------------------------------------------------------
tmp=$out/.$name.tmp.aimodel
t0=$EPOCHREALTIME
(cd "$work" && env -i HOME=$HOME PATH=/usr/bin:/bin SWIFT_DETERMINISTIC_HASHING=1 \
  "$venv/bin/python" -I -B "$recipe/convert_eomt.py" --weights-dir "$work/downloads/eomt-weights" --out "$tmp" --height 768 --width 768 \
    --dtype float16 --stream-scale $STREAM_SCALE --outputs compact)
t1=$EPOCHREALTIME
mlirb=$tmp/main.mlirb
msha=$(sha "$mlirb")
[[ $msha == $(xxd -p -c 64 "$tmp/main.hash") ]] || fail "main.hash is not main.mlirb's SHA-256"

# ---- identity: the canary's output hash ------------------------------------------------------------------------------------
canary_out=$(cd "$work" && env -i HOME=$HOME PATH=/usr/bin:/bin USE_OS_COREAI=1 \
  "$venv/bin/python" -I -B "$recipe/canary_check.py" --kind eomt --model "$tmp" --picture "$recipe/canary-DSC06673.png" 2>/dev/null)
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
  "$(sha "$recipe/requirements.lock")" "$(sha "$recipe/convert_eomt.py")" "$(sha "$recipe/eomt_port.py")" "$WEIGHTS_SHA256" "$CONFIG_SHA256" "$canary_input" "$canary" \
  "$(printf '%.1f' $((t1 - t0)))" "$(sw_vers -buildVersion)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" <<'PY'
import json, sys
(path, rid, sha, size, kb, lock, conv, port, w, c, cin, cout, secs, build, when) = sys.argv[1:]
json.dump({"recipe id": rid, "weights sha256": w, "config sha256": c, "canary input sha256": cin, "canary output sha256": cout,
           "main.mlirb sha256": sha, "main.mlirb bytes": int(size), "bundle KiB": int(kb), "requirements.lock sha256": lock, "convert_eomt.py sha256": conv,
           "eomt_port.py sha256": port, "stream scale": 0.125, "conversion seconds": float(secs), "converted on macOS build": build, "converted at": when,
           "note": "not byte-deterministic: random symbol suffixes in the last ~16 KB of main.mlirb; the numbers computed are identical across conversions (the canary hash)"},
          open(path, "w"), indent=1)
PY
print "built $out/$name.aimodel  ($(stat -f %z "$out/$name.aimodel/main.mlirb") bytes in main.mlirb, sha256 $msha, canary $canary, conversion $(printf '%.1f' $((t1 - t0))) s)"
