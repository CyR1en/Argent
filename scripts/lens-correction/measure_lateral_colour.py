#!/usr/bin/env python3
"""Measure R/G and B/G radial edge offsets in paired --scene-out arrays.

Uses the inverse of InHouseColor.cameraToWorking. Selects distributed strong,
radially facing green edges in the outer half of the field from the off image.
Reports the same edges in both images; no correction coefficients are fitted.
Only NumPy is required. Inputs stay outside the repository.
"""
import argparse
import json
from pathlib import Path

import numpy as np


TO_WORKING = np.array([[1.121206, .023553, -.146545],
                       [-.042143, 1.481152, -.440795],
                       [.005260, -.238506, 1.231460]], dtype=np.float32)
TO_CAMERA = np.linalg.inv(TO_WORKING)
POSITIONS = np.arange(-16, 16.01, .5)
SHIFTS = np.arange(-8, 8.001, .05)
CENTRAL = (POSITIONS >= -8) & (POSITIONS <= 8)


def sample(image, x, y):
    """Bilinear taps, with all coordinates already inside the image."""
    ix, iy = np.floor(x).astype(int), np.floor(y).astype(int)
    fx, fy = (x - ix)[..., None], (y - iy)[..., None]
    return ((image[iy, ix] * (1 - fx) + image[iy, ix + 1] * fx) * (1 - fy)
            + (image[iy + 1, ix] * (1 - fx) + image[iy + 1, ix + 1] * fx) * fy)


def edges(camera):
    h, w = camera.shape[:2]
    g = camera[..., 1]
    found = []
    # One strongest radial edge per 48-pixel tile prevents one object dominating.
    for y in range(32, h - 64, 48):
        for x in range(32, w - 64, 48):
            yy, xx = np.mgrid[y:y+48, x:x+48]
            rx, ry = xx - (w - 1) / 2, yy - (h - 1) / 2
            radius = np.hypot(rx, ry)
            t = radius / (np.hypot(w, h) / 2)
            gx = (g[yy, xx + 1] - g[yy, xx - 1]) / 2
            gy = (g[yy + 1, xx] - g[yy - 1, xx]) / 2
            magnitude = np.hypot(gx, gy)
            radial = np.abs(gx * rx + gy * ry) / np.maximum(radius, 1)
            valid = ((t >= .5) & (t <= .95) & (radial > .8 * magnitude)
                     & (g[yy, xx] > .015) & (g[yy, xx] < 1.5))
            score = np.where(valid, magnitude, 0)
            i = np.unravel_index(np.argmax(score), score.shape)
            if score[i] >= .01:
                found.append((float(xx[i]), float(yy[i])))
    return np.array(found)


def profiles(camera, points):
    h, w = camera.shape[:2]
    radial = points - np.array([(w - 1) / 2, (h - 1) / 2])
    radial /= np.linalg.norm(radial, axis=1)[:, None]
    x = points[:, 0, None] + radial[:, 0, None] * POSITIONS
    y = points[:, 1, None] + radial[:, 1, None] * POSITIONS
    result = np.zeros((*x.shape, 3))
    for tangent in [-2, -1, 0, 1, 2]:
        result += sample(camera, x - tangent * radial[:, 1, None],
                         y + tangent * radial[:, 0, None]) / 5
    return result


def offsets(profile):
    target = profile[:, CENTRAL, 1]
    target = target - target.mean(axis=1, keepdims=True)
    target /= np.maximum(np.linalg.norm(target, axis=1, keepdims=True), 1e-12)
    offsets, correlations = [], []
    for channel in [0, 2]:
        scores = []
        for shift in SHIFTS:
            position = (POSITIONS[CENTRAL] + shift - POSITIONS[0]) / .5
            index = np.minimum(position.astype(int), len(POSITIONS) - 2)
            fraction = position - index
            moved = (profile[:, index, channel] * (1 - fraction)
                     + profile[:, index + 1, channel] * fraction)
            moved -= moved.mean(axis=1, keepdims=True)
            moved /= np.maximum(np.linalg.norm(moved, axis=1, keepdims=True), 1e-12)
            scores.append(np.sum(moved * target, axis=1))
        scores = np.array(scores).T
        best = scores.argmax(axis=1)
        # Parabolic refinement of the correlation peak, below the 0.05 px grid.
        index = np.clip(best, 1, len(SHIFTS) - 2)
        row = np.arange(len(index))
        a, b, c = scores[row, index-1], scores[row, index], scores[row, index+1]
        denominator = a - 2*b + c
        delta = np.divide(.5 * (a - c), denominator, out=np.zeros_like(a), where=denominator != 0)
        offsets.append(SHIFTS[index] + np.clip(delta, -1, 1) * .05)
        correlations.append(scores[row, best])
    return np.array(offsets).T, np.array(correlations).T


def measure(off_path, on_path):
    off = np.load(off_path, mmap_mode='r')
    on = np.load(on_path, mmap_mode='r')
    if off.shape != on.shape:
        raise ValueError('paired arrays must have the same shape')
    camera = np.asarray(off) @ TO_CAMERA.T
    points = edges(camera)
    if len(points) == 0:
        raise ValueError('no measurable outer-field edges')
    before = profiles(camera, points)
    del camera
    camera = np.asarray(on) @ TO_CAMERA.T
    after = profiles(camera, points)
    del camera
    a, ac = offsets(before)
    b, bc = offsets(after)
    green = before[..., 1]
    differences = np.diff(green[:, CENTRAL], axis=1)
    monotonic = np.abs(differences.sum(axis=1)) / np.maximum(np.abs(differences).sum(axis=1), 1e-12)
    contrast = np.ptp(green[:, CENTRAL], axis=1)
    valid = ((monotonic > .8) & (contrast > .04)
             & (np.min(ac, axis=1) > .98) & (np.min(bc, axis=1) > .98)
             & (np.max(np.abs(a), axis=1) < 7.5) & (np.max(np.abs(b), axis=1) < 7.5))
    if valid.sum() < 20:
        raise ValueError(f'only {valid.sum()} usable edges; need 20')
    result = {'edges': int(valid.sum()), 'candidates': len(points), 'channels': {}}
    for channel, name in enumerate(['red', 'blue']):
        result['channels'][name] = {
            state: {'signed_median_px': float(np.median(values[valid, channel])),
                    'median_px': float(np.median(np.abs(values[valid, channel]))),
                    'p95_px': float(np.percentile(np.abs(values[valid, channel]), 95))}
            for state, values in [('off', a), ('on', b)]}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--off', type=Path, required=True)
    parser.add_argument('--on', type=Path, required=True)
    parser.add_argument('--label', required=True, help='lens name, without a private file name')
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    result = {'lens': args.label, **measure(args.off, args.on)}
    args.out.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
