"""ACES Reference Gamut Compression v1.0 with Argent's colorimetric limits.

The curve is from Academy Software Foundation aces-dev,
transforms/ctl/lmt/LMT.Academy.ReferenceGamutCompress.ctl (v1.0):
https://github.com/ampas/aces-dev/blob/v1.3/transforms/ctl/lmt/LMT.Academy.ReferenceGamutCompress.ctl
Argent uses a 0.90 threshold and limits derived from the CIE 1931 spectral
boundary in scene-linear Rec.2020, not the ACES thresholds or camera limits.
"""

import numpy as np

from .spectral import cie_1931, rgb_to_xyz_matrix

THRESHOLD = (0.90, 0.90, 0.90)
POWER = 1.2
LIMIT_MARGIN = 1e-4
LIMITS = (1.3964, 1.1686, 1.0246)
RGB_TO_XYZ = rgb_to_xyz_matrix()
XYZ_TO_RGB = np.linalg.inv(RGB_TO_XYZ)


def compress(rgb, threshold=THRESHOLD, limit=LIMITS, power=POWER):
    """Compress distances from max(R,G,B), preserving nonpositive pixels.

    RGB has a final axis of length three; thresholds and limits broadcast over
    it. In-threshold components are returned without arithmetic changes.
    """
    rgb = np.asarray(rgb)
    threshold, limit = np.asarray(threshold), np.asarray(limit)
    if rgb.ndim == 0 or rgb.shape[-1] != 3:
        raise ValueError("RGB must have a final axis of length three")
    if not np.isfinite(power) or power <= 0:
        raise ValueError("power must be finite and positive")
    if (np.any(~np.isfinite(threshold)) or np.any(~np.isfinite(limit))
            or np.any(threshold < 0) or np.any(threshold >= 1)
            or np.any(limit <= 1) or np.any(limit <= threshold)):
        raise ValueError("require finite 0 <= threshold < 1 < limit")
    ach = np.max(rgb, axis=-1, keepdims=True)
    magnitude = np.where(ach > 0, np.abs(ach), 1)
    distance = (ach - rgb) / magnitude
    scale = (limit - threshold) / (
        ((1 - threshold) / (limit - threshold)) ** (-power) - 1) ** (1 / power)
    nd = np.maximum(distance - threshold, 0) / scale
    cd = threshold + scale * nd / (1 + nd ** power) ** (1 / power)
    result = np.where((ach > 0) & (distance > threshold), ach - cd * magnitude, rgb)
    return result.astype(rgb.dtype) if np.issubdtype(rgb.dtype, np.floating) else result


def limits_for():
    """Derive channel-distance maxima, including max-channel edge crossings.

    A distance is linear-fractional wherever the maximum channel is fixed,
    so extrema on an edge occur at its endpoints or channel crossings. The
    final spectral edge is the line of purples. Values <= threshold are raised
    to threshold + LIMIT_MARGIN; the scene limits do not need this guard.
    """
    xyz = cie_1931()
    xyz = xyz / xyz.sum(axis=-1, keepdims=True)
    vertices = xyz @ XYZ_TO_RGB.T
    candidates = [*vertices]
    for a, b in zip(vertices, np.roll(vertices, -1, axis=0)):
        for i, j in ((0, 1), (0, 2), (1, 2)):
            start, end = a[i] - a[j], b[i] - b[j]
            if start != end:
                fraction = start / (start - end)
                if 0 < fraction < 1:
                    candidates.append(a + fraction * (b - a))
    rgb = np.asarray(candidates)
    ach = rgb.max(axis=-1, keepdims=True)
    limits = np.max((ach - rgb) / np.abs(ach), axis=0)
    return np.where(limits <= THRESHOLD, np.asarray(THRESHOLD) + LIMIT_MARGIN, limits)
