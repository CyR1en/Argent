"""The fixed prompt's states as one file the app bundles, so that no text encoder ships (docs/remove-plan.md section 4.5).
usage: objectclear_text_states.py --weights WEIGHTS/ObjectClear --out DIR
Runs objectclear_port.py's TextStates (SDXL's two CLIP text encoders, on the prompt's pinned token ids) once, in float32 on one CPU thread, and writes
  DIR/objectclear-text-states.f16     little-endian half floats, no header: the states, 77 x 2048 values, row by row; then the pooled state, 1280 values
  DIR/objectclear-text-states.json    the layout, the prompt, its tokens, the row the object's embedding replaces, and the file's SHA-256
Prints  STATES <sha256 of the .f16 file>.  Needs only the 29 locked packages."""
import argparse, hashlib, json, os, sys, warnings
warnings.filterwarnings("ignore")
ap = argparse.ArgumentParser(); ap.add_argument("--weights", required=True); ap.add_argument("--out", required=True); args = ap.parse_args()
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, torch
from safetensors.torch import load_file
import objectclear_port as port
torch.set_num_threads(1)
m = port.TextStates().load_weights(load_file(os.path.join(args.weights, "text_encoder/model.fp16.safetensors")), load_file(os.path.join(args.weights, "text_encoder_2/model.fp16.safetensors"))).eval().float()
with torch.no_grad(): states, pooled = m()
states = states.numpy().astype("<f2"); pooled = pooled.numpy().astype("<f2")
assert states.shape == (1, 77, 2048) and pooled.shape == (1, 1280) and np.isfinite(states).all() and np.isfinite(pooled).all()
os.makedirs(args.out, exist_ok=True); path = os.path.join(args.out, "objectclear-text-states.f16")
with open(path, "wb") as f: f.write(states.tobytes()); f.write(pooled.tobytes())
digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
json.dump({"file": "objectclear-text-states.f16", "dtype": "float16, little-endian", "sha256": digest,
           "states": {"offset bytes": 0, "shape": [1, 77, 2048], "what": "the UNet's `states` for the conditional branch, before the object's row is put in"},
           "pooled": {"offset bytes": 77 * 2048 * 2, "shape": [1, 1280], "what": "the UNet's `pooled` for the conditional branch"},
           "unconditional": "zeros for both (guidance above 1 only)", "fuse index": port.FUSE_INDEX,
           "fuse": "row `fuse index` of the states is replaced by the object encoder's `fused` output (1 x 2048) for each job",
           "prompt": port.PROMPT, "token ids, text encoder 1": port.TOKENS_1, "token ids, text encoder 2": port.TOKENS_2,
           "range": [float(states.min()), float(states.max())]}, open(os.path.join(args.out, "objectclear-text-states.json"), "w"), indent=1)
print("STATES " + digest, flush=True)
