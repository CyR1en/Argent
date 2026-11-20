"""S3OD-sod to Core AI: one fixed input shape, 1 x 3 x 1024 x 1024, outputs "masks" (1, 3, 1024, 1024) fp16 and "iou" (1, 3) fp32.
usage: convert_s3od.py --weights PATH/s3od.pt --out PATH.aimodel [--dtype float16|float32] [--stream-scale S] [--no-fold-q] [--attn float32|same] [--plain]
Reads the checkpoint with weights_only=True and builds s3od_port.py's graph (beside this file). Needs only the 29 locked packages."""
import argparse, os, shutil, sys, time, warnings
warnings.filterwarnings("ignore")
ap = argparse.ArgumentParser()
ap.add_argument("--weights", required=True); ap.add_argument("--out", required=True)
ap.add_argument("--dtype", default="float16"); ap.add_argument("--stream-scale", type=float, default=1.0); ap.add_argument("--no-fold-q", action="store_true")
ap.add_argument("--attn", default="float32", choices=["float32", "same"]); ap.add_argument("--tail", default="float32")
args = ap.parse_args()
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import torch
import s3od_port
from coreai_torch import TorchConverter, get_decomp_table
from coreai.runtime import AIModelAssetMetadata
from pathlib import Path
torch.manual_seed(0)
def stage(name, t0, note=""): print(f"[{name}] {time.time() - t0:.1f}s {note}", flush=True)
DT = {"float16": torch.float16, "float32": torch.float32}
dt = DT[args.dtype]
t0 = time.time()
sd = torch.load(args.weights, map_location="cpu", weights_only=True)["state_dict"]
m = s3od_port.S3odSod(1024, 1024, stream_scale=args.stream_scale, fold_q_scale=not args.no_fold_q, tail_dtype=DT[args.tail],
                      attn_dtype=None if args.attn == "same" else DT[args.attn]).load_weights(sd).eval().to_inference_dtype(dt)
x = torch.zeros(1, 3, 1024, 1024, dtype=dt)
print("parameters kept", sum(p.numel() for p in m.parameters()) / 1e6, "M", flush=True)
stage("load", t0)
t0 = time.time(); ep = torch.export.export(m, args=(), kwargs={"image": x}); stage("export", t0)
t0 = time.time(); ep = ep.run_decompositions(get_decomp_table()); stage("decompose", t0)
t0 = time.time()
prog = TorchConverter(mode=TorchConverter.Mode.RELEASE).add_exported_program(exported_program=ep, input_names=["image"], output_names=["masks", "iou"]).to_coreai(); stage("to_coreai", t0)
t0 = time.time()
out = Path(os.path.abspath(args.out))
if out.exists(): shutil.rmtree(out)
md = AIModelAssetMetadata(); md.author = "okupyn/s3od-sod (S3OD code MIT; backbone weights derived from Meta DINOv3)"; md.license = "S3OD code MIT; weights under the DINOv3 licence"
md.model_description = f"S3OD-sod 1024x1024 {args.dtype}, attention {args.attn}, stream scale {args.stream_scale}, q fold {not args.no_fold_q}"; md.creation_date = 1
prog.save_asset(out, md); stage("save", t0, out)
