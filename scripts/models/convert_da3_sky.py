"""Depth Anything 3 Mono-Large (sky and depth heads) to Core AI: fp16, one fixed shape 1 x 1 x 3 x 756 x 756.
Standalone: reads the weights and the DA3 source from the directories it is given, writes one .aimodel. Run it through scripts/convert-da3-sky.zsh.
usage: convert_da3_sky.py --weights-dir DIR --code-dir DIR --out PATH.aimodel
The graph is R4's (src/e2_convert.py) with the sky and depth outputs of the head. Differences from R4's script: fixed shape 756 x 756, no eager reference
forward (R4: 149 s of CPU, not needed to export), asset metadata with a fixed creation date, no logging into another report's folder."""
import argparse, json, os, shutil, sys, time, warnings
warnings.filterwarnings("ignore")
ap = argparse.ArgumentParser()
ap.add_argument("--weights-dir", required=True); ap.add_argument("--code-dir", required=True); ap.add_argument("--out", required=True)
args = ap.parse_args()
H = W = 756
sys.path.insert(0, os.path.join(args.code_dir, "src"))
import torch
from safetensors.torch import load_file
from depth_anything_3.model.da3 import DepthAnything3Net
from depth_anything_3.model.dinov2.dinov2 import DinoV2
from depth_anything_3.model.dpt import DPT
from coreai_torch import TorchConverter, get_decomp_table
from coreai.runtime import AIModelAssetMetadata
torch.manual_seed(0)
def stage(name, t0, note=""): print(f"[{name}] {time.time() - t0:.1f}s {note}", flush=True)
t0 = time.time()
cfg = json.load(open(os.path.join(args.weights_dir, "config.json")))["config"]; n = cfg["net"]; h = cfg["head"]
bb = DinoV2(name=n["name"], out_layers=n["out_layers"], alt_start=n["alt_start"], qknorm_start=n["qknorm_start"], rope_start=n["rope_start"], cat_token=n["cat_token"])
head = DPT(dim_in=h["dim_in"], output_dim=h["output_dim"], features=h["features"], out_channels=h["out_channels"])
net = DepthAnything3Net(net=bb, head=head)
net.load_state_dict({k[6:]: v for k, v in load_file(os.path.join(args.weights_dir, "model.safetensors")).items()}, strict=True)
class DA3Sky(torch.nn.Module):
    def __init__(self, net):
        super().__init__(); self.net = net
    def forward(self, image):
        feats, _ = self.net.backbone(image, cam_token=None, export_feat_layers=[], ref_view_strategy="saddle_balanced")
        out = self.net.head(feats, image.shape[-2], image.shape[-1], patch_start_idx=0)
        return out["sky"], out["depth"]
m = DA3Sky(net).eval().to(torch.float16)
x = torch.zeros(1, 1, 3, H, W, dtype=torch.float16)
stage("load", t0)
t0 = time.time(); ep = torch.export.export(m, args=(), kwargs={"image": x}); stage("export", t0)
t0 = time.time(); ep = ep.run_decompositions(get_decomp_table()); stage("decompose", t0)
t0 = time.time()
prog = TorchConverter(mode=TorchConverter.Mode.RELEASE).add_exported_program(exported_program=ep, input_names=["image"], output_names=["sky", "depth"]).to_coreai(); stage("to_coreai", t0)
t0 = time.time()
from pathlib import Path
out = Path(os.path.abspath(args.out))   # save_asset wants a pathlib.Path ending in .aimodel
if out.exists(): shutil.rmtree(out)
md = AIModelAssetMetadata(); md.author = "ByteDance Seed (Depth Anything 3)"; md.license = "Apache-2.0"
md.model_description = f"DA3 Mono-Large sky+depth, {H}x{W} float16"; md.creation_date = 1
prog.save_asset(out, md); stage("save", t0, out)
