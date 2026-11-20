"""Y2: ViTMatte-S to Core AI: one fixed 1 x 4 x 1024 x 1024 input "image" (RGB normalised mean .5 std .5, trimap in [0, 1]), output "alpha" fp16.
usage: convert_vitmatte.py --weights model.safetensors --out PATH.aimodel [--dtype float16|float32] [--tile 1024]. Needs the coreai-torch venv (V4's hash-locked packages)."""
import argparse, os, shutil, sys, time, warnings
warnings.filterwarnings('ignore')
ap = argparse.ArgumentParser(); ap.add_argument('--weights', required=True); ap.add_argument('--out', required=True); ap.add_argument('--dtype', default='float16'); ap.add_argument('--tile', type=int, default=1024)
a = ap.parse_args(); sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import torch, vitmatte_port
from safetensors.torch import load_file
from coreai_torch import TorchConverter, get_decomp_table
from coreai.runtime import AIModelAssetMetadata
from pathlib import Path
torch.manual_seed(0)
DT = {'float16': torch.float16, 'float32': torch.float32}; dt = DT[a.dtype]
t0 = time.time(); m = vitmatte_port.VitMatteS(tile=a.tile).load_weights(load_file(a.weights)).eval().to(dt)
x = torch.zeros(1, 4, a.tile, a.tile, dtype=dt); print('parameters', sum(p.numel() for p in m.parameters()) / 1e6, 'M'); print('load', time.time() - t0, flush=True)
t = time.time(); ep = torch.export.export(m, args=(), kwargs={'image': x}); print('export', time.time() - t, flush=True)
t = time.time(); ep = ep.run_decompositions(get_decomp_table()); print('decompose', time.time() - t, flush=True)
t = time.time(); prog = TorchConverter(mode=TorchConverter.Mode.RELEASE).add_exported_program(exported_program=ep, input_names=['image'], output_names=['alpha']).to_coreai(); print('to_coreai', time.time() - t, flush=True)
out = Path(os.path.abspath(a.out))
if out.exists(): shutil.rmtree(out)
md = AIModelAssetMetadata(); md.author = 'hustvl/ViTMatte (MIT); ViTMatte-S Composition-1k weights'; md.license = 'MIT (code); Composition-1k research data'; md.model_description = f'ViTMatte-S {a.tile} square {a.dtype}: alpha'; md.creation_date = 1
prog.save_asset(out, md); print('saved', out, flush=True)
