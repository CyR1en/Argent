"""Read uncompressed probe TIFFs. All measurements are B relative to A; JSON stdout.

displacement A B [--patch 256 --step 256 --rings 10]: per-channel feature
motion, pixels right/down positive, radius / half diagonal, plus ring medians.
gain A B: linear luminance ratio in stops, with pixel counts per ring.
defringe A B --layout fringe-layout.json: relative RGB chroma removed from
each region with its linear-RGB hue angle and fringe width from the layout;
fringe excess above its neutral reference, and protected-patch RGB/chroma change.
xmp EXPORT: every crs: and aux: field, including structured values.
--self-test: independent synthetic TIFFs; no Lightroom or repository data.
lanes ROOT OUTPUT --lane N: analyze one completed LC3 round-two lane and save
its PNG, JSON evidence and lane-N.md outside Git. Needs matplotlib and, for lane 3,
rawpy. Does not start Lightroom or write jobs. ROOT contains lc3r2-plan.json.
summary ROOT OUTPUT: print one row per export using the lane measurements.
"""
import argparse
import hashlib
import json
import sys
import tempfile
from fractions import Fraction
import xml.etree.ElementTree as ET
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_lens_charts as charts  # noqa: E402
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lightroom-probe"))
import make_charts  # noqa: E402
import presence_stats  # noqa: E402
import probe  # noqa: E402
import synth_masks  # noqa: E402


def linear(path):
    image, icc = probe.read_tiff(path)
    gamma = probe.icc_gamma(icc) if icc else None
    if gamma is None:
        raise ValueError(f"{path}: expected the probe's pure-gamma ICC export")
    return np.power(image, np.float32(gamma))


def xmp(path):
    text = presence_stats.xmp(path)
    if not text:
        raise ValueError(f"{path}: no XMP packet")
    namespaces = {"http://ns.adobe.com/camera-raw-settings/1.0/": "crs",
                  "http://ns.adobe.com/exif/1.0/aux/": "aux"}
    result = {}

    def add(key, value):
        if key.startswith("{"):
            namespace, name = key[1:].split("}", 1)
            if namespace in namespaces:
                result.setdefault(f"{namespaces[namespace]}:{name}", []).append(value)

    for node in ET.fromstring(text):
        for element in node.iter():
            add(element.tag, ET.tostring(element, encoding="unicode") if len(element) else element.text or "")
            for key, value in element.attrib.items():
                add(key, value)
    return result


def radius(shape):
    h, w = shape[:2]
    x = (np.arange(w, dtype=np.float32) - (w - 1) / 2) / (np.hypot(w, h) / 2)
    y = (np.arange(h, dtype=np.float32) - (h - 1) / 2) / (np.hypot(w, h) / 2)
    return np.hypot(y[:, None], x[None, :])


def phase_shift(a, b):
    """Signal-weighted phase correlation, local inverse DFT sampled at 0.01 px.

    Reject flat and one-dimensional patches (the aperture problem). Tapering
    suppresses patch boundaries; weak Fourier bins are excluded from the phase.
    """
    for patch in (a, b):
        gy, gx = np.gradient(patch.astype(float))
        covariance = np.array([[np.mean(gx * gx), np.mean(gx * gy)], [np.mean(gx * gy), np.mean(gy * gy)]])
        eigenvalues = np.linalg.eigvalsh(covariance)
        if eigenvalues[0] < max(1e-10, eigenvalues[1] * 0.001):
            return None
    window = np.outer(np.hanning(a.shape[0]), np.hanning(a.shape[1]))
    fa, fb = [np.fft.fft2((p - p.mean()) * window) for p in (a, b)]
    cross = fb * fa.conj()
    magnitude = np.abs(cross)
    cross = np.where(magnitude > magnitude.max() * 0.001, cross / np.sqrt(np.maximum(magnitude, 1e-30)), 0)
    peak = np.array(np.unravel_index(np.fft.ifft2(cross).real.argmax(), a.shape), dtype=float)
    peak = np.where(peak > np.array(a.shape) / 2, peak - a.shape, peak)
    fy, fx = np.fft.fftfreq(a.shape[0]), np.fft.fftfreq(a.shape[1])
    for spacing in (0.1, 0.01):
        ys, xs = [v + np.arange(-10, 11) * spacing for v in peak]
        correlation = (np.exp(2j * np.pi * ys[:, None] * fy) @ cross @
                       np.exp(2j * np.pi * fx[:, None] * xs)).real
        iy, ix = np.unravel_index(correlation.argmax(), correlation.shape)
        peak = np.array([ys[iy], xs[ix]])
    if np.any(np.abs(peak) >= np.array(a.shape) / 4):
        return None
    return peak[::-1]  # dx, dy of B's features relative to A


def displacement(a, b, patch=256, step=256, rings=10):
    if a.shape != b.shape:
        raise ValueError("export dimensions differ; use uncropped full-size exports")
    h, w = a.shape[:2]
    if patch > min(h, w):
        raise ValueError("patch is larger than the export")
    rows, rejected = [], 0
    for y in range(0, h - patch + 1, step):
        for x in range(0, w - patch + 1, step):
            px, py = x + (patch - 1) / 2, y + (patch - 1) / 2
            ux, uy = px - (w - 1) / 2, py - (h - 1) / 2
            r = np.hypot(ux, uy)
            for channel, label in enumerate("RGB"):
                shift = phase_shift(a[y:y + patch, x:x + patch, channel], b[y:y + patch, x:x + patch, channel])
                if shift is None:
                    rejected += 1
                    continue
                dx, dy = map(float, shift)
                rows.append(dict(channel=label, x=px, y=py, radius=float(r / (np.hypot(w, h) / 2)), dx=dx, dy=dy,
                                 radial=float((dx * ux + dy * uy) / r) if r else 0,
                                 tangential=float((-dx * uy + dy * ux) / r) if r else 0))
    summary = []
    for channel in "RGB":
        for index in range(rings):
            group = [row for row in rows if row["channel"] == channel and index <= row["radius"] * rings < index + 1]
            summary.append(dict(channel=channel, ring=[index / rings, (index + 1) / rings], patches=len(group),
                                **{key: float(np.median([row[key] for row in group])) if group else None
                                   for key in ("dx", "dy", "radial", "tangential")}))
    return dict(patches=rows, rings=summary, rejected_channel_patches=rejected, max_shift_px=patch / 4,
                fit=fit_displacement(rows, a.shape))


def residual(values):
    values = np.asarray(values, float)
    return dict(rms=float(np.sqrt(np.mean(values ** 2))), p95=float(np.percentile(np.abs(values), 95)))


def fit_displacement(rows, shape):
    """Feature motion = translation + v * sum(c[j] t**(2*j)), independently per channel.

    The constant radial term includes framing magnification. Residuals are vector
    lengths, not the smaller rms of their individual coordinates. No outlier trim.
    """
    h, w = shape[:2]
    result = {}
    for channel in "RGB":
        group = [r for r in rows if r["channel"] == channel]
        if len(group) < 4:
            result[channel] = dict(patches=len(group), error="fewer than four patches")
            continue
        v = np.array([[r["x"] - (w - 1) / 2, r["y"] - (h - 1) / 2] for r in group])
        t = np.linalg.norm(v, axis=1) / (np.hypot(w, h) / 2)
        basis = v[:, :, None] * t[:, None, None] ** np.arange(0, 8, 2)
        design = np.concatenate([basis, np.broadcast_to(np.eye(2), (len(v), 2, 2))], axis=2).reshape(-1, 6)
        observed = np.array([[r["dx"], r["dy"]] for r in group])
        coefficients = np.linalg.lstsq(design, observed.ravel(), rcond=None)[0]
        error = observed - (design @ coefficients).reshape(-1, 2)
        result[channel] = dict(patches=len(group), radial_coefficients=coefficients[:4].tolist(),
                               translation_px=coefficients[4:].tolist(), **residual(np.linalg.norm(error, axis=1)))
    return result


def fit_gain(rows):
    group = [r for r in rows if r["stops"] is not None]
    if len(group) < 4:
        return dict(error="fewer than four populated rings")
    t = np.array([r["radius"] for r in group])
    design = t[:, None] ** np.arange(0, 8, 2)
    values = np.array([r["stops"] for r in group])
    coefficients = np.linalg.lstsq(design, values, rcond=None)[0]
    return dict(coefficients_stops=coefficients.tolist(), **residual(values - design @ coefficients))


def amount_law(amounts, fields, tolerance):
    """Test a linear law in displacement or stops, relative to the accepted zero.

    A collapsed or incomplete sweep cannot identify a law, even with zero residual.
    """
    amounts, fields = np.asarray(amounts, float), np.asarray(fields, float)
    if sorted(amounts.tolist()) != [0, 50, 100, 150, 200]:
        return dict(law=None, error="accepted amounts do not cover 0, 50, 100, 150, 200", rms=None)
    zero, hundred = fields[amounts == 0][0], fields[amounts == 100][0]
    delta = hundred - zero
    if np.max(np.abs(delta)) < tolerance:
        return dict(law=None, error="response is below the identification tolerance", rms=None)
    error = fields - zero - (amounts / 100).reshape((-1,) + (1,) * delta.ndim) * delta
    score = residual(np.linalg.norm(error, axis=-1) if error.ndim == 3 else error)
    return dict(law="linear relative to zero" if score["rms"] <= tolerance else None, **score)


def invert_radial(p, factor, rmax):
    q = p.copy()
    for _ in range(64):
        q = p / factor(np.linalg.norm(q, axis=1) / rmax)[:, None]
    return q


def border_scale(factor, shape):
    h, w = shape[:2]
    border = np.linspace((min(w, h) - 1) / np.hypot(w, h), 1, 4001)
    x = np.linspace(0, 1.6, 160001)
    mapped = x * factor(x)
    if not np.all(np.diff(mapped) > 0):
        raise ValueError("non-monotone inferred source map")
    return float(np.max(border / np.interp(border, mapped, x)))


def distortion_laws(p, q, shape, knots=None, intact=None):
    """Anchor at 100; predict with border framing or linear displacement.

    Coordinates are centred. Only an output translation is fitted per amount.
    The returned coefficients belong in private evidence, never in Git.
    """
    h, w = shape[:2]
    rmax = np.hypot(w, h) / 2
    t = np.linalg.norm(q[2], axis=1) / rmax
    design = q[2, :, :, None] * t[:, None, None] ** np.arange(0, 8, 2)
    co = np.linalg.lstsq(design.reshape(-1, 4), p.ravel(), rcond=None)[0]

    framed_design = q[2, :, :, None] * t[:, None, None] ** np.arange(0, 10, 2)
    framed = np.linalg.lstsq(framed_design.reshape(-1, 5), p.ravel(), rcond=None)[0]

    def profile(t):
        return np.polynomial.polynomial.polyval(t * t, co / co[0])

    border = np.linspace((min(w, h) - 1) / np.hypot(w, h), 1, 4001)
    if knots is None:
        unframed = lambda t: profile(t / co[0])
    else:
        unframed = lambda t: 1 + curve(knots, t) / 16384
        anchor_scale = border_scale(unframed, shape)
        profile = lambda t: unframed(t / anchor_scale)
    results = {}
    for law in ("scaled-radius", "same-radius", "linear-displacement"):
        rows, errors = [], []
        for i, amount in enumerate((0, 50, 100, 150, 200)):
            alpha = amount / 100
            if law == "scaled-radius":
                g = lambda x: 1 + alpha * (unframed(x) - 1)
                scale = border_scale(g, shape)
                factor = lambda t: g(t / scale) / scale
            elif law == "linear-displacement":
                scale = 1.0
                factor = lambda t: 1 + alpha * (np.polynomial.polynomial.polyval(t * t, framed) - 1)
            else:
                scale = float(np.max(1 + alpha * (profile(border) - 1)))
                factor = lambda t: (1 + alpha * (profile(t) - 1)) / scale
            predicted = invert_radial(p, factor, rmax)
            translation = np.mean(q[i] - predicted, axis=0)
            error = np.linalg.norm(predicted + translation - q[i], axis=1)
            errors.append(error)
            rows.append(dict(amount=amount, scale=scale, translation_px=translation.tolist(), **residual(error)))
        results[law] = dict(pooled=residual(np.concatenate(errors)),
                            non_anchor=residual(np.concatenate([errors[i] for i in (1, 3, 4)])), by_amount=rows)
        if intact is not None:
            results[law]["complete_disks"] = dict(points=int(intact.sum()),
                pooled=residual(np.concatenate([e[intact] for e in errors])),
                non_anchor=residual(np.concatenate([errors[i][intact] for i in (1, 3, 4)])),
                by_amount=[dict(amount=a, **residual(e[intact])) for a, e in zip((0, 50, 100, 150, 200), errors)])
    floor = []
    for amount, points in zip((0, 50, 100, 150, 200), q):
        t = np.linalg.norm(points, axis=1) / rmax
        design = points[:, :, None] * t[:, None, None] ** np.arange(0, 10, 2)
        fitted = np.linalg.lstsq(design.reshape(-1, 5), p.ravel(), rcond=None)[0]
        predicted = invert_radial(p, lambda t: np.polynomial.polynomial.polyval(t * t, fitted), rmax)
        error = predicted + np.mean(points - predicted, axis=0) - points
        floor.append(dict(amount=amount, **residual(np.linalg.norm(error, axis=1))))
    return dict(points=len(p), anchor_coefficients=co.tolist(), framed_anchor_coefficients=framed.tolist(),
                free_radial_fit=floor, laws=results)


def sweep_points(paths, grid=False):
    """Register accepted green exports without saved fields or a motion cutoff."""
    from scipy import ndimage
    from scipy.optimize import least_squares
    from scipy.spatial import cKDTree

    a = linear(paths[0])[:, :, 1].copy()
    h, w = a.shape
    center, rmax = np.array([(w - 1) / 2, (h - 1) / 2]), np.hypot(w, h) / 2
    if grid:
        centroids = []
        for path in paths:
            image = a if path == paths[0] else linear(path)[:, :, 1]
            background = np.median(image)
            labels, _ = ndimage.label(image < background * 0.65)
            sizes = np.bincount(labels.ravel())
            ids = np.flatnonzero((sizes > 20) & (sizes < 400))
            ids = ids[ids != 0]
            centroids.append(np.array(ndimage.center_of_mass(np.maximum(background - image, 0), labels, ids))[:, ::-1])
        p = centroids[0]
        v = p - center
        t = np.linalg.norm(v, axis=1) / rmax
        design = np.concatenate([v[:, :, None] * t[:, None, None] ** np.arange(0, 10, 2),
                                 np.broadcast_to(np.eye(2), (len(v), 2, 2))], axis=2).reshape(-1, 7)
        matched, valid, checks = [p], np.ones(len(p), bool), []
        for dots in centroids[1:]:
            distance, index = cKDTree(dots).query(matched[-1])
            seed = valid & (distance < 35)
            # The unambiguous matches seed a radial prediction for EVERY dot,
            # including dots that moved farther than half the grid spacing.
            for _ in range(4):
                co = np.linalg.lstsq(design.reshape(-1, 2, 7)[seed].reshape(-1, 7),
                                     (dots[index] - center)[seed].ravel(), rcond=None)[0]
                prediction = (design @ co).reshape(-1, 2) + center
                distance, index = cKDTree(dots).query(prediction)
                seed = distance < 6
            valid &= seed
            matched.append(dots[index])
            checks.append(dict(matched=int(seed.sum()), unmatched=int((~seed).sum()),
                               maximum_prediction_error_px=float(distance[seed].max())))
        # Keep edge-cut centroids; their errors must remain in the score.
        points = np.array(matched)[:, valid] - center
        radii = t[valid]
        return points[0], points, dict(method="weighted dot centroids; radial prediction of all dots",
                    detected=[len(c) for c in centroids], matching=checks,
                    radius_050_065=int(((radii >= 0.50) & (radii < 0.65)).sum()),
                    common_points=int(valid.sum()), rejected_points=int((~valid).sum()))

    allrows, checks = [], []
    for path in paths:
        b = a if path == paths[0] else linear(path)[:, :, 1].copy()
        parameters = np.zeros(6)
        for scale in (4, 2, 1):
            aa = ndimage.gaussian_filter(a, scale / 2)[::scale, ::scale]
            bb = ndimage.gaussian_filter(b, scale / 2)[::scale, ::scale]
            gy, gx = np.gradient(aa)
            by, bx = np.gradient(bb)
            strength = np.hypot(bx, by)
            yy, xx = np.mgrid[24:aa.shape[0]-24:7, 24:aa.shape[1]-24:7]
            selected = ((strength[yy, xx] > np.percentile(strength, 65)) &
                        (bb[yy, xx] > 0.01) & (bb[yy, xx] < 0.95))
            y, x = yy[selected], xx[selected]
            v = np.stack([x * scale - center[0], y * scale - center[1]], axis=1)
            t = np.linalg.norm(v, axis=1) / rmax
            basis = v[:, :, None] * t[:, None, None] ** np.arange(0, 8, 2)
            design = np.concatenate([basis, np.broadcast_to(np.eye(2), (len(v), 2, 2))], axis=2) / scale
            observed, base = bb[y, x], np.stack([x, y], axis=1)

            def evaluate(par, jac=False):
                p = base + np.einsum("nij,j->ni", design, par)
                coords = [p[:, 1], p[:, 0]]
                samples = ndimage.map_coordinates(aa, coords, order=1, mode="nearest")
                phot = np.linalg.lstsq(np.stack([samples, np.ones(len(samples))], axis=1), observed, rcond=None)[0]
                if jac:
                    gradient = np.stack([ndimage.map_coordinates(gx, coords, order=1, mode="nearest"),
                                         ndimage.map_coordinates(gy, coords, order=1, mode="nearest")], axis=1)
                    return phot[0] * np.einsum("ni,nij->nj", gradient, design)
                return phot[0] * samples + phot[1] - observed

            fit = least_squares(evaluate, parameters, jac=lambda p: evaluate(p, True), x_scale="jac",
                                loss="soft_l1", f_scale=0.01, max_nfev=120,
                                ftol=1e-10, xtol=1e-10, gtol=1e-10)
            parameters = fit.x

        def mapping(q):
            v = q - center
            t = np.linalg.norm(v, axis=-1) / rmax
            return q + v * np.polynomial.polynomial.polyval(t * t, parameters[:4])[..., None] + parameters[4:]

        rows, corrections, rejected = {}, [], 0
        for y in range(128, h - 128, 512):
            for x in range(128, w - 128, 512):
                p = np.array([x + 127.5, y + 127.5])
                q = p.copy()
                for _ in range(24):
                    q += p - mapping(q)
                yy, xx = np.mgrid[-63.5:64.5, -63.5:64.5]
                coords = np.stack([xx + q[0], yy + q[1]], axis=-1)
                mapped = mapping(coords)
                warped = ndimage.map_coordinates(a, [mapped[:, :, 1], mapped[:, :, 0]], order=1, mode="nearest")
                target = ndimage.map_coordinates(b, [coords[:, :, 1], coords[:, :, 0]], order=1, mode="nearest")
                shift = phase_shift(warped, target)
                if shift is None or np.linalg.norm(shift) > 2:
                    rejected += 1
                    continue
                rows[tuple(p)] = q + shift
                corrections.append(float(np.linalg.norm(shift)))
        allrows.append(rows)
        check = dict(accepted=len(rows), rejected=rejected, local_correction=residual(corrections))
        check.update(source_map_parameters=parameters.tolist(), photometric_rms=float(np.sqrt(np.mean(evaluate(parameters)**2))))
        checks.append(check)
    common = sorted(set.intersection(*(set(rows) for rows in allrows)))
    return np.array(common) - center, np.array([[rows[p] for p in common] for rows in allrows]) - center, dict(
        method="radial green source map; independent local phase refinement", common_points=len(common), by_amount=checks)


def gain(a, b, rings=10):
    if a.shape != b.shape:
        raise ValueError("export dimensions differ")
    r = radius(a.shape)
    valid = (a > 2 / 65535) & (b > 2 / 65535) & (a < 0.999) & (b < 0.999)
    stops = np.log2(np.maximum(b, 1e-20) / np.maximum(a, 1e-20))
    rows = []
    for index in range(rings):
        values = stops[valid & (r * rings >= index) & (r * rings < index + 1)]
        mask = valid & (r * rings >= index) & (r * rings < index + 1)
        rows.append(dict(ring=[index / rings, (index + 1) / rings], pixels=len(values),
                         radius=float(np.median(r[mask])) if len(values) else None,
                         stops=float(np.median(values)) if len(values) else None))
    return rows


def accepted_sweep(root, subject, control):
    """Find a complete accepted Custom sweep, preferring explicit selection.

    Reject the earlier jobs whose requested amounts were reset on export.
    No source manifest rewrite or hand-made directory view is needed.
    """
    candidates = sorted(root.glob(f"exports-*-amounts-{subject}*"), reverse=True)
    if subject == "sirui-own":
        candidates += sorted(root.glob("exports-*-sirui-own"), reverse=True)
    for folder in candidates:
        paths = [folder / f"{folder.name.removeprefix('exports-')}_{control}-{a:03}.tif"
                 for a in (0, 50, 100, 150, 200)]
        if not all(p.is_file() for p in paths):
            continue
        records = [xmp(p) for p in paths]
        key = "crs:LensProfile" + control.title() + "Scale"
        if ([scalar(r, key) for r in records] == [str(a) for a in (0, 50, 100, 150, 200)] and
                all(scalar(r, "crs:LensProfileSetup") == "Custom" for r in records)):
            return paths
    raise ValueError(f"no accepted Custom {control} sweep for {subject}")


def vignette_law(values, y0):
    from scipy.optimize import minimize_scalar
    stops = np.asarray(values) - values[0]
    alpha = np.arange(5)[:, None] / 2
    y100 = y0 * np.exp2(stops[2])

    def predict(beta):
        y = np.where(alpha <= 1, y0 + alpha * (y100 - y0),
                     y100 + (1 - y100) * -np.expm1(-beta * np.maximum(alpha - 1, 0) * (y100 - y0) / (1 - y100)))
        return np.log2(y / y0)

    def fit(mask):
        return float(minimize_scalar(lambda b: np.mean((predict(b)[:, mask] - stops[:, mask]) ** 2),
                                     bounds=(0.01, 3), method="bounded").x)

    beta = fit(np.ones(stops.shape[1], bool))
    error = predict(beta) - stops
    training = np.arange(stops.shape[1]) % 2 == 0
    held = predict(fit(training))[:, ~training] - stops[:, ~training]
    return dict(law="linear luminance through 100; exponential approach to white above 100", beta=beta,
                pooled=residual(error), non_anchor=residual(error[[1, 3, 4]]),
                by_amount=[dict(amount=a, **residual(e)) for a, e in zip((0, 50, 100, 150, 200), error)],
                held_out=residual(held), held_out_non_anchor=residual(held[[1, 3, 4]]),
                linear_stops=residual(stops - alpha * stops[2]),
                linear_gain=residual(stops - np.log2(1 + alpha * (np.exp2(stops[2]) - 1))))


def defringe(a, b, layout):
    if a.shape != b.shape or a.shape[:2] != (layout["height"], layout["width"]):
        raise ValueError("exports must match the fringe layout dimensions")

    def samples(image, box):
        x0, y0, x1, y1 = box
        rgb = image[y0:y1, x0:x1]
        chroma = rgb / np.maximum(rgb.mean(axis=-1, keepdims=True), 1e-8) - 1
        return np.median(np.linalg.norm(chroma, axis=-1)), np.median(rgb, axis=(0, 1))

    rows = []
    for region in layout["regions"]:
        ca, ra = samples(a, region["box"])
        cb, rb = samples(b, region["box"])
        row = dict(region, chroma_before=float(ca), chroma_after=float(cb), rgb_before=ra.tolist(), rgb_after=rb.tolist(),
                   chroma_removed=float(ca - cb), rgb_change=(rb - ra).tolist())
        if region["kind"] == "fringe":
            def area(image):
                x0, y0, x1, y1 = region["box"]
                rgb = image[y0:y1, x0:x1]
                chroma = np.linalg.norm(rgb / np.maximum(rgb.mean(axis=-1, keepdims=True), 1e-8) - 1, axis=-1)
                return float(np.maximum(chroma - samples(image, region["reference"])[0], 0).sum(dtype=np.float64))

            area_a, area_b = area(a), area(b)
            x0, y0, x1, y1 = region["box"]
            reference = samples(a, region["reference"])[0]
            profiles = []
            for image in (a, b):
                rgb = image[y0 + min(40, (y1-y0)//4):y1 - min(40, (y1-y0)//4), x0:x1]
                c = np.linalg.norm(rgb / np.maximum(rgb.mean(axis=-1, keepdims=True), 1e-8) - 1, axis=-1)
                profiles.append(np.maximum(c - reference, 0).mean(axis=0))
            remaining = profiles[1] / np.maximum(profiles[0], 1e-8)
            if region["reference"][0] > x1:
                remaining = remaining[::-1]
            ca -= samples(a, region["reference"])[0]
            cb -= samples(b, region["reference"])[0]
            row.update(excess_chroma_before=float(ca), excess_chroma_after=float(cb),
                       excess_chroma_removed=float(ca - cb),
                       excess_area_before=area_a, excess_area_after=area_b,
                       columns_remaining_field_to_bar=remaining.tolist(),
                       area_fraction_removed=(area_a - area_b) / area_a if area_a > 1e-6 else None,
                       fraction_removed=float((ca - cb) / ca) if ca > 1e-6 else None)
        else:
            x0, y0, x1, y1 = region["box"]
            before, after = [im[y0:y1, x0:x1] for im in (a, b)]
            c0, c1 = [np.linalg.norm(im / np.maximum(im.mean(axis=-1, keepdims=True), 1e-8) - 1, axis=-1)
                      for im in (before, after)]
            row.update(chroma_change=float(cb - ca), rgb_change_norm=float(np.linalg.norm(rb - ra)),
                       pixels_losing_half_chroma=float(np.mean(c1 < 0.5 * c0)))
            yy, xx = np.indices(c0.shape)
            depth = np.minimum(np.minimum(xx, c0.shape[1] - 1 - xx), np.minimum(yy, c0.shape[0] - 1 - yy))
            row["rim_by_depth"] = [dict(depth_px=d, fraction_losing_half=float(np.mean(c1[depth == d] < 0.5 * c0[depth == d])),
                                        mean_fraction_removed=float(np.mean(1 - c1[depth == d] / np.maximum(c0[depth == d], 1e-8))))
                                   for d in range(min(25, int(depth.max()) + 1))]
        rows.append(row)
    return rows


def fit_defringe_response(amounts, response):
    """Descriptive saturation law on the synthetic chart, not a recovered filter.

    Fit R(a) = amplitude * (1 - exp(-(a/tau)**power)). The amplitude is
    solved linearly at each of the 121 by 121 fixed tau/power candidates.
    """
    a, y = np.asarray(amounts, float), np.asarray(response, float)
    tau = np.geomspace(0.25, 20, 121)[:, None, None]
    power = np.linspace(0.5, 8, 121)[None, :, None]
    basis = -np.expm1(-(a[None, None, :] / tau) ** power)
    amplitude = np.sum(basis * y, axis=2) / np.sum(basis ** 2, axis=2)
    errors = amplitude[..., None] * basis - y
    i, j = np.unravel_index(np.mean(errors ** 2, axis=2).argmin(), amplitude.shape)
    return dict(law="R(a) = amplitude * (1 - exp(-(a/tau)^power))", amplitude=float(amplitude[i, j]),
                tau=float(tau[i, 0, 0]), power=float(power[0, j, 0]), **residual(errors[i, j]))


def hue_response(rows, threshold=0.05):
    """Bracket affected runs on the sampled circular chart, at 5% removal.

    Keep the continuous response as well: a threshold is a reporting convention,
    not a claim that Lightroom's selection is a hard hue mask.
    """
    hues = sorted({r["hue_degrees"] for r in rows if r["kind"] == "fringe" and r["fringe_width_px"] == 6})
    wheel = []
    for hue in hues:
        samples = [r["fraction_removed"] for r in rows if r["kind"] == "fringe" and
                   r["fringe_width_px"] == 6 and r["hue_degrees"] == hue and r["fraction_removed"] is not None]
        wheel.append(float(np.median(samples)) if samples else None)
    if not set(range(0, 360, 10)).issubset(hues) or any(v is None for v in wheel):
        return dict(error="incomplete 36-hue wheel", response=wheel)
    active = np.array(wheel) >= threshold
    intervals = []
    if active.all():
        intervals = [dict(all_hues=True)]
    else:
        for i in range(len(hues)):
            if active[i] and not active[(i - 1) % len(hues)]:
                end = i
                while active[(end + 1) % len(hues)]:
                    end += 1
                intervals.append(dict(start_bracket=[hues[(i - 1) % len(hues)], hues[i]],
                                      end_bracket=[hues[end % len(hues)], hues[(end + 1) % len(hues)]]))
    return dict(threshold=threshold, intervals=intervals, hues=hues, response=wheel)


def neutral_fringe(root, output):
    folders = sorted(root.glob("exports-*-fringe-neutral"), reverse=True)
    if not folders:
        return None
    folder = folders[0]
    layout = json.loads((root / "lc3-fix-charts/fringe-neutral-layout.json").read_text())
    paths = sorted(folder.glob("*.tif"))
    off = next(p for p in paths if p.stem.endswith("_off"))
    a = linear(off)
    result = {}
    for path in paths:
        state = path.stem.split("_")[-1]
        cache = output / f"neutral-{state}.defringe.json"
        if cache.exists():
            response = json.loads(cache.read_text())
        else:
            response = defringe(a, linear(path), layout)
            save_json(cache, response)
        record = xmp(path)
        areas = {str(hue): {str(width): float(np.mean([r["area_fraction_removed"] for r in response if
                 r["kind"] == "fringe" and r["hue_degrees"] == hue and r["fringe_width_px"] == width]))
                 for width in (2, 6, 12)} for hue in (0, 180)}
        profiles = {str(hue): [r["columns_remaining_field_to_bar"] for r in response if r["kind"] == "fringe"
                    and r["hue_degrees"] == hue and r["fringe_width_px"] == 12] for hue in (0, 180)}
        result[state] = dict(hue=hue_response(response), areas=areas, profiles_12px=profiles,
                rendering={key: scalar(record, "crs:" + key) for key in
                           ("CameraProfile", "Look", "WhiteBalance", "Temperature", "Tint")},
                settings={key: scalar(record, key) for key in record if key.startswith("crs:Defringe")})
    save_json(output / "fringe-neutral.json", result)
    return result


def edge_positions(distance, luminance, level):
    """Linear crossings of a fixed clean-side half-height, in normal pixels."""
    indices = np.flatnonzero(np.diff(luminance >= level))
    return [float(distance[i] + (level - luminance[i]) * (distance[i + 1] - distance[i]) /
                  (luminance[i + 1] - luminance[i])) for i in indices]


def donor_fit(before, after, dark, bright):
    """Intersect the repair ray with the line of clean-side chromaticities.

    The bright share is unconstrained: values outside [0,1] and residuals must
    remain visible rather than forcing a donor conclusion. Equal clean colours
    cannot distinguish sides. All inputs are RGB / mean(RGB) - 1.
    """
    axis, delta = bright - dark, after - before
    matrix = np.column_stack((delta, -axis))
    if np.linalg.norm(axis) < 0.002 or np.linalg.matrix_rank(matrix, tol=1e-6) < 2:
        return None
    travel, share = np.linalg.lstsq(matrix, dark - before, rcond=None)[0]
    return dict(bright_share=float(share), travel=float(travel),
                residual=float(np.linalg.norm(before + travel * delta - dark - share * axis)))


def blurred_response(a, b, layout):
    weights = np.array([0.28804, 0.71187, 0.00009])  # linear ProPhoto Y
    distance = np.arange(-120, 120.001, 0.25)

    def chroma(rgb):
        return rgb / np.maximum(rgb.mean(axis=-1, keepdims=True), 1e-8) - 1

    def profile(image, stimulus, normal):
        tangent = np.arange(-300, 300, dtype=float) + 0.5
        theta = np.deg2rad(stimulus["angle_from_vertical"])
        cx, cy = stimulus["center"]
        x = cx - 0.5 + normal[None, :] * np.cos(theta) + tangent[:, None] * np.sin(theta)
        y = cy - 0.5 - normal[None, :] * np.sin(theta) + tangent[:, None] * np.cos(theta)
        ix, iy = np.floor(x).astype(int), np.floor(y).astype(int)
        fx, fy = (x - ix)[..., None], (y - iy)[..., None]
        sampled = ((1 - fy) * ((1 - fx) * image[iy, ix] + fx * image[iy, ix + 1]) +
                   fy * ((1 - fx) * image[iy + 1, ix] + fx * image[iy + 1, ix + 1]))
        return sampled.mean(axis=0)

    # A thin line has no clean dark interior; the neutral edge supplies that
    # chart's rendered dark colour instead of assuming the source RGB survived.
    neutral = layout["stimuli"][0]
    clean_dark = profile(a, neutral, np.array([-180.]))[0]
    clean_dark_after = profile(b, neutral, np.array([-180.]))[0]
    rows = []
    for stimulus in layout["stimuli"]:
        pa, pb = [profile(image, stimulus, distance) for image in (a, b)]
        line = stimulus["line_width_px"]
        clean = profile(a, stimulus, np.array([-180., 180.]))
        clean_after = profile(b, stimulus, np.array([-180., 180.]))
        dark, bright = (clean_dark, clean[1]) if line else clean
        after_dark, after_bright = (clean_dark_after, clean_after[1]) if line else clean_after
        clean_c = chroma(np.array([dark, bright]))
        ca, cb = chroma(pa), chroma(pb)
        own_dark = (np.abs(distance) < line / 2) if line else (distance < 0)
        changed = np.max(np.abs(pb - pa), axis=-1) > 0.0002
        edge_distance = np.abs(np.abs(distance) - line / 2) if line else np.abs(distance)
        ya, yb = pa @ weights, pb @ weights
        level = float((dark @ weights + bright @ weights) / 2)
        pos_a, pos_b = [edge_positions(distance, y, level) for y in (ya, yb)]
        shifts = [min(pos_b, key=lambda p: abs(p - q)) - q for q in pos_a] if pos_b else []
        donors = []
        for i in np.flatnonzero(changed & (edge_distance < 40)):
            fit = donor_fit(ca[i], cb[i], *clean_c)
            donors.append(dict(distance_px=float(distance[i]), before=ca[i].tolist(), after=cb[i].tolist(),
                               same_side_distance=float(np.linalg.norm(cb[i] - clean_c[0 if own_dark[i] else 1])),
                               other_side_distance=float(np.linalg.norm(cb[i] - clean_c[1 if own_dark[i] else 0])),
                               fit=fit))
        sigma = max(stimulus.get("sigma_rgb_px", [3]))
        donor_probes = []
        axis = clean_c[1] - clean_c[0]
        for d in (-2 * sigma, -sigma, -sigma / 3, sigma / 3, sigma, 2 * sigma):
            i = int(np.argmin(np.abs(distance - d)))
            donor_probes.append(dict(distance_px=float(distance[i]), chroma_before=ca[i].tolist(), chroma_after=cb[i].tolist(),
                                     changed=bool(changed[i]),
                                     after_bright_share=float((cb[i] - clean_c[0]) @ axis / (axis @ axis))
                                     if np.linalg.norm(axis) >= 0.002 else None,
                                     ray_fit=donor_fit(ca[i], cb[i], *clean_c) if changed[i] else None))
        side_areas = {}
        # Score the actual pixels, including slants. Resampled normal profiles
        # are retained for colour comparisons and subpixel edge crossings only.
        x0, y0, x1, y1 = stimulus["box"]
        yy, xx = np.mgrid[y0:y1, x0:x1]
        cx, cy = stimulus["center"]
        theta = np.deg2rad(stimulus["angle_from_vertical"])
        normal = (xx + 0.5 - cx) * np.cos(theta) - (yy + 0.5 - cy) * np.sin(theta)
        tangent = (xx + 0.5 - cx) * np.sin(theta) + (yy + 0.5 - cy) * np.cos(theta)
        roi = (np.abs(normal) < 120) & (np.abs(tangent) < 300)
        native_a, native_b = a[y0:y1, x0:x1][roi], b[y0:y1, x0:x1][roi]
        native_d = normal[roi]
        native_dark = (np.abs(native_d) < line / 2) if line else native_d < 0
        native_areas = [np.maximum(np.linalg.norm(chroma(im), axis=-1) -
                                  np.linalg.norm(chroma(ref), axis=-1)[np.where(native_dark, 0, 1)], 0)
                        for im, ref in ((native_a, np.array([dark, bright])),
                                        (native_b, np.array([after_dark, after_bright])))]
        native_changed = np.max(np.abs(native_b - native_a), axis=-1) > 0.0002
        native_reach = np.abs(np.abs(native_d) - line / 2) if line else np.abs(native_d)
        for name, mask in (("dark", native_dark), ("bright", ~native_dark), ("all", np.ones(len(native_d), bool))):
            aa, ab = [float(v[mask].sum(dtype=np.float64)) for v in native_areas]
            side_areas[name] = dict(before=aa, after=ab, fraction_removed=1 - ab / aa if aa > 0.001 else None)
        rows.append(dict(stimulus=stimulus, area=side_areas,
                         changed_normal_span_px=[float(native_d[native_changed].min()), float(native_d[native_changed].max())]
                         if native_changed.any() else [],
                         reach_from_edge_px=float(native_reach[native_changed].max()) if native_changed.any() else 0.,
                         change_threshold_linear_rgb=0.0002, clean_dark_rgb=dark.tolist(), clean_bright_rgb=bright.tolist(),
                         area_reference_dark_rgb_after=after_dark.tolist(), area_reference_bright_rgb_after=after_bright.tolist(),
                         edge_before_px=pos_a, edge_after_px=pos_b, edge_shift_px=shifts,
                         line_min_y_before=float(ya.min()) if line else None,
                         line_min_y_after=float(yb.min()) if line else None,
                         distance_px=distance.tolist(), rgb_before=pa.tolist(), rgb_after=pb.tolist(),
                         donor_probes=donor_probes, donors=donors))
    return rows


def neutral_round(root, output, number):
    """The full neutral sweep is primary when its two complete jobs exist."""
    import matplotlib.pyplot as plt
    import lightroom_jobs

    wheel_folder = root / "exports-lc3n5-fringe-wheel"
    edges_folder = root / "exports-lc3n5-fringe-edges"
    layout_folder = root / "lc3-neutral-round"
    layout = json.loads((layout_folder / "fringe-wheel-layout.json").read_text())
    output.mkdir(parents=True, exist_ok=True)
    before = linear(wheel_folder / "lc3n5-fringe-wheel_off.tif")
    summary, lines = {}, []

    def accepted(path, requested):
        requested = dict(DefringePurpleAmount=0, DefringePurpleHueLo=30, DefringePurpleHueHi=70,
                         DefringeGreenAmount=0, DefringeGreenHueLo=40, DefringeGreenHueHi=60) | requested
        record = xmp(path)
        rendering = {key: scalar(record, "crs:" + key) for key in
                     ("CameraProfile", "Look", "WhiteBalance", "Temperature", "Tint", "Version", "ProcessVersion")}
        if (rendering["CameraProfile"] != "Embedded" or rendering["Look"] is not None or
                rendering["WhiteBalance"] != "As Shot" or float(rendering["Temperature"]) != 6500 or float(rendering["Tint"]) != 10):
            raise ValueError(f"{path.name}: neutral rendering was not retained")
        settings = {key.removeprefix("crs:"): scalar(record, key) for key in record if key.startswith("crs:Defringe")}
        differences = {key: dict(requested=value, accepted=settings.get(key)) for key, value in requested.items()
                       if float(settings.get(key, "nan")) != value}
        state = path.stem.split("_")[-1]
        if differences and "-pair-" not in state and not state.endswith(("-lo-095", "-hi-005")):
            raise ValueError(f"{path.name}: unexpected setting readback {differences}")
        return dict(settings=settings, rendering=rendering, requested=requested, differences=differences)

    for state, requested in lightroom_jobs.states("fringe-wheel"):
        path = wheel_folder / f"lc3n5-fringe-wheel_{state}.tif"
        response = defringe(before, linear(path), layout)
        save_json(output / f"wheel-{state}.defringe.json", response)
        areas = {str(hue): {str(width): float(np.mean([r["area_fraction_removed"] for r in response if
                 r["kind"] == "fringe" and r["hue_degrees"] == hue and r["fringe_width_px"] == width]))
                 for width in (2, 6, 12)} for hue in (0, 180)}
        protected = [r for r in response if r["kind"] == "protected"]
        summary[state] = dict(**accepted(path, requested), hue=hue_response(response), areas=areas,
                              protected={r["colour"] + "-" + str(r["fringe_width_px"]):
                                         {k: r[k] for k in ("pixels_losing_half_chroma", "rim_by_depth")}
                                         for r in protected})
        lines.append(f"{state}: {json.dumps({k: v for k, v in summary[state].items() if k != 'protected'})}")
    del before
    save_json(output / "wheel-summary.json", summary)
    if number == 9:
        fig, axes = plt.subplots(2, 3, figsize=(17, 9))
        for index, colour in enumerate(("purple", "green")):
            hue = "0" if colour == "purple" else "180"
            for width in (2, 6, 12):
                amounts = (0, 1, 2, 5, 10, 20)
                axes[0, index].plot(amounts, [summary[f"{colour}-amount-{n:02}"]["areas"][hue][str(width)] for n in amounts],
                                    ".-", label=f"{width} px")
            axes[0, index].set(title=colour, xlabel="Amount", ylabel="Integrated excess removed")
            axes[0, index].legend()
            for endpoint in ("lo", "hi"):
                states = [(s, v) for s, v in summary.items() if s.startswith(f"{colour}-hue-{endpoint}-")]
                axes[1, index].plot([int(s.split("-")[-1]) for s, v in states],
                                   [v["hue"]["intervals"][0]["start_bracket" if endpoint == "lo" else "end_bracket"][0]
                                    for s, v in states], ".", label=endpoint)
            axes[1, index].set(xlabel="Requested handle (readback in JSON)", ylabel="Boundary lower bracket, degrees")
            axes[1, index].legend()
            wide = summary[f"{colour}-hue-lo-000"]["hue"]
            axes[0, 2].plot(wide["hues"], wide["response"], ".-", label=colour)
            patch = "purple-6" if colour == "purple" else "green-6"
            for amount in (1, 5, 10, 20):
                rim = summary[f"{colour}-amount-{amount:02}"]["protected"][patch]["rim_by_depth"]
                axes[1, 2].plot([r["depth_px"] for r in rim], [r["mean_fraction_removed"] for r in rim], label=f"{colour} {amount}")
        axes[0, 2].set(title="Amount 20, window 0 / 100", xlabel="Chart hue, degrees", ylabel="Median excess removed")
        axes[1, 2].set(title="Protected patch rim", xlabel="Depth from border, px", ylabel="Mean chroma removed")
        axes[0, 2].legend(); axes[1, 2].legend(fontsize=7)
        fig.tight_layout(); fig.savefig(output / "lc3-neutral-wheel.png", dpi=140); plt.close(fig)
    else:
        edge_layout = json.loads((layout_folder / "fringe-edges-layout.json").read_text())
        before = linear(edges_folder / "lc3n5-fringe-edges_off.tif")
        edge_summary = {}
        fig, axes = plt.subplots(3, 4, figsize=(18, 11))
        for state, requested in lightroom_jobs.states("fringe-edges"):
            path = edges_folder / f"lc3n5-fringe-edges_{state}.tif"
            response = blurred_response(before, linear(path), edge_layout)
            edge_summary[state] = dict(**accepted(path, requested), stimuli=response)
            save_json(output / f"edges-{state}.json", edge_summary[state])
            for axis, row in zip(axes.flat, response):
                axis.plot(row["distance_px"], np.linalg.norm(np.array(row["rgb_after"]) /
                          np.maximum(np.mean(row["rgb_after"], axis=-1, keepdims=True), 1e-8) - 1, axis=-1), label=state)
                axis.set(title=row["stimulus"]["name"], xlim=(-25, 25), xlabel="Edge normal, px", ylabel="Relative chroma")
        axes.flat[0].legend(fontsize=6)
        fig.tight_layout(); fig.savefig(output / "lc3-neutral-edges.png", dpi=140); plt.close(fig)
        save_json(output / "edge-summary.json", edge_summary)
        lines += [f"{s}: {json.dumps({k: v for k, v in row.items() if k not in ('distance_px', 'rgb_before', 'rgb_after', 'donors')})}"
                  for s, value in edge_summary.items() for row in value["stimuli"]]
    save_json(output / f"lane-{number}.json", summary)
    (output / f"lane-{number}.md").write_text(f"# Lane {number}: PASS\n\nFull neutral sweep; 97 wheel exports and 8 edge exports.\n\n" +
        "Rendering, requested and accepted settings, continuous responses and per-stimulus measurements follow.\n\n```text\n" +
        "\n".join(lines) + "\n```\n")
    print(f"Lane {number}: PASS; 97 neutral wheel states" + ("; 8 blurred-edge states" if number == 10 else ""))
    return True


def file_curves(path):
    """Read only the public correction tags. Never copy identity fields to reports."""
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "spikes/lens-tags"))
    from tags import TIFF
    tiff = TIFF(str(path))
    first, _ = tiff.ifd(tiff.first)
    for offset in tiff.values(first[0x014A]) if 0x014A in first else []:
        sub, _ = tiff.ifd(offset)
        if 0x7037 in sub:
            return {name: np.array(tiff.values(sub[tag])[1:], float)
                    for tag, name in [(0x7037, "distortion"), (0x7035, "lateral")] if tag in sub}
    return {}


def curve(knots, t, placement="endpoints"):
    positions = np.arange(len(knots)) / (len(knots) - 1)
    if placement == "half-step":
        positions += 0.5 / (len(knots) - 1)
    return np.interp(t, positions, knots)


def distortinfo_relation(knots, info, rmax):
    """Compare aux's even polynomial with the normalized file factor.

    Fit one framing multiplier, with both endpoint and half-step placements.
    Separately test factor(t/scale)/scale, the file's scaled-radius reading.
    Also report the best even cubic approximation of the file itself, to separate
    polynomial approximation error from disagreement with the aux field.
    """
    t = np.linspace(0, 1, 1001)
    design = t[:, None] ** np.arange(0, 8, 2)
    polynomial = design @ np.asarray(info)
    results = {}
    for placement in ("endpoints", "half-step"):
        factor = 1 + curve(knots, t, placement) / 16384
        multiplier = float(np.dot(factor * t, polynomial * t) / np.dot(polynomial * t, polynomial * t))
        fit = np.linalg.lstsq(design * t[:, None], factor * t, rcond=None)[0]
        def scaled_error(scale):
            predicted = (1 + curve(knots, t / scale, placement) / 16384) / scale
            return (predicted - polynomial) * t * rmax

        # A bounded, one-dimensional fit; no polynomial coefficients are refitted.
        lo, hi = 0.9, 1.15
        ratio = (np.sqrt(5) - 1) / 2
        x, y = hi - ratio * (hi - lo), lo + ratio * (hi - lo)
        fx, fy = np.mean(scaled_error(x) ** 2), np.mean(scaled_error(y) ** 2)
        for _ in range(75):
            if fx < fy:
                hi, y, fy = y, x, fx
                x = hi - ratio * (hi - lo)
                fx = np.mean(scaled_error(x) ** 2)
            else:
                lo, x, fx = x, y, fy
                y = lo + ratio * (hi - lo)
                fy = np.mean(scaled_error(y) ** 2)
        scale = (lo + hi) / 2
        results[placement] = dict(framing_multiplier=multiplier,
                                 **residual((polynomial * multiplier - factor) * t * rmax),
                                 scaled_radius=dict(law="aux(t) = file_factor(t / scale) / scale", scale=scale,
                                                    **residual(scaled_error(scale))),
                                 file_polynomial_residual=residual((design @ fit - factor) * t * rmax))
    return results


def compare_file(rows, shape, knots):
    """Backward-map comparison using feature correspondences p -> q, fitting framing only."""
    h, w = shape[:2]
    group = [r for r in rows if r["channel"] == "G"]
    if not group:
        return dict(error="no green correspondences", rms=None)
    p = np.array([[r["x"], r["y"]] for r in group]) - [(w - 1) / 2, (h - 1) / 2]
    q = p + np.array([[r["dx"], r["dy"]] for r in group])
    t = np.linalg.norm(q, axis=1) / (np.hypot(w, h) / 2)
    predicted = q * (1 + curve(knots, t) / 16384)[:, None]
    framing = float(np.sum(predicted * p) / np.sum(predicted ** 2))
    return dict(scale=1 / framing, patches=len(p), **residual(np.linalg.norm(predicted * framing - p, axis=1)))


def pixel_hash(path):
    pixels, icc = probe.read_tiff(path)
    return hashlib.sha256(pixels.tobytes()).hexdigest(), probe.icc_gamma(icc), pixels.shape


def scalar(record, key):
    return record.get(key, [None])[0]


def save_json(path, value):
    path.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")


def lane(root, output, number):
    """Run one frozen LC3 lane against the existing round-two manifest. Never queue jobs.

    Plotting needs matplotlib; lane 3 also uses rawpy for LC2's untreated bilinear
    decode. All outputs, including owner-derived fit coefficients, are private.
    """
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    if number in (9, 10) and (root / "exports-lc3n5-fringe-wheel").is_dir():
        return neutral_round(root, output, number)
    output.mkdir(parents=True, exist_ok=True)
    plan_path = root / "lc3r2-plan.json"
    plan = (json.loads(plan_path.read_text()) if plan_path.exists() or number not in (5, 6)
            else dict(jobs=[]))
    jobs = {j["name"]: j for j in plan["jobs"]}
    records = {}
    for job in jobs:
        for path in sorted((root / f"exports-{job}").glob("*.tif")):
            records[path] = xmp(path)
    save_json(output / "xmp.json", {p.name: v for p, v in records.items()})
    names = ["regression", "defaults", "builtin-ca", "distortinfo", "distortion-amount",
             "vignette-amount", "viltrox-no-profile", "remove-ca", "defringe-amount", "defringe-hue"]
    title = f"LC3 lane {number}: {names[number - 1]}"
    lines, detail, passed = [], {}, True
    fig, axes = plt.subplots(1, 1, figsize=(14, 8))
    ax = axes

    def export(job, state):
        name = "lc3r2-" + job
        return root / f"exports-{name}" / f"{name}_{state}.tif"

    def field(a, b):
        cache = output / (b.stem + ".displacement.json")
        if cache.exists():
            return json.loads(cache.read_text())
        result = displacement(linear(a), linear(b), patch=256, step=512)
        save_json(cache, result)
        return result

    def plot_rings(axis, result, label, relative=False):
        green = {tuple(r["ring"]): r for r in result["rings"] if r["channel"] == "G"}
        for channel in ("R", "B") if relative else "RGB":
            group = [r for r in result["rings"] if r["channel"] == channel and r["radial"] is not None
                     and (not relative or green[tuple(r["ring"])]["radial"] is not None)]
            axis.plot([np.mean(r["ring"]) for r in group],
                      [r["radial"] - (green[tuple(r["ring"])]["radial"] if relative else 0) for r in group],
                      ".-", label=f"{label} {channel}, n={sum(r['patches'] for r in group)}")
        axis.set(xlabel="Radius / half diagonal", ylabel="Radial feature motion (px)")

    if number == 1:
        pairs = json.loads((root / "lc3r2-regression.json").read_text())["comparisons"]
        for pair in pairs:
            a, ga, _ = pixel_hash(pair["baseline"])
            b, gb, _ = pixel_hash(pair["head"])
            equal = a == b and ga == gb
            passed &= equal
            lines += [f"{'PASS' if equal else 'FAIL'} {Path(pair['head']).stem.split('_')[-1]}",
                      f"baseline {a}", f"head     {b}", f"ICC gamma {ga} / {gb}"]
        detail = dict(comparisons=len(pairs), equal=passed)
        ax.axis("off")
        ax.text(0, 0.9, "\n".join(lines), family="monospace", fontsize=12, va="top")
    elif number == 2:
        defaults = {p.name: v for p, v in records.items() if "02-defaults" in p.name}
        fields = sorted({k for v in records.values() for k in v if any(s in k for s in
                         ("Lens", "Distortion", "Lateral", "Chromatic", "Defringe", "Vignette", "Perspective", "Crop"))})
        labels = [name.split("02-defaults-")[1].split("_defaults")[0] for name in defaults]
        table = [[str(scalar(v, key) or "absent") for v in defaults.values()] for key in fields]
        save_json(output / "defaults-lens-fields.json", {name: {k: v.get(k, "absent") for k in fields}
                                                        for name, v in defaults.items()})
        ranges = {p.parent.parent.name.removeprefix("exports-lc3r2-12-ranges-"): json.loads(p.read_text())
                  for p in sorted(root.glob("exports-lc3r2-12-ranges-*/ranges/*.json"))}
        save_json(output / "ranges.json", ranges)
        for key in sorted(next(iter(ranges.values()))["neutral"]):
            observations = [r["neutral"][key] for r in ranges.values()]
            values = {(v.get("minimum"), v.get("maximum"), v.get("current"), v.get("neutralSetting"),
                       v.get("valueError"), v.get("rangeError")) for v in observations}
            lines.append(f"{key}: {sorted(values, key=str)}")
        lines.insert(0, f"{len(defaults)} fresh imports; {len(fields)} present/absent lens fields; {len(ranges)} SDK readbacks")
        detail = dict(defaults=defaults, lens_fields=fields, ranges=ranges)
        fig.set_size_inches(20, max(9, len(fields) * 0.25))
        ax.axis("off")
        display = [[v if len(v) < 36 else v[:32] + "..." for v in row] for row in table]
        t = ax.table(cellText=display, rowLabels=fields, colLabels=labels, loc="center", cellLoc="left")
        t.auto_set_font_size(False)
        t.set_fontsize(6)
        t.scale(1, 1.25)
        passed = len(defaults) == 8 and len(ranges) == 4
    elif number == 3:
        path = export("03-profile-a063-75mm", "off")
        source = Path(jobs["lc3r2-03-profile-a063-75mm"]["source"])
        # Same untreated, bilinear DefaultCrop decode used by LC2. Compare
        # channel-relative motions to remove the common registration.
        sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "spikes/lens-tags"))
        from register import ours
        cache = output / "builtin-displacement.json"
        if cache.exists():
            measured = json.loads(cache.read_text())
        else:
            untreated = np.moveaxis(ours(str(source)), 0, -1)
            image = linear(path) ** (1 / 2.2)
            measured = displacement(untreated, image, patch=256, step=256)
            save_json(cache, measured)
        h, w = 4672, 7008
        rmax = np.hypot(w, h) / 2
        lateral = file_curves(source)["lateral"]
        green = {(r["x"], r["y"]): r for r in measured["patches"] if r["channel"] == "G"}
        detail = {}
        t = np.linspace(0, 1, 201)
        for label, knots in zip(("R", "B"), np.split(lateral, 2)):
            group = [r for r in measured["patches"] if r["channel"] == label and (r["x"], r["y"]) in green]
            relative = np.array([[r["dx"] - green[r["x"], r["y"]]["dx"],
                                  r["dy"] - green[r["x"], r["y"]]["dy"]] for r in group])
            v = np.array([[r["x"] - (w - 1) / 2, r["y"] - (h - 1) / 2] for r in group])
            ts = np.linalg.norm(v, axis=1) / rmax
            channel = dict(patches=len(group))
            for placement, style in [("endpoints", "--"), ("half-step", ":")]:
                prediction = -v * curve(knots, ts, placement)[:, None] / 2097152
                scale = float(np.sum(relative * prediction) / np.sum(prediction ** 2))
                channel[placement] = dict(nominal=residual(np.linalg.norm(relative - prediction, axis=1)),
                                          fitted_scale=scale, scaled=residual(np.linalg.norm(relative - scale * prediction, axis=1)))
                ax.plot(t, -t * rmax * curve(knots, t, placement) / 2097152, style, label=f"file {label} {placement}")
            detail[label] = channel
            lines.append(f"{label}: {json.dumps(channel)}")
        plot_rings(ax, measured, "untreated to Lightroom", relative=True)
        lines += ["Residuals include colour-transform and demosaic differences; these are not an isolated camera-channel correction."]
        passed = all(detail[c]["patches"] > 0 for c in ("R", "B"))
    elif number == 4:
        relations, absent, seen = {}, 0, {}
        for path, record in records.items():
            info = scalar(record, "aux:LensDistortInfo")
            if info is None:
                absent += 1
                continue
            job = jobs[path.parent.name.removeprefix("exports-")]
            source = Path(job["source"])
            if (str(source), info) not in seen:
                knots = file_curves(source).get("distortion")
                if knots is None:
                    continue
                relation = distortinfo_relation(knots, [float(Fraction(v)) for v in info.split()], np.hypot(7008, 4672) / 2)
                seen[str(source), info] = relation
                label = source.stem
                relations[label] = relation
                for placement in relation:
                    lines.append(f"{label} {placement}: {json.dumps(relation[placement])}")
        detail = dict(present=len(records) - absent, absent=absent, relations=relations)
        xs = np.arange(len(relations))
        for i, placement in enumerate(("endpoints", "half-step")):
            ax.bar(xs + i * 0.35, [v[placement]["scaled_radius"]["rms"] for v in relations.values()], 0.35, label=placement)
        ax.set(xticks=xs + 0.175, xticklabels=list(relations), ylabel="File factor(t/scale)/scale vs aux rms (px)")
        lines.insert(0, f"LensDistortInfo present in {len(records) - absent}/{len(records)} exports, absent in {absent}; {len(relations)} source relations")
        passed = bool(relations)
    elif number in (5, 6):
        control = "distortion" if number == 5 else "vignetting"
        subjects = ["grid", "a063-33mm", "a063-54mm", "a063-75mm"] if number == 5 else ["flat"]
        if number == 5 and list(root.glob("exports-*-sirui-own")) and "lc3r2-03-profile-sirui35-f1p4" in jobs:
            subjects.append("sirui-own")
        detail = {}
        for subject in subjects:
            print(f"Registering accepted {subject} {control} sweep", file=sys.stderr, flush=True)
            paths = accepted_sweep(root, subject, control)
            accepted = [float(scalar(xmp(p), "crs:LensProfile" + control.title() + "Scale")) for p in paths]
            if number == 5:
                knots = (file_curves(Path(jobs["lc3r2-03-profile-sirui35-f1p4"]["source"]))["distortion"]
                         if subject == "sirui-own" else None)
                p, q, registration = sweep_points(paths, grid=subject == "grid")
                intact = None
                if subject == "grid":
                    absolute = q + [3503.5, 2335.5]
                    intact = (np.min(np.minimum(absolute, [7008, 4672] - absolute), axis=2) > 8).all(axis=0)
                    registration["edge_cut_points"] = int((~intact).sum())
                law = distortion_laws(p, q, (4672, 7008), knots=knots, intact=intact)
                law["registration"] = registration
                detail[subject] = law
                t = np.linalg.norm(p, axis=1) / (np.hypot(7008, 4672) / 2)
                for i, amount in enumerate((0, 50, 100, 150, 200)):
                    motion = np.sum((q[i] - p) * p, axis=1) / np.linalg.norm(p, axis=1)
                    ax.scatter(t, motion, s=1, label=f"{subject} {amount}")
                scores = {name: dict(pooled=v["pooled"], non_anchor=v["non_anchor"],
                                    by_amount=[{k: r[k] for k in ("amount", "rms", "p95")} for r in v["by_amount"]])
                          for name, v in law["laws"].items()}
                lines.append(f"{subject}: accepted {accepted}; common points {len(p)}; {json.dumps(scores)}")
                lines.append(f"{subject}: registration {json.dumps({k: v for k, v in registration.items() if k != 'by_amount'})}")
                lines.append(f"{subject}: free radial fit {json.dumps(law['free_radial_fit'])}")
                for name, result in law["laws"].items():
                    verdicts = []
                    for row, floor in zip(result["by_amount"][1:], law["free_radial_fit"][1:]):
                        if row["rms"] <= 0.15:
                            verdict = "within 0.15 px"
                        elif row["rms"] <= floor["rms"] + 0.02:
                            verdict = "above 0.15 px at the registration floor"
                        else:
                            verdict = "above 0.15 px and the free radial fit; law or anchor mismatch"
                        verdicts.append(f"{row['amount']}: {row['rms']:.6f} px rms, {verdict}")
                    lines.append(f"{subject} {name}: " + "; ".join(verdicts))
                if intact is not None:
                    lines.append(f"{subject}: complete disks, same anchor fit, {json.dumps(law['laws']['scaled-radius']['complete_disks'])}")
            else:
                a = linear(paths[0]) @ probe.PROPHOTO_Y
                y0 = float(np.median(a))
                rings = [gain(a, linear(p) @ probe.PROPHOTO_Y, 20) for p in paths]
                values = np.array([[r["stops"] for r in rows] for rows in rings])
                law = vignette_law(values, y0)
                detail[subject] = dict(accepted=accepted, observations=rings, law=law)
                for amount, rows in zip(accepted, rings):
                    ax.plot([r["radius"] for r in rows], [r["stops"] for r in rows], label=f"{subject} {amount}")
                lines.append(f"{subject}: accepted {accepted}; law {json.dumps(law)}")
        if number == 5:
            lines.append("Two amount laws: scaled-radius with re-framing for the Adobe profile; "
                         "linear displacement with the framing of 100 for the file's own curve (Camera Settings). "
                         "Scores above 0.15 px remain failures of that bar, including registration-floor limits.")
        ax.set(xlabel="Radius / half diagonal", ylabel="Feature motion (px)" if number == 5 else "Luminance gain (stops)")
    elif number == 7:
        a, b = [export("03-profile-viltrox50-f1p4", s) for s in ("off", "on")]
        ha, _, _ = pixel_hash(a)
        hb, _, _ = pixel_hash(b)
        profile = scalar(records[b], "crs:LensProfileName")
        detail = dict(profile=profile, pixels_equal=ha == hb, off_hash=ha, on_hash=hb)
        passed = bool(profile) or ha == hb
        lines.append(json.dumps(detail))
        ax.axis("off")
        ax.text(0, 0.85, f"Selected profile: {profile or 'absent'}\nPixels equal: {ha == hb}\nOff {ha}\nOn  {hb}", family="monospace", fontsize=12)
    elif number == 8:
        detail = {}
        for subject in ("08-ca-viltrox50", "08-ca-edges"):
            a, b = [export(subject, s) for s in ("off", "on")]
            measured = field(a, b)
            detail[subject] = measured
            plot_rings(ax, measured, subject, relative=True)
            lines.append(f"{subject}: {len(measured['patches'])} accepted channel patches; {measured['rejected_channel_patches']} rejected; fits {json.dumps(measured['fit'])}")
            passed &= bool(measured["patches"])
    elif number in (9, 10):
        subject = "09-defringe-hue-width"
        base = export(subject, "off")
        layout = json.loads((root / "lc3-r2-charts/fringe-layout.json").read_text())
        a = None
        detail = {}
        paths = sorted(p for p in records if subject in p.name and
                       ("-amount-" if number == 9 else "-hue-") in p.stem.split("_")[-1])
        for path in paths:
            state = path.stem.split("_")[-1]
            cache = output / (state + ".defringe.json")
            response = json.loads(cache.read_text()) if cache.exists() else None
            if response is None or "columns_remaining_field_to_bar" not in response[0]:
                if a is None:
                    a = linear(base)
                response = defringe(a, linear(path), layout)
                save_json(cache, response)
            settings = {k.removeprefix("crs:"): scalar(records[path], k) for k in records[path] if k.startswith("crs:Defringe")}
            intervals = hue_response(response)
            protected = [r for r in response if r["kind"] != "fringe"]
            maxima = dict(rgb_change=max(r["rgb_change_norm"] for r in protected),
                          chroma_change=max(abs(r["chroma_change"]) for r in protected),
                          pixels_losing_half_chroma=max(r["pixels_losing_half_chroma"] for r in protected))
            widths = {str(hue): {str(width): float(np.median([r["fraction_removed"] for r in response if
                       r["kind"] == "fringe" and r["hue_degrees"] == hue and r["fringe_width_px"] == width]))
                       for width in (2, 6, 12)} for hue in (0, 180)}
            areas = {str(hue): {str(width): float(np.mean([r["area_fraction_removed"] for r in response if
                       r["kind"] == "fringe" and r["hue_degrees"] == hue and r["fringe_width_px"] == width]))
                       for width in (2, 6, 12)} for hue in (0, 180)}
            detail[state] = dict(settings=settings, hue=intervals, protected_max=maxima, widths=widths, areas=areas)
            if number == 10:
                lines.append(f"{state}: kept {json.dumps(settings)}, intervals {json.dumps(intervals['intervals'])}, protected {json.dumps(maxima)}, widths {json.dumps(widths)}")
        if number == 9:
            fig.clear()
            axs = fig.subplots(2, 2)
            for index, colour in enumerate(("purple", "green")):
                amounts = (0, 1, 2, 5, 10, 20)
                for hue, style in [(0, "-"), (180, "--")]:
                    for width in (2, 6, 12):
                        ys = [detail[f"{colour}-amount-{n:02}"]["areas"][str(hue)][str(width)] for n in amounts]
                        axs[0, index].plot(amounts, ys, style, marker=".", label=f"hue {hue}, {width}px")
                        if hue == (0 if colour == "purple" else 180):
                            fitted = fit_defringe_response(amounts, ys)
                            lines.append(f"{colour} {width}px area response fit: {json.dumps(fitted)}")
                for kind in ("pixels_losing_half_chroma",):
                    axs[1, index].plot(amounts, [detail[f"{colour}-amount-{n:02}"]["protected_max"][kind] for n in amounts], ".-", label=kind)
                axs[0, index].set(title=colour, ylabel="Fraction of integrated excess fringe chroma removed", xlabel="Amount")
                axs[1, index].set(xlabel="Amount", ylabel="Protected pixels losing over half their chroma")
                axs[0, index].legend(fontsize=8)
                axs[1, index].legend(fontsize=8)
            for state, value in detail.items():
                lines.append(f"{state}: area response {json.dumps(value['areas'])}; median response {json.dumps(value['widths'])}; protected {json.dumps(value['protected_max'])}; kept {json.dumps(value['settings'])}")
            passed = len(detail) == 12
        else:
            fig.clear()
            fig.set_size_inches(16, 10)
            axs = fig.subplots(2, 2)
            fig.subplots_adjust(left=0.08, right=0.86, top=0.90, bottom=0.16, hspace=0.38, wspace=0.25)
            for index, colour in enumerate(("purple", "green")):
                for j, endpoint in enumerate(("lo", "hi")):
                    group = [(s, v) for s, v in detail.items() if s.startswith(f"{colour}-hue-{endpoint}-")]
                    matrix = np.array([v["hue"]["response"] for _, v in group])
                    axis = axs[index, j]
                    image = axis.imshow(matrix, aspect="auto", extent=(-5, 355, len(group) - 0.5, -0.5), vmin=0, vmax=1)
                    axis.set(title=f"{colour} {endpoint}", xlabel="Chart linear-RGB hue (degrees)", ylabel="Requested / accepted handle")
                    key = f"Defringe{colour.title()}Hue{endpoint.title()}"
                    axis.set_yticks(range(len(group)), [f"{s.split('-')[-1]} / {v['settings'][key]}" for s, v in group], fontsize=7)
            fig.colorbar(image, ax=axs.ravel().tolist(), label="Fraction removed", fraction=0.025)
            max_protected = max(v["protected_max"]["rgb_change"] for v in detail.values())
            max_width = {str(hue): {str(width): max(v["areas"][str(hue)][str(width)] for v in detail.values())
                         for width in (2, 6, 12)} for hue in (0, 180)}
            width_text = "; ".join(f"hue {hue}: " + ", ".join(f"{width}px {value:.2%}" for width, value in values.items())
                                   for hue, values in max_width.items())
            fig.text(0.08, 0.04, f"Maximum change of protected median RGB {max_protected:.7f}\nBest integrated removal: {width_text}", fontsize=10)
            passed = len(detail) == 80 and all("error" not in v["hue"] for v in detail.values())
    if number in (9, 10):
        neutral = neutral_fringe(root, output)
        if neutral is not None:
            detail["fringe-neutral"] = neutral
            for state, value in neutral.items():
                lines.append(f"fringe-neutral {state}: rendering {json.dumps(value['rendering'])}; "
                             f"intervals {json.dumps(value['hue']['intervals'])}; areas {json.dumps(value['areas'])}")
    if number not in (1, 2, 7, 9, 10):
        ax.legend(fontsize=7, ncol=2)
        ax.grid(alpha=0.2)
    fig.suptitle(title + (" — PASS" if passed else " — FAIL"))
    if number != 10:
        fig.tight_layout()
    fig.savefig(output / f"lc3-{names[number - 1]}.png", dpi=140, bbox_inches="tight")
    plt.close(fig)
    save_json(output / f"lane-{number}.json", detail)
    command = f"PYTHONPATH=references/lc3-python .venv/bin/python scripts/lens-correction/lightroom_fields.py lanes references/lightroom-probe <private-lanes> --lane {number}"
    pass_lines = ["the two exports have one pixel hash", "every crs: and aux: lens field is recorded for each frame",
                  "the red and blue displacement by radius is plotted against the file's curve under both knot placements",
                  "the fitted relation and its residual are printed",
                  "the field at each amount is fitted and one amount law is named, or none fits within 0.15 px rms",
                  "the gain in stops by radius is plotted and one amount law is named, or none fits within 0.02 stop",
                  "the lane records which profile Lightroom chose, or that it chose none and the pixels equal the profile-off export",
                  "the change in channel displacement is plotted with its patch count",
                  "the removed chroma by amount is plotted for the fringe and for the protected patches",
                  "the hue interval that each setting affects is recorded"]
    report = f"# Lane {number}: {'PASS' if passed else 'FAIL'}\n\nPass when {pass_lines[number-1]}.\n\nCommand: `{command}`\n\n```text\n" + "\n".join(lines) + "\n```\n"
    (output / f"lane-{number}.md").write_text(report)
    print(report)
    return passed


def summary(root, output):
    """One row per export, with an off-state reference for the same source.

    Corner gain is the median ratio of four corner pixels. On photographs it
    includes scene changes caused by geometry; only the flat isolates vignetting.
    A missing file curve stays unavailable. Registration residuals accompany the
    comparisons in summary-fields.json, so a poor fit cannot establish parity.
    """
    jobs = json.loads((root / "lc3r2-plan.json").read_text())["jobs"]
    baselines = {}
    for job in jobs:
        folder = root / ("exports-" + job["name"])
        candidates = sorted(folder.glob("*_off.tif"))
        if candidates:
            baselines.setdefault(job["source"], candidates[0])
    cache_path = output / "summary-fields.json"
    cache = json.loads(cache_path.read_text()) if cache_path.exists() else {}
    rows = []
    for job in jobs:
        subject = Path(job["source"]).stem
        if subject == "raw_00_base":
            subject = "fe28-70-control"
        base = baselines.get(job["source"])
        reference = None
        knots = file_curves(Path(job["source"])).get("distortion")
        for path in sorted((root / ("exports-" + job["name"])).glob("*.tif")):
            state = path.stem.split("_")[-1]
            if job["family"] == "profile":
                state = "profile-" + state
            if job["family"] == "ca":
                state = "remove-ca-" + state
            if path.name not in cache:
                value = dict(rms=None, corner=None)
                if base is not None:
                    if reference is None:
                        reference = linear(base)
                    image = reference if path == base else linear(path)
                    ia, ib = [v[[0, 0, -1, -1], [0, -1, 0, -1]] @ probe.PROPHOTO_Y for v in (reference, image)]
                    if np.all((ia > 2 / 65535) & (ib > 2 / 65535) & (ia < 0.999) & (ib < 0.999)):
                        value["corner"] = float(np.median(np.log2(ib / ia)))
                    if knots is not None:
                        displacement_path = output / (path.stem + ".displacement.json")
                        if displacement_path.exists():
                            measured = json.loads(displacement_path.read_text())
                        else:
                            measured = displacement(reference, image, patch=256, step=512)
                        value.update(compare_file(measured["patches"], image.shape, knots))
                        value["registration_fit"] = measured["fit"]
                    del image
                cache[path.name] = value
                save_json(cache_path, cache)
            rms, corner = cache[path.name]["rms"], cache[path.name]["corner"]
            distortion = f"{rms:.4f} px" if rms is not None else "unavailable"
            vignette = f"{corner:+.5f} stop" if corner is not None else "unavailable"
            rows.append(f"{subject} {state} distortion rms {distortion} vs file curve, vignette corner {vignette}")
        del reference
    text = "\n".join(rows) + "\n"
    (output / "summary.txt").write_text(text)
    print(text, end="")


def self_test():
    # Independent known crossings, and a partial repair toward a known mixture.
    d = np.arange(-10, 10.001, 0.05)
    p0 = edge_positions(d, 1 / (1 + np.exp(-d / 2)), 0.5)
    p1 = edge_positions(d, 1 / (1 + np.exp(-(d - 0.37) / 2)), 0.5)
    assert len(p0) == len(p1) == 1 and abs(p1[0] - p0[0] - 0.37) < 0.0001
    dark, bright = np.array([0.2, -0.3, 0.1]), np.array([-0.3, 0.1, 0.2])
    start = np.array([0.4, -0.7, 0.3])
    target = dark * 0.65 + bright * 0.35
    fitted = donor_fit(start, start * 0.2 + target * 0.8, dark, bright)
    assert abs(fitted["bright_share"] - 0.35) < 1e-10 and abs(fitted["travel"] - 1.25) < 1e-10
    assert donor_fit(start, target, dark, dark) is None
    print("PASS edge crossing: known 0.37 px shift; donor ray: known 35% mixture and 80% partial repair; equal donors unidentifiable")
    test_y, test_x = np.mgrid[:800, :800]
    test_d = test_x + 0.5 - 400
    test_a = np.repeat((0.2 + 0.45 / (1 + np.exp(-test_d / 2)))[..., None], 3, axis=-1)
    mask = (test_d >= -8) & (test_d < -2)
    test_a[mask] += np.array([0.02, -0.01, 0.015])
    test_b = test_a.copy()
    test_b[mask] = (test_a[mask] @ np.array([0.28804, 0.71187, 0.00009]))[:, None]
    test_layout = dict(stimuli=[dict(name="known", box=[0, 0, 800, 800], center=[400, 400],
                                   angle_from_vertical=0, line_width_px=None)])
    observed = blurred_response(test_a, test_b, test_layout)[0]
    assert abs(observed["area"]["all"]["fraction_removed"] - 1) < 1e-5
    assert observed["reach_from_edge_px"] == 7.5
    assert max(map(abs, observed["edge_shift_px"])) < 1e-6
    print("PASS blurred-edge reader: full excess removal, native 7.5 px reach, fixed luminance crossing")
    def write(path, rgb):
        h, w = rgb.shape[:2]
        icc = synth_masks.icc_gamma_profile()
        entries = [make_charts.long_(256, w), make_charts.long_(257, h), make_charts.short(258, 16, 16, 16),
                   make_charts.short(259, 1), make_charts.short(262, 2), make_charts.short(277, 3),
                   make_charts.short(284, 1), (34675, 7, len(icc), icc)]
        pixels = np.round(np.clip(rgb, 0, 1) ** (1 / synth_masks.GAMMA) * 65535).astype("<u2")
        path.write_bytes(make_charts.tiff(entries, pixels))

    h, w = 768, 1024
    yy, xx = np.mgrid[:h, :w]
    ux, uy = xx - (w - 1) / 2, yy - (h - 1) / 2
    r = radius((h, w))
    waves = np.random.default_rng(17).uniform(size=(48, 4))

    def texture(x, y):
        value = np.full(x.shape, 0.35)
        for fx, fy, phase, amplitude in waves:
            value += (0.002 + amplitude * 0.004) * np.cos((fx - 0.5) * 0.9 * x + (fy - 0.5) * 0.9 * y + phase * 6.28)
        return value

    with tempfile.TemporaryDirectory(prefix="argent-lc3-self-test-") as temporary:
        folder = Path(temporary)
        base = np.repeat(texture(xx, yy)[..., None], 3, axis=-1)
        shifts = [(0.37, -0.28), (0, 0), (-0.42, 0.23)]
        warped = np.stack([texture(xx - 0.002 * ux * r * r - dx, yy - 0.002 * uy * r * r - dy)
                           for dx, dy in shifts], axis=-1)
        write(folder / "base.tif", base)
        write(folder / "warp.tif", warped)
        measured = displacement(linear(folder / "base.tif"), linear(folder / "warp.tif"), 96, 128, 5)
        errors = []
        for row in measured["patches"]:
            x, y = row["x"] - (w - 1) / 2, row["y"] - (h - 1) / 2
            dx, dy = shifts["RGB".index(row["channel"])]
            errors.append(np.hypot(row["dx"] - (0.002 * x * row["radius"] ** 2 + dx),
                                   row["dy"] - (0.002 * y * row["radius"] ** 2 + dy)))
        assert len(errors) == 8 * 6 * 3 and max(errors) < 0.05, (len(errors), max(errors, default=999))
        assert sum(row["patches"] for row in measured["rings"]) == len(errors)
        for channel, expected in zip("RGB", shifts):
            fitted = measured["fit"][channel]
            assert np.max(np.abs(np.array(fitted["translation_px"]) - expected)) < 0.03
            ts = np.linspace(0, 0.85, 100)
            predicted = sum(c * ts ** j for c, j in zip(fitted["radial_coefficients"], range(0, 8, 2)))
            assert np.max(np.abs((predicted - 0.002 * ts ** 2) * ts * 640)) < 0.03
            assert fitted["rms"] < 0.04
        flat = np.full((h, w, 3), 0.18)
        write(folder / "flat.tif", flat)
        write(folder / "gain.tif", flat * np.exp2(0.7 * r * r)[..., None])
        values = gain(probe.lightroom_luminance(folder / "flat.tif"), probe.lightroom_luminance(folder / "gain.tif"), 5)
        gain_error = max(abs(row["stops"] - float(np.median((0.7 * r * r)[(r >= i / 5) & (r < (i + 1) / 5)])))
                         for i, row in enumerate(values))
        assert gain_error < 0.01, gain_error
        fitted_gain = fit_gain(values)
        assert fitted_gain["rms"] < 0.001
        assert abs(fitted_gain["coefficients_stops"][1] - 0.7) < 0.01
        amounts = [0, 50, 100, 150, 200]
        known = np.array(amounts)[:, None] / 100 * np.array([0.1, 0.4, 0.8])
        assert amount_law(amounts, known, 0.02)["rms"] < 1e-12
        assert amount_law([100] * 5, known, 0.02)["law"] is None
        assert amount_law(amounts, known ** 2, 0.02)["law"] is None
        response = 0.98 * -np.expm1(-(np.array([0, 1, 2, 5, 10, 20]) / 3) ** 2)
        response_fit = fit_defringe_response([0, 1, 2, 5, 10, 20], response)
        assert response_fit["rms"] < 0.002 and abs(response_fit["amplitude"] - 0.98) < 0.01
        t = np.linspace(0, 1, 16)
        info = [1, 0.002, 0, 0]
        relation = distortinfo_relation(0.002 * t ** 2 * 16384, info, 640)
        assert relation["endpoints"]["rms"] < 0.002
        scale = 1.04
        info = [1 / scale, 0.002 / scale ** 3, 0, 0]
        relation = distortinfo_relation(0.002 * t ** 2 * 16384, info, 640)
        assert abs(relation["endpoints"]["scaled_radius"]["scale"] - scale) < 1e-5
        assert relation["endpoints"]["scaled_radius"]["rms"] < 0.002
        # A synthetic forward correspondence generated from the backward file map.
        q = np.array([[100., 100.], [200., 400.], [700., 300.], [900., 600.]])
        v = q - [(w - 1) / 2, (h - 1) / 2]
        ts = np.linalg.norm(v, axis=1) / 640
        knots = 0.002 * t ** 2 * 16384
        p = [(w - 1) / 2, (h - 1) / 2] + v * (1 + curve(knots, ts) / 16384)[:, None] / 1.04
        rows = [dict(channel="G", x=float(a[0]), y=float(a[1]), dx=float(b[0]-a[0]), dy=float(b[1]-a[1])) for a, b in zip(p, q)]
        comparison = compare_file(rows, (h, w), knots)
        assert comparison["rms"] < 1e-10 and abs(comparison["scale"] - 1.04) < 1e-10
        before, layout = charts.fringe(800, 600)
        after = before.copy()
        for region in layout["regions"]:
            if region["kind"] == "fringe":
                x0, y0, x1, y1 = region["box"]
                after[y0:y1, x0:x1] = 0.65
        write(folder / "fringe-a.tif", before)
        write(folder / "fringe-b.tif", after)
        response = defringe(linear(folder / "fringe-a.tif"), linear(folder / "fringe-b.tif"), layout)
        for row in response:
            if row["kind"] == "fringe":
                rgb = 0.65 + np.array(row["rgb_offset"])
                expected = np.linalg.norm(rgb / rgb.mean() - 1)
                assert abs(row["excess_chroma_removed"] - expected) < 0.001
                assert abs(row["area_fraction_removed"] - 1) < 0.001
            else:
                assert row["rgb_change_norm"] < 1e-6 and abs(row["chroma_change"]) < 1e-6
        # A wrapping hue interval and a width cutoff must both be recovered,
        # including negative controls at the same hue with a wider fringe.
        selective = before.copy()
        for region in layout["regions"]:
            if (region["kind"] == "fringe" and
                    (region["hue_degrees"] >= 330 or region["hue_degrees"] <= 190) and
                    region["fringe_width_px"] <= 6):
                x0, y0, x1, y1 = region["box"]
                selective[y0:y1, x0:x1] = 0.65
        write(folder / "fringe-selective.tif", selective)
        response = defringe(linear(folder / "fringe-a.tif"), linear(folder / "fringe-selective.tif"), layout)
        recovered = set()
        for row in response:
            hue, size = row["hue_degrees"], row["fringe_width_px"]
            removed = row["kind"] == "fringe" and (hue >= 330 or hue <= 190) and size <= 6
            if row["kind"] == "fringe":
                rgb = 0.65 + np.array(row["rgb_offset"])
                expected = np.linalg.norm(rgb / rgb.mean() - 1) if removed else 0
                assert abs(row["excess_chroma_removed"] - expected) < 0.001, row
                if row["excess_chroma_removed"] > 0.01:
                    recovered.add((hue, size))
            else:
                assert abs(row["chroma_removed"]) < 1e-6 and row["rgb_change_norm"] < 1e-6
        assert {hue for hue, _ in recovered} == set(range(0, 191, 10)) | {330, 340, 350}
        assert {size for _, size in recovered} == {2, 6}
        interval = hue_response(response)
        assert interval["intervals"] == [dict(start_bracket=[320, 330], end_bracket=[190, 200])], interval
        for hue in (0, 180):
            assert {size for angle, size in recovered if angle == hue} == {2, 6}
        assert phase_shift(np.ones((32, 32)), np.ones((32, 32))) is None
        print(f"PASS radial warp + channel shifts: {len(errors)} patches, max error {max(errors):.5f} px")
        print(f"PASS radial gain: {len(values)} rings, max error {gain_error:.6f} stop; defringe and protected colours")
        print("PASS defringe selectivity: hue interval 330 through 190 degrees, widths <= 6 px; protected colours unchanged")
        # Independent synthetic source map: K(r)=1+0.10*r^2. Generate
        # correspondences by a dense inverse, rather than the tested inverter.
        yy0, xx0 = np.mgrid[-2100:2101:300, -3300:3301:300]
        source = np.stack([xx0.ravel(), yy0.ravel()], axis=1).astype(float)
        rm = np.hypot(7008, 4672) / 2
        xx1 = np.linspace(0, 2, 500001)
        generated = []
        for alpha in np.arange(5) / 2:
            sc = 1.0
            for _ in range(100):
                sc = 1 + alpha * 0.10 / sc**2
            rr = np.linalg.norm(source, axis=1) / rm
            radii = np.interp(rr, xx1 * (1 + alpha * 0.10 * xx1**2), xx1)
            generated.append(source * (sc * radii / np.maximum(rr, 1e-30))[:, None])
        laws = distortion_laws(source, np.array(generated), (4672, 7008))["laws"]
        assert laws["scaled-radius"]["non_anchor"]["rms"] < 1e-6, laws
        assert laws["same-radius"]["non_anchor"]["rms"] > 1, laws
        print("PASS scaled-radius amount law recovered; same-radius law rejected with fixed border framing")
        # Render an analytic texture through a known framed map, then register
        # the TIFFs just like natural exports. No file curve guides registration.
        sh, sw = 1792, 2304
        sy, sx = np.mgrid[:sh, :sw]
        vx, vy = sx - (sw - 1) / 2, sy - (sh - 1) / 2
        st = np.hypot(vx, vy) / (np.hypot(sw, sh) / 2)
        paths = []
        for amount in (0, 50, 100, 150, 200):
            factor = 1 + amount / 100 * (-0.06 + 0.06 * st**2)
            image = texture(((sw - 1) / 2 + vx * factor) / 16, ((sh - 1) / 2 + vy * factor) / 16)
            path = folder / f"linear-{amount}.tif"
            write(path, np.repeat(image[..., None], 3, axis=-1))
            paths.append(path)
        sp, sq, registration = sweep_points(paths)
        rr = np.linalg.norm(sp, axis=1) / (np.hypot(sw, sh) / 2)
        dense = np.linspace(0, 1.6, 200001)
        for amount, observed in zip((0, 50, 100, 150, 200), sq):
            mapped = dense * (1 + amount / 100 * (-0.06 + 0.06 * dense**2))
            expected = sp * (np.interp(rr, mapped, dense) / rr)[:, None]
            assert residual(np.linalg.norm(observed - expected, axis=1))["rms"] < 0.05
        recovered = distortion_laws(sp, sq, (sh, sw))["laws"]
        assert registration["common_points"] >= 10, registration
        assert recovered["linear-displacement"]["non_anchor"]["rms"] < 0.15, recovered
        assert all(row["rms"] > 0.15 for row in recovered["scaled-radius"]["by_amount"] if row["amount"] in (50, 150))
        print("PASS rendered linear-displacement sweep recovered by free registration; scaled-radius law rejected")
        print("PASS per-channel radial fit, stop fit, amount-law identification and collapsed-sweep rejection, aux polynomial relation")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true")
    sub = parser.add_subparsers(dest="command")
    sub.add_parser("xmp").add_argument("a", type=Path)
    for name in ("lanes", "summary"):
        command = sub.add_parser(name)
        command.add_argument("root", type=Path)
        command.add_argument("output", type=Path)
        if name == "lanes":
            command.add_argument("--lane", type=int, choices=range(1, 11), required=True)
    for name in ("displacement", "gain", "defringe"):
        command = sub.add_parser(name)
        command.add_argument("a", type=Path)
        command.add_argument("b", type=Path)
        command.add_argument("--rings", type=int, default=10)
        command.add_argument("--patch", type=int, default=256)
        command.add_argument("--step", type=int, default=256)
        command.add_argument("--layout", type=Path, required=name == "defringe")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if not args.command:
        parser.error("choose a measurement or --self-test")
    if args.command == "lanes":
        raise SystemExit(0 if lane(args.root, args.output, args.lane) else 1)
    if args.command == "summary":
        summary(args.root, args.output)
        return
    if args.command == "xmp":
        result = xmp(args.a)
    else:
        if args.rings < 1 or args.patch < 16 or args.step < 1:
            parser.error("require positive rings/step and patch >= 16")
        if args.command == "gain":
            result = gain(probe.lightroom_luminance(args.a), probe.lightroom_luminance(args.b), args.rings)
        else:
            a, b = linear(args.a), linear(args.b)
            result = (displacement(a, b, args.patch, args.step, args.rings) if args.command == "displacement" else
                      defringe(a, b, json.loads(args.layout.read_text())))
    print(json.dumps(result, indent=2, allow_nan=False))


if __name__ == "__main__":
    main()
