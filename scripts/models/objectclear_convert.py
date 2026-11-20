"""One of ObjectClear's four graphs to Core AI. Run it through scripts/convert-objectclear.zsh.
usage: objectclear_convert.py --graph vae_decoder|vae_encoder|object_encoder|unet --weights WEIGHTS/ObjectClear --out PATH.aimodel
                              [--dtype float16|float32] [--norm float32] [--height H --width W | --sizes HxW,HxW,... | --dynamic] [--debug]
Builds objectclear_port.py's module (beside this file) from the pinned safetensors and converts it. Needs only the 29 locked packages.

Sizes are the picture's, in pixels, height first. One size makes one function, `main`, of that fixed shape. `--sizes` makes one function a size, named
`s<height>x<width>`, in one asset that stores the weights once. `--dynamic` makes one `main` whose height and width are symbolic: any multiple of 16
from --min-side to --max-side. The object encoder has one shape, 224 x 224, whatever is asked.
Names. vae_decoder: latents -> picture.  vae_encoder: picture -> moments.  object_encoder: object -> fused, embeds.
       unet: sample, timestep, states, pooled, time_ids -> noise, attention.   All float32 at the edge (objectclear_port.py)."""
import argparse, gc, json, os, resource, shutil, sys, time, warnings
warnings.filterwarnings("ignore")
ap = argparse.ArgumentParser()
ap.add_argument("--graph", required=True, choices=["vae_decoder", "vae_encoder", "object_encoder", "unet"]); ap.add_argument("--weights", required=True); ap.add_argument("--out", required=True)
ap.add_argument("--dtype", default="float16"); ap.add_argument("--norm"); ap.add_argument("--height", type=int, default=1328); ap.add_argument("--width", type=int, default=512)
ap.add_argument("--sizes"); ap.add_argument("--dynamic", action="store_true"); ap.add_argument("--min-side", type=int, default=64); ap.add_argument("--max-side", type=int, default=1344)
ap.add_argument("--debug", action="store_true")
args = ap.parse_args()
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import torch
from pathlib import Path
from safetensors.torch import load_file
import objectclear_port as port
from coreai_torch import TorchConverter, get_decomp_table
from coreai.runtime import AIModelAssetMetadata
torch.manual_seed(0)
def stage(name, t0, note=""): print(f"[{name}] {time.time() - t0:.1f}s peak {resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 2 ** 30:.2f} GiB rss {note}", flush=True)
DT = {"float16": torch.float16, "float32": torch.float32}
W = lambda rel: load_file(os.path.join(args.weights, rel))

t0 = time.time()
if args.graph == "vae_decoder": m = port.VaeDecoder().load_weights(W("vae/diffusion_pytorch_model.fp16.safetensors")); names = (["latents"], ["picture"])
elif args.graph == "vae_encoder": m = port.VaeEncoder().load_weights(W("vae/diffusion_pytorch_model.fp16.safetensors")); names = (["picture"], ["moments"])
elif args.graph == "object_encoder": m = port.ObjectEncoder().load_weights(W("image_prompt_encoder/model.fp16.safetensors"), W("postfuse_module/model.fp16.safetensors")); names = (["object"], ["fused", "embeds"])
else: m = port.UNet().load_weights(W("unet/diffusion_pytorch_model.fp16.safetensors")); names = (["sample", "timestep", "states", "pooled", "time_ids"], ["noise", "attention"])
m = m.eval().to(DT[args.dtype])
if args.norm: port.set_norm_dtype(m, DT[args.norm])
print("parameters", round(sum(p.numel() for p in m.parameters()) / 1e6, 1), "M", flush=True)
stage("load", t0)

def example(height, width):
    """Zeros of the graph's input shapes for a picture of height x width pixels."""
    h, w = height // 8, width // 8; z = lambda *s: torch.zeros(*s, dtype=torch.float32)
    return {"vae_decoder": {"latents": z(1, 4, h, w)}, "vae_encoder": {"picture": z(1, 3, height, width)}, "object_encoder": {"object": z(1, 3, 224, 224)},
            "unet": {"sample": z(1, 9, h, w), "timestep": z(1), "states": z(1, 77, 2048), "pooled": z(1, 1280), "time_ids": z(1, 6)}}[args.graph]

def symbolic():
    """Height and width as export dimensions. Each is written as a multiple of what the graph divides by, since export cannot prove the divisions otherwise."""
    from torch.export import Dim
    lo, hi = args.min_side, args.max_side
    if args.graph == "vae_decoder": return {"latents": {2: Dim("h", min=lo // 8, max=hi // 8), 3: Dim("w", min=lo // 8, max=hi // 8)}}
    if args.graph == "vae_encoder": return {"picture": {2: 8 * Dim("h8", min=lo // 8, max=hi // 8), 3: 8 * Dim("w8", min=lo // 8, max=hi // 8)}}
    if args.graph == "unet": return {"sample": {2: 2 * Dim("h2", min=lo // 16, max=hi // 16), 3: 2 * Dim("w2", min=lo // 16, max=hi // 16)}, "timestep": None, "states": None, "pooled": None, "time_ids": None}
    return None

if args.graph == "object_encoder": functions = [("main", (224, 224), None)]
elif args.dynamic: functions = [("main", (args.height, args.width), symbolic())]
elif args.sizes: functions = [(f"s{h}x{w}", (int(h), int(w)), None) for h, w in (s.split("x") for s in args.sizes.split(","))]
else: functions = [("main", (args.height, args.width), None)]

converter = TorchConverter(mode=TorchConverter.Mode.DEBUG if args.debug else TorchConverter.Mode.RELEASE)
for name, (height, width), shapes in functions:
    t0 = time.time()
    with torch.no_grad(): ep = torch.export.export(m, args=(), kwargs=example(height, width), dynamic_shapes=shapes)
    stage(f"export {name}", t0, f"{height} x {width}{' symbolic' if shapes else ''}")
    t0 = time.time(); ep = ep.run_decompositions(get_decomp_table()); stage(f"decompose {name}", t0)
    converter.add_exported_program(exported_program=ep, input_names=names[0], output_names=names[1], entrypoint_name=name)
    del ep
t0 = time.time(); program = converter.to_coreai(); stage("to_coreai", t0)
converter.clear(); del converter, m; gc.collect()      # the program has its own copy of the weights: let torch's go before the file is written
t0 = time.time()
out = Path(os.path.abspath(args.out))
if out.exists(): shutil.rmtree(out)
md = AIModelAssetMetadata(); md.author = "ObjectClear (S-Lab, NTU; github.com/zjx0101/ObjectClear at c052d91), on Stable Diffusion XL inpainting and CLIP ViT-L/14"
md.license = "NTU S-Lab License 1.0: non-commercial use only"
md.model_description = (f"ObjectClear {args.graph}, {args.dtype}" + (f", norms {args.norm}" if args.norm else "") + ", " +
                        ("224 x 224" if args.graph == "object_encoder" else f"symbolic size {args.min_side} to {args.max_side}" if args.dynamic else " ".join(f[0] for f in functions) if args.sizes else f"{args.height} x {args.width}"))
md.creation_date = 1
program.save_asset(out, md); stage("save", t0, str(out))
print("RESULT " + json.dumps({"graph": args.graph, "functions": [f[0] for f in functions], "dtype": args.dtype, "norm": args.norm, "dynamic": bool(args.dynamic),
                              "peak rss GiB": round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 2 ** 30, 2)}), flush=True)
