"""EoMT-DINOv3-L/16 ADE20K-150 to Core AI: one fixed input shape, 1 x 3 x H x W, output "maps" (1, 3, H/4, W/4) fp16: water, sky, class index (--outputs full: "probs" (1, 150, H/4, W/4)).
usage: convert_eomt.py --weights-dir DIR --out PATH.aimodel --height H --width W [--dtype float16|float32] [--tail float32|float16]
Reads DIR/model.safetensors (tue-mps/eomt-dinov3-ade-semantic-large-512 at the pinned revision) and builds eomt_port.py's graph (beside this file). Needs only the 29 locked packages. Run it through scripts/convert-eomt.zsh."""
import argparse, os, shutil, sys, time, warnings
warnings.filterwarnings("ignore")
ap = argparse.ArgumentParser()
ap.add_argument("--weights-dir", required=True); ap.add_argument("--out", required=True)
ap.add_argument("--height", type=int, required=True); ap.add_argument("--width", type=int, required=True)
ap.add_argument("--dtype", default="float16"); ap.add_argument("--tail", default="float32")
ap.add_argument("--stream-scale", type=float, default=0.125); ap.add_argument("--no-fold-q", action="store_true"); ap.add_argument("--outputs", default="compact", choices=["compact", "full"])
args = ap.parse_args()
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import torch, json
from safetensors.torch import load_file
import eomt_port
from coreai_torch import TorchConverter, get_decomp_table
from coreai.runtime import AIModelAssetMetadata
from pathlib import Path
torch.manual_seed(0)
def stage(name, t0, note=""): print(f"[{name}] {time.time() - t0:.1f}s {note}", flush=True)
H, W = args.height, args.width
dt = {"float16": torch.float16, "float32": torch.float32}[args.dtype]
t0 = time.time()
cfg = json.load(open(os.path.join(args.weights_dir, "config.json"))); id2 = {int(k): v.strip() for k, v in cfg["id2label"].items()}; nm = {v: k for k, v in id2.items()}
water_ids = [nm[n] for n in ("water", "sea", "river", "lake", "waterfall", "swimming pool", "fountain")]; sky_id = nm["sky"]
print("water class ids", water_ids, "sky", sky_id)
m = eomt_port.EomtL(H, W, tail_dtype={"float16": torch.float16, "float32": torch.float32}[args.tail], stream_scale=args.stream_scale, fold_q_scale=not args.no_fold_q,
                    outputs=args.outputs, water_ids=water_ids, sky_id=sky_id).load_weights(load_file(os.path.join(args.weights_dir, "model.safetensors"))).eval().to(dt)
x = torch.zeros(1, 3, H, W, dtype=dt)
stage("load", t0)
t0 = time.time(); ep = torch.export.export(m, args=(), kwargs={"image": x}); stage("export", t0)
t0 = time.time(); ep = ep.run_decompositions(get_decomp_table()); stage("decompose", t0)
t0 = time.time()
prog = TorchConverter(mode=TorchConverter.Mode.RELEASE).add_exported_program(exported_program=ep, input_names=["image"], output_names=["maps" if args.outputs == "compact" else "probs"]).to_coreai(); stage("to_coreai", t0)
t0 = time.time()
out = Path(os.path.abspath(args.out))
if out.exists(): shutil.rmtree(out)
md = AIModelAssetMetadata(); md.author = "tue-mps/eomt-dinov3-ade-semantic-large-512 (EoMT code MIT; backbone weights derived from Meta DINOv3)"; md.license = "EoMT code MIT; weights under the DINOv3 licence; trained on ADE20K (its terms)"
md.model_description = f"EoMT-DINOv3-L ADE20K-150 semantic, {H}x{W} {args.dtype}, tail {args.tail}, stream scale {args.stream_scale}, q fold {not args.no_fold_q}, outputs {args.outputs}"; md.creation_date = 1
prog.save_asset(out, md); stage("save", t0, out)
