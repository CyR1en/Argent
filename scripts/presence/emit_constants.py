"""Writes one version of Presence's constants as Swift, from that version's inputs in scripts/presence/<version>/.

    python3 -I scripts/presence/emit_constants.py 2026-11-11-1 > Sources/ArgentCore/Film/PresenceConstants+2026-11-11-1.swift

The inputs are the fits' constants.json files, copied unchanged from the evidence folder's fit/ (texture-clarity.json for
Texture, clarity-round2.json for Clarity, dehaze.json, colour.json), and method.json for what they do not hold. Every number
the stages read comes from them; the colour matrices are derived here from the spaces method.json copies from fit_colour.py.
Plain Python with no numpy, so any python3 writes the same bytes: PresenceConstantsTests runs this again and compares.
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def matmul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)] for i in range(3)]


def inverse(m):
    (a, b, c), (d, e, f), (g, h, i) = m
    det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    adjugate = [[e * i - f * h, c * h - b * i, b * f - c * e],
                [f * g - d * i, a * i - c * g, c * d - a * f],
                [d * h - e * g, b * g - a * h, a * e - b * d]]
    return [[x / det for x in row] for row in adjugate]


def apply(m, v):
    return [sum(m[i][k] * v[k] for k in range(3)) for i in range(3)]


def bradford(spaces, src, dst):
    """fit_colour.py's bradford: inv(B) diag((B dst) / (B src)) B."""
    b = spaces["bradford"]
    s, t = apply(b, spaces[src]), apply(b, spaces[dst])
    return matmul(inverse(b), matmul([[t[i] / s[i] if i == j else 0.0 for j in range(3)] for i in range(3)], b))


def f(x):
    text = f"{float(x):.9g}"
    return "0" if text == "-0" else text


def vector(xs):
    return "SIMD3(" + ", ".join(f(x) for x in xs) + ")"


def floats(xs):
    return "[" + ", ".join(f(x) for x in xs) + "]"


def matrix(m):
    return f"Matrix3(r0: {vector(m[0])}, r1: {vector(m[1])}, r2: {vector(m[2])})"


def law(magnitudes, values):
    assert len(magnitudes) == len(values) and magnitudes[0] == 0 and magnitudes[-1] == 100, "a law spans 0 to 100"
    assert all(a < b for a, b in zip(magnitudes, magnitudes[1:])), "a law's magnitudes rise"
    return f"Law(magnitudes: {floats(magnitudes)}, values: {floats(values)})"


def detail_side(side):
    """F1's side: k at |v| 25, 50, 75 and 100, 0 at 0 (fit_texture_clarity.py strength), and m at L* 0, 10, ..., 100."""
    assert len(side["law"]) == 4 and len(side["weight"]) == 11
    return (f"DetailSide(strength: {law([0, 25, 50, 75, 100], [0, *side['law']])},\n"
            f"                                    weight: ToneWeight(values: {floats(side['weight'])}))")


def tone_base(radius, epsilon, field, share):
    return (f"ToneBaseParameters(radiusFraction: {f(radius)}, epsilon: {f(epsilon)}, fieldLongSide: {int(field)}, "
            f"coefficientRadiusShare: {f(share)})")


def value_term(q):
    return (f"Vibrance.ValueTerm(b1: {f(q['b1'])}, b2: {f(q['b2'])}, alpha: {f(q['alpha'])}, beta: {f(q['beta'])}, "
            f"lv: {f(q['lv'])}, sv: {f(q['sv'])})")


def strength(s):
    return f"Vibrance.Strength(positive: {f(s['positive'])}, negative: {f(s['negative'])})"


def main(version):
    folder = HERE / version
    read = lambda name: json.loads((folder / name).read_text())  # noqa: E731
    texture = read("texture-clarity.json")["candidates"]["texture-guided-band"]
    clarity = read("clarity-round2.json")["recommendation"]["clarity-guided"]
    dehaze = read("dehaze.json")["candidates"]["dark-channel"]["constants"]
    colour = read("colour.json")
    method = read("method.json")

    tp, tn = texture["positive"]["params"], texture["negative"]["params"]
    assert texture["positive"]["detail"] == "band" and tp == tn, "Texture is one band for both signs"
    cp, cn = clarity["positive"]["params"], clarity["negative"]["params"]
    assert clarity["positive"]["detail"] == clarity["negative"]["detail"] == "guided"
    assert dehaze["method"] == "dark-channel" and dehaze["positive_law"] == "beer-lambert" \
        and dehaze["negative_law"] == "crossfade" and not dehaze["opening"] \
        and dehaze.get("negative_space", "linear") == "linear", "the stage's form is F2's recommended one"
    hsv = colour["vibrance"]["constants"]["hsv"]
    pos, neg = hsv["pos"], hsv["neg"]

    spaces = method["colourSpaces"]
    rec2020_to_xyz50 = matmul(bradford(spaces, "d65", "d50"), spaces["rec2020ToXYZ65"])
    prophoto_to_rec2020 = matmul(inverse(rec2020_to_xyz50), spaces["proPhotoToXYZ"])
    rec2020_to_prophoto = inverse(prophoto_to_rec2020)
    lms = matmul(spaces["oklabM1"], matmul(bradford(spaces, "d50", "d65"), spaces["proPhotoToXYZ"]))
    lms = [[x / sum(row) for x in row] for row in lms]

    vib = method["vibrance"]
    strengths = vib["strength"]
    stocks = ", ".join(f'"{name}": {strength(s)}' for name, s in sorted(strengths["stocks"].items())) or ":"
    fade = method["dehaze"]
    name = "v" + version.replace("-", "_")
    print(f"""// Generated by scripts/presence/emit_constants.py from scripts/presence/{version}/. Change the inputs and run it again.
extension PresenceConstants {{
    static let {name} = PresenceConstants(
        version: "{version}",
        source: "scripts/presence/{version}: texture-clarity.json texture-guided-band (F1), clarity-round2.json clarity-guided (F1b), "
            + "dehaze.json dark-channel (F2), colour.json S-A and V-A hsv (F3), method.json",
        texture: Texture(radiusFramePixels: {f(tp['radius_px'])}, epsilon: {f(tp['epsilon'])},
                         coefficientRadiusShare: {f(tp.get('share', method['texture']['coefficientRadiusShare']))},
                         fieldShare: {f(tp['field_scale'])}, minimumFieldLongSide: {int(method['texture']['minimumFieldLongSide'])},
                         positive: {detail_side(texture['positive'])},
                         negative: {detail_side(texture['negative'])}),
        clarity: Clarity(positiveField: {tone_base(cp['radius'], cp['epsilon'], cp['field'], cp.get('share', method['clarity']['coefficientRadiusShare']))},
                         negativeField: {tone_base(cn['radius'], cn['epsilon'], cn['field'], cn.get('share', method['clarity']['coefficientRadiusShare']))},
                         positive: {detail_side(clarity['positive'])},
                         negative: {detail_side(clarity['negative'])}),
        dehaze: Dehaze(fieldLongSide: {int(dehaze['long_side'])}, omega: {f(dehaze['omega'])},
                       airlightRadius: {f(dehaze['airlight_radius'])}, airlightQuantile: {f(dehaze['airlight_quantile'])},
                       airlightBrightShare: {f(dehaze['airlight_bright'])}, darkRadius: {f(dehaze['dark_radius'])},
                       guide: {tone_base(dehaze['guide_radius'], dehaze['epsilon'], dehaze['long_side'], fade['coefficientRadiusShare'])},
                       minimumTransmission: {f(dehaze['t_min'])},
                       fade: {f"Dehaze.Fade(startRatio: {f(fade['fadeStartRatio'])}, endRatio: {f(fade['fadeEndRatio'])})" if dehaze['fade'] else 'nil'},
                       kappa: {law(dehaze['kappa_values'], dehaze['kappa'])},
                       hazeShare: {law(dehaze['haze_values'], dehaze['haze_share'])},
                       hazePower: {law(dehaze['haze_values'], dehaze['haze_power'])}),
        saturation: Saturation(luma: {vector(colour['saturation']['lumaRec2020'])}),
        vibrance: Vibrance(toProPhoto: {matrix(rec2020_to_prophoto)},
                           fromProPhoto: {matrix(prophoto_to_rec2020)},
                           proPhotoToLMS: {matrix(lms)},
                           oklabA: {vector(spaces['oklabM2'][1])}, oklabB: {vector(spaces['oklabM2'][2])},
                           proPhotoLuma: {vector(spaces['proPhotoToXYZ'][1])}, lightnessReference: {f(vib['lightnessReference'])},
                           saturationKnee: {f(hsv['sknee'])},
                           positive: .init(a1: {f(pos['a1'])}, a2: {f(pos['a2'])}, a3: {f(pos.get('a3', 0))},
                                           x0: {f(pos['x0'])}, x0v: {f(pos['x0v'])}, minimumFallOff: {f(vib['minimumFallOff'])},
                                           d: {f(pos['d'])}, hueCentre: {f(pos['hc'])}, hueWidth: {f(pos['hw'])},
                                           l0: {f(pos['l0'])}, sigma: {f(pos['sigma'])},
                                           value: {value_term(pos)}),
                           negative: .init(c: {f(neg['c'])}, q: {f(neg['q'])}, kappa: {f(neg['kappa'])},
                                           value: {value_term(neg)}),
                           strengths: [{stocks}], defaultStrength: {strength(strengths['default'])}),
        detailLimitStops: {f(method['detail']['limitStops'])})
}}""")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
