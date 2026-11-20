"""ObjectClear's pipeline around its four networks, in NumPy alone: what a Swift port (package H2) has to compute between the graphs, written
out once and checked against the recorded tensors. It is the executable form of goldens/README.md.

  objectclear_reference.py check RUN_FOLDER [RUN_FOLDER ...]     every relation between consecutive recorded files, with its worst error

Each function says which lines of the reference pipeline it stands for (ObjectClear at c052d91, diffusers 0.43). Where the pipeline computed in
half precision the function computes in float32 and `half` rounds the result, which is what `check` compares; a port in float32 that skips the
rounding differs from the recorded files by half-float rounding only. Needs numpy and Pillow (to read the PNGs), nothing else."""
import json, math, os, sys
import numpy as np

SCALING = 0.13025            # vae/config.json scaling_factor
FUSE_INDEX = 5               # the prompt's token "object": pipeline_objectclear.py line 1605 and 1809
HEADS = 10                   # attention heads of down_blocks.1 (unet/config.json attention_head_dim[1])
CLIP_MEAN = np.array([0.48145466, 0.4578275, 0.40821073], np.float32)
CLIP_STD = np.array([0.26862954, 0.26130258, 0.27577711], np.float32)


def half(x):
    """Round to half precision and widen again: where the pipeline held a float16."""
    return np.asarray(x, np.float32).astype(np.float16).astype(np.float32)


# ---- pixels to tensors (VaeImageProcessor.preprocess, pipeline lines 1582 to 1602) --------------------------------------------------------
def picture_tensor(rgb):
    """H x W x 3 uint8 to 1 x 3 x H x W float32 in [-1, 1]."""
    return (rgb.astype(np.float32) / np.float32(255) * np.float32(2) - np.float32(1)).transpose(2, 0, 1)[None]

def mask_tensor(gray):
    """H x W uint8 to 1 x 1 x H x W float32, 1 where the value / 255 is 0.5 or more (128 and up)."""
    return (gray.astype(np.float32) / np.float32(255) >= 0.5).astype(np.float32)[None, None]

def object_alone(picture, mask):
    """The image encoder's input: the picture where the mask is set, zero elsewhere (zero is mid grey in [-1, 1])."""
    return picture * (mask > 0.5)

def mask_latents(mask):
    """F.interpolate's default, nearest: the mask's every eighth pixel, from (0, 0)."""
    return mask[:, :, ::8, ::8]


# ---- the image encoder's resize: F.interpolate(mode="bilinear", antialias=True) to 224 x 224 (clip_image_encoder.py) -------------------------
def _antialias_weights(size_in, size_out):
    scale = size_in / size_out; support = max(scale, 1.0); rows = []
    for i in range(size_out):
        center = scale * (i + 0.5)
        lo = max(int(center - support + 0.5), 0); hi = min(int(center + support + 0.5), size_in)
        w = np.array([max(0.0, 1.0 - abs((j + lo - center + 0.5) / support)) for j in range(hi - lo)], np.float64)
        rows.append((lo, w / w.sum()))
    return rows

def resize_antialias(x, height=224, width=224):
    """1 x C x H x W to 1 x C x height x width with a triangle filter as wide as the scale, each axis in turn."""
    x = x.astype(np.float64)
    cols = _antialias_weights(x.shape[3], width); rows = _antialias_weights(x.shape[2], height)
    y = np.stack([(x[..., lo:lo + len(w)] * w).sum(-1) for lo, w in cols], -1)
    z = np.stack([(y[:, :, lo:lo + len(w), :] * w[:, None]).sum(2) for lo, w in rows], 2)
    return z.astype(np.float32)

def clip_normalize(x):
    return (x - CLIP_MEAN[None, :, None, None]) / CLIP_STD[None, :, None, None]

def fuse_prompt(text_states, fused_row):
    """PostfuseModule.forward: the fusion network's 1 x 2048 output replaces row FUSE_INDEX of the fixed 1 x 77 x 2048 text states."""
    out = text_states.copy(); out[:, FUSE_INDEX, :] = fused_row.reshape(1, -1); return out


# ---- the scheduler: EulerDiscreteScheduler, scaled_linear betas 0.00085 to 0.012 over 1000, 'leading' spacing, offset 1 -----------------------
def schedule(steps):
    """timesteps (steps values), sigmas (steps + 1, the last 0) and the factor the first noise is multiplied by."""
    # torch.linspace in float32: from the start up to the middle, from the end down after it
    lo, hi = np.float32(0.00085 ** 0.5), np.float32(0.012 ** 0.5); step = np.float32((hi - lo) / np.float32(999)); n = np.arange(1000, dtype=np.float32)
    betas = np.where(np.arange(1000) < 500, lo + step * n, hi - step * (np.float32(999) - n)).astype(np.float32) ** 2
    alphas = np.cumprod(np.float32(1) - betas, dtype=np.float32)
    all_sigmas = (((np.float32(1) - alphas) / alphas) ** np.float32(0.5)).astype(np.float32)
    timesteps = (np.arange(steps) * (1000 // steps)).round()[::-1].astype(np.float32) + 1
    sigmas = np.append(np.interp(timesteps, np.arange(1000), all_sigmas), 0.0).astype(np.float32)
    return timesteps, sigmas, float((sigmas[0] ** 2 + 1) ** 0.5)

def sample_latents(moments, noise):
    """DiagonalGaussianDistribution.sample times the scaling factor: moments is 1 x 8 x h x w, mean then log variance (clamped to -30 .. 20)."""
    mean, logvar = moments[:, :4], np.clip(moments[:, 4:], -30.0, 20.0)
    return half(half(mean + half(np.exp(0.5 * logvar)) * noise) * np.float32(SCALING))

def unet_sample(latents, sigma, mask_lat, masked_picture_lat):
    """The UNet's 9 channels: the latents scaled for this sigma, the mask, the masked picture's latents."""
    return np.concatenate([half(latents / np.float32((np.float32(sigma) ** 2 + 1) ** 0.5)), mask_lat, masked_picture_lat], 1)

def guide(unet_out, guidance):
    """unet_out is B x 4 x h x w: the unconditional row first when B is 2."""
    if unet_out.shape[0] == 1: return unet_out
    return half(unet_out[:1] + half(np.float32(guidance) * half(unet_out[1:] - unet_out[:1])))

def euler_step(latents, noise_pred, sigma, sigma_next):
    """x + eps * (sigma_next - sigma), as the scheduler does it: sigma * eps in half, the rest in float32, the result in half."""
    x = latents.astype(np.float32); denoised = x - half(np.float32(sigma) * noise_pred)
    return half(x + (x - denoised) / np.float32(sigma) * np.float32(sigma_next - sigma))

def after_first_step(scheduler_out, picture_lat, noise, sigma_1, mask_lat):
    """Lines 1813 to 1822, step 0 only: outside the mask the latents are the picture's again, at the noise level the next step expects."""
    noised = half(picture_lat + half(noise * half(sigma_1)))
    return half(half((1 - mask_lat) * noised) + half(mask_lat * scheduler_out)), noised


# ---- the attention map (resize_attn_map_divide2 and lines 1933 to 1937) -----------------------------------------------------------------------
def _upsample_bilinear_2x(x):
    """F.interpolate(scale 2, bilinear, align_corners=False) on ... x h x w."""
    def axis(n):
        src = np.maximum((np.arange(2 * n) + 0.5) / 2 - 0.5, 0); i0 = np.floor(src).astype(int); return i0, np.minimum(i0 + 1, n - 1), (src - i0).astype(np.float32)
    r0, r1, rt = axis(x.shape[-2]); c0, c1, ct = axis(x.shape[-1])
    top = x[..., r0, :] * (1 - rt)[:, None] + x[..., r1, :] * rt[:, None]
    return top[..., c0] * (1 - ct) + top[..., c1] * ct

def attention_map(raw, latent_height, latent_width, branches=1):
    """raw is (branches * HEADS) x (latent_height / 2 * latent_width / 2) x 77, softmax over the 77. Returns the conditional branch's map,
    1 x 1 x latent_height x latent_width in [0, 1]: the token's column, the mean over the heads, twice the size, stretched to its range."""
    column = raw[:, :, FUSE_INDEX].reshape(branches, HEADS, latent_height // 2, latent_width // 2)
    mean = half(column.astype(np.float32).mean(1, keepdims=True))
    up = half(_upsample_bilinear_2x(mean))[-1:]
    lo, hi = up.min(), up.max()
    return half((up - lo) / (hi - lo))     # the pipeline adds 1e-8 to the range, which is 0 in half precision

def attention_bytes(attention):
    """The map the pipeline returns, latent size: times 255 in half precision (so 0.502 can reach 128), then truncated."""
    return half(attention[0, 0] * np.float32(255.0)).astype(np.uint8)

def _bicubic(x):
    x = abs(x); a = -0.5
    return ((a + 2) * x - (a + 3)) * x * x + 1 if x < 1 else ((((x - 5) * x + 8) * x - 4) * a if x < 2 else 0.0)

def _pillow_coefficients(size_in, size_out):
    scale = size_in / size_out; filterscale = max(scale, 1.0); support = 2.0 * filterscale; rows = []
    for i in range(size_out):
        center = (i + 0.5) * scale
        lo = max(int(center - support + 0.5), 0); hi = min(int(center + support + 0.5), size_in)
        w = np.array([_bicubic((j + lo - center + 0.5) / filterscale) for j in range(hi - lo)], np.float64); w /= w.sum()
        rows.append((lo, np.array([int(-0.5 + k * (1 << 22)) if k < 0 else int(0.5 + k * (1 << 22)) for k in w], np.int64)))
    return rows

def resize_bicubic_u8(gray, height, width):
    """Pillow's Image.resize((width, height)) of an 8-bit grey image, its default bicubic: fixed point with 22 bits, columns then rows,
    each pass rounded to 8 bits. This is how run_oc.py brings the latent-size attention map to the working size."""
    def run(a, rows, axis):
        a = np.moveaxis(a.astype(np.int64), axis, -1)
        out = np.stack([np.clip(((a[..., lo:lo + len(k)] * k).sum(-1) + (1 << 21)) >> 22, 0, 255) for lo, k in rows], -1)
        return np.moveaxis(out, -1, axis)
    return run(run(gray, _pillow_coefficients(gray.shape[1], width), 1), _pillow_coefficients(gray.shape[0], height), 0).astype(np.uint8)


# ---- the decoder's picture (VaeImageProcessor.postprocess) --------------------------------------------------------------------------------------
def picture_bytes(decoded):
    """1 x 3 x H x W about [-1, 1] to H x W x 3 uint8: x / 2 + 0.5 clamped to [0, 1] in half precision, times 255, rounded half to even."""
    return np.rint(np.clip(half(half(decoded / 2) + 0.5), 0, 1)[0].transpose(1, 2, 0) * np.float32(255)).astype(np.uint8)


# ---- attention-guided fusion (objectclear/utils/attention_guided_fusion.py), without OpenCV or SciPy ---------------------------------------------
def _blur3(x):
    """scipy.ndimage.convolve with [[1, 2, 1], [2, 4, 2], [1, 2, 1]] / 16, mode='nearest', on C x H x W."""
    p = np.pad(x, ((0, 0), (1, 1), (1, 1)), mode="edge"); k = np.array([0.0625, 0.125, 0.0625, 0.125, 0.25, 0.125, 0.0625, 0.125, 0.0625], np.float32)
    h, w = x.shape[1:]; out = np.zeros(x.shape, np.float64); n = 0
    for dy in range(3):
        for dx in range(3):
            out += p[:, dy:dy + h, dx:dx + w].astype(np.float64) * float(k[n]); n += 1
    return out.astype(np.float32)

def _zoom_linear(x, height, width):
    """scipy.ndimage.zoom(order=1) on C x H x W: linear between samples, the corners of input and output aligned."""
    def axis(n_in, n_out):
        src = np.arange(n_out, dtype=np.float64) * ((n_in - 1) / (n_out - 1)) if n_out > 1 else np.zeros(1)
        i0 = np.minimum(np.floor(src).astype(int), n_in - 1); return i0, np.minimum(i0 + 1, n_in - 1), src - i0
    r0, r1, rt = axis(x.shape[1], height); c0, c1, ct = axis(x.shape[2], width); x = x.astype(np.float64)
    rows = x[:, r0, :] * (1 - rt)[None, :, None] + x[:, r1, :] * rt[None, :, None]
    return (rows[:, :, c0] * (1 - ct) + rows[:, :, c1] * ct).astype(np.float32)

def _wavelet_blur(x, radius):
    y = _blur3(x)
    if radius > 1:
        h, w = x.shape[1:]; y = _zoom_linear(_zoom_linear(y, int(round(h / radius)), int(round(w / radius))), h, w)
    return y

def _wavelet_split(x):
    high = np.zeros_like(x)
    for level in range(5):
        low = _wavelet_blur(x, 2 ** level); high += x - low; x = low
    return high, x

def _dilate_ellipse21(x):
    """cv2.dilate with getStructuringElement(MORPH_ELLIPSE, (21, 21)): the greatest value under an ellipse of radius 10, the picture's outside ignored."""
    h, w = x.shape; p = np.pad(x, 10, mode="constant", constant_values=-np.inf); out = np.full(x.shape, -np.inf, np.float32)
    for dy in range(-10, 11):
        dx = int(round(10 * math.sqrt((100 - dy * dy) / 100.0)))
        for j in range(-dx, dx + 1):
            np.maximum(out, p[10 + dy:10 + dy + h, 10 + j:10 + j + w], out=out)
    return out

def _gaussian9(x):
    """cv2.GaussianBlur(x, (9, 9), sigmaX=2): 9 taps of exp(-d^2 / 8) normalised, each axis, the border mirrored without repeating the edge."""
    k = np.exp(-(np.arange(9) - 4.0) ** 2 / 8.0); k = (k / k.sum()).astype(np.float32).astype(np.float64)
    p = np.pad(x.astype(np.float64), 4, mode="reflect"); h, w = x.shape
    rows = sum(p[:, i:i + w] * k[i] for i in range(9)); return sum(rows[i:i + h] * k[i] for i in range(9)).astype(np.float32)

def attention_guided_fusion(original, removed, attention_latent):
    """original and removed are H x W x 3 uint8 (the input and the decoder's picture), attention_latent H/8 x W/8 uint8. Returns the fused
    picture: inside the attention map the decoder's picture; outside it the input's detail over the decoder's colour (five wavelet levels)."""
    h, w = original.shape[:2]
    inside = np.repeat(np.repeat((attention_latent > 128).astype(np.float32), 8, 0), 8, 1)[:h, :w]      # cv2.threshold is strict; nearest by 8
    merged = np.clip(np.maximum(inside, _gaussian9(_dilate_ellipse21(inside))), 0, 1)[..., None]
    keep = (1 - inside)[..., None]
    content = (original * keep).astype(np.float32) / np.float32(255); style = (removed * keep).astype(np.float32) / np.float32(255)
    high, _ = _wavelet_split(content.transpose(2, 0, 1)); _, low = _wavelet_split(style.transpose(2, 0, 1))
    wave = np.clip((high + low).transpose(1, 2, 0) * np.float32(255), 0, 255).astype(np.uint8)
    return (wave * (1 - merged) + removed * merged).astype(np.uint8)


# ---- the whole loop, given the four networks as functions: how a port runs a job -----------------------------------------------------------------
def run(rgb, gray, steps, guidance, noises, text_states, pooled, encode_object, encode_picture, unet, decode):
    """rgb H x W x 3 and gray H x W uint8 at the working size. noises: the three 1 x 4 x H/8 x W/8 normal draws, in the generator's order
    (the picture's sample, the start, the masked picture's sample). encode_object(1 x 3 x 224 x 224 normalised) -> the fused row, 1 x 2048.
    encode_picture(1 x 3 x H x W) -> 1 x 8 x h x w moments. unet(sample, timestep, states, pooled, time_ids) -> (noise 1 x 4 x h x w,
    attention raw HEADS x tokens x 77). decode(1 x 4 x h x w) -> 1 x 3 x H x W. Returns the fused picture, the latent-size attention bytes,
    and the decoder's picture before the fusion."""
    h, w = gray.shape; picture = picture_tensor(rgb); mask = mask_tensor(gray)
    row = encode_object(clip_normalize(resize_antialias(object_alone(picture, mask))))
    states = fuse_prompt(text_states, row)
    moments = encode_picture(picture)
    picture_lat = sample_latents(moments, noises[0]); masked_lat = sample_latents(moments, noises[2]); mask_lat = mask_latents(mask)
    timesteps, sigmas, first = schedule(steps); latents = half(noises[1] * np.float32(first))
    time_ids = np.array([[h, w, 0, 0, h, w]], np.float32); raw = None
    for i in range(steps):
        sample = unet_sample(latents, sigmas[i], mask_lat, masked_lat)
        eps, raw = unet(sample, timesteps[i], states, pooled, time_ids)
        if guidance > 1:
            eps_un, _ = unet(sample, timesteps[i], np.zeros_like(states), np.zeros_like(pooled), time_ids)
            eps = guide(np.concatenate([eps_un, eps]), guidance)
        latents = euler_step(latents, eps, sigmas[i], sigmas[i + 1])
        if i == 0: latents, _ = after_first_step(latents, picture_lat, noises[1], sigmas[1], mask_lat)
    attention = attention_bytes(attention_map(raw, h // 8, w // 8))
    generated = picture_bytes(decode(half(latents / np.float32(SCALING))))
    return attention_guided_fusion(rgb, generated, attention), attention, generated


# ---- check: every relation between consecutive recorded files ------------------------------------------------------------------------------------
def check(folder):
    from PIL import Image
    m = json.load(open(os.path.join(folder, "manifest.json"))); steps, guidance = m["steps"], m["guidance"]; B = m["unet batch"]
    L = lambda name: np.load(os.path.join(folder, name + ".npy"))
    P = lambda name: np.asarray(Image.open(os.path.join(folder, name + ".png")))
    rows = []
    def same(what, got, want, note=""):
        got = np.asarray(got); want = np.asarray(want); assert got.shape == want.shape, (what, got.shape, want.shape)
        d = np.abs(got.astype(np.float64) - want.astype(np.float64)); scale = max(float(np.abs(want).max()), 1e-12)
        rows.append((what, float(d.max()), float(d.max()) / scale, float((d == 0).mean()), note))
    rgb, gray = P("input"), P("mask"); picture, mask = L("picture"), L("mask"); h, w = gray.shape
    same("picture from input.png", picture_tensor(rgb), picture); same("mask from mask.png", mask_tensor(gray), mask)
    same("image_encoder_input = picture * (mask > 0.5)", object_alone(picture, mask), L("image_encoder_input"))
    same("image_encoder_resized (antialiased bilinear to 224)", resize_antialias(L("image_encoder_input")), L("image_encoder_resized"))
    same("image_encoder_normalized (CLIP mean and std)", clip_normalize(L("image_encoder_resized")), L("image_encoder_normalized"))
    fused = L("fused_prompt_states"); same("fused_prompt_states but row 5 = text_states", np.delete(fused, FUSE_INDEX, 1), np.delete(L("text_states"), FUSE_INDEX, 1))
    same("vae_encoder_input = picture (half)", half(picture), L("vae_encoder_input"))
    same("the two encodes' moments", L("vae_encoder_moments_masked"), L("vae_encoder_moments_picture"))
    same("picture_latents from moments and noise", sample_latents(L("vae_encoder_moments_picture"), L("vae_sample_noise_picture")), L("picture_latents"))
    same("masked_picture_latents from moments and noise", sample_latents(L("vae_encoder_moments_masked"), L("vae_sample_noise_masked")), L("masked_picture_latents"))
    same("mask_latents = mask[::8, ::8]", mask_latents(mask), L("mask_latents"))
    timesteps, sigmas, first = schedule(steps)
    same("timesteps", timesteps, L("timesteps")); same("sigmas", sigmas, L("sigmas")); same("init_noise_sigma", first, L("init_noise_sigma"))
    # schedule() lands within a float32 step or two of torch's table (about 4e-7 of the value); the relations below are checked with the
    # recorded table, so that what they show is their own rounding and not the table's
    sigmas = L("sigmas"); first = float(L("init_noise_sigma"))
    same("initial_latents = initial_noise * init_noise_sigma", half(L("initial_noise") * np.float32(first)), L("initial_latents"))
    same("time_ids = (H, W, 0, 0, H, W)", np.array([[h, w, 0, 0, h, w]], np.float32), L("time_ids"))
    states = L("unet_encoder_hidden_states"); same("unet_encoder_hidden_states, conditional row = fused_prompt_states", states[-1:], fused)
    same("unet_text_embeds, conditional row = pooled_text_states", L("unet_text_embeds")[-1:], L("pooled_text_states"))
    if B == 2:
        same("unconditional rows are zero", np.concatenate([states[:1].ravel(), L("unet_text_embeds")[:1].ravel()]), np.zeros(77 * 2048 + 1280, np.float32))
    latents = L("initial_latents"); worst = {}
    def worse(what, got, want):
        d = float(np.abs(np.asarray(got, np.float64) - np.asarray(want, np.float64)).max()); worst[what] = max(worst.get(what, 0.0), d)
    for i in range(steps):
        S = lambda name: L(f"step_{i:02d}/{name}")
        worse("step: latents_in = the step before's latents_out", S("latents_in"), latents)
        worse("step: sigma, timestep", np.array([S("sigma"), S("unet_timestep")]), np.array([sigmas[i], timesteps[i]]))
        sample = unet_sample(S("latents_in"), sigmas[i], L("mask_latents"), L("masked_picture_latents"))
        worse("step: unet_sample from latents_in, mask_latents, masked_picture_latents", np.repeat(sample, B, 0), S("unet_sample"))
        worse("step: noise_pred from unet_out (guidance)", guide(S("unet_out"), guidance), S("noise_pred"))
        out = euler_step(S("latents_in"), S("noise_pred"), sigmas[i], sigmas[i + 1])
        worse("step: scheduler_out = Euler step", out, S("scheduler_out"))
        if i == 0:
            blended, noised = after_first_step(S("scheduler_out"), L("picture_latents"), L("initial_noise"), sigmas[1], L("mask_latents"))
            same("picture_latents_noised = picture_latents + initial_noise * sigmas[1]", noised, L("picture_latents_noised"))
            same("step 0: latents_out = picture outside the mask, scheduler_out inside", blended, S("latents_out"))
        else:
            worse("step > 0: latents_out = scheduler_out", S("latents_out"), S("scheduler_out"))
        latents = S("latents_out")
    for what, d in worst.items(): rows.append((what + f" (worst of {steps})", d, float("nan"), float("nan"), ""))
    same("final_latents = the last latents_out", L("final_latents"), latents)
    raw = L("attention_raw"); same("attention_raw sums to 1 over the text tokens", raw[-HEADS:].sum(-1), np.ones(raw[-HEADS:].shape[:2], np.float32), "half-precision softmax")
    amap = attention_map(raw, h // 8, w // 8, B); same("attention_map from attention_raw", amap, L("attention_map"))
    same("attention_latent.png = attention_map * 255 truncated", attention_bytes(L("attention_map")), P("attention_latent"))
    same("attention.png = Pillow bicubic of attention_latent.png", resize_bicubic_u8(P("attention_latent"), h, w), P("attention"))
    same("vae_decoder_input = final_latents / 0.13025", half(L("final_latents") / np.float32(SCALING)), L("vae_decoder_input"))
    same("generated.png from vae_decoder_output", picture_bytes(L("vae_decoder_output")), P("generated"))
    same("fused.png = attention_guided_fusion(input, generated, attention_latent)", attention_guided_fusion(rgb, P("generated"), P("attention_latent")), P("fused"),
         "OpenCV blurs in float32: a few values in a million fall the other side of a whole number")
    print(f"{os.path.basename(folder.rstrip('/'))}: {w} x {h}, {steps} steps, guidance {guidance}")
    for what, d, rel, exact, note in rows:
        print(f"  {d:11.3e}  {'' if math.isnan(rel) else f'rel {rel:8.1e}  exact {exact * 100:8.4f} %'}  {what}{'  [' + note + ']' if note else ''}")
    return rows


if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] != "check": sys.exit(__doc__)
    for folder in sys.argv[2:]: check(folder)
