import argparse
import sys
from importlib.resources import as_file, files
from pathlib import Path

STOCKS_DIR = files("argent_bake").joinpath("stocks")
if not STOCKS_DIR.is_dir():
    STOCKS_DIR = Path(__file__).resolve().parents[1] / "stocks"


def _size(value: str) -> int:
    size = int(value)
    if not 2 <= size <= 128:
        raise argparse.ArgumentTypeError("size must be 2...128")
    return size


def _bake_one(profile, out_dir, size: int) -> int:
    """Bake one loaded profile into `out_dir`, printing what the bake found. Returns the exit code.

    The gates run first, the same ones `check` prints, and a profile that fails one is not
    baked: a stock that misses its own sheet must not reach the app.
    """
    from .bake import bake_stock, paper_named
    from .negative import check_gates
    from .printing import CalibrationError

    failed = [gate for gate in check_gates(profile) if not gate.passed]
    if failed:
        for gate in failed:
            print(f"error: {profile.id}: gate {gate.name} fails: {gate.detail}", file=sys.stderr)
        print(f"error: {profile.id} not baked; run check for every gate", file=sys.stderr)
        return 2
    try:
        result = bake_stock(profile, paper_named(profile.paper), out_dir, size)
    except (CalibrationError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    print(f"wrote {result.directory} (negative and print {result.size}^3, density range {result.density_range})")
    print("daylight filtration, log10 exposure: " + " ".join(f"{v:.3f}" for v in result.filtration))
    print("paper exposure per unit dye, log10: " + " ".join(f"{v:.3f}" for v in result.exposure_per_unit))
    if profile.status == "approximation":
        print('note: stock status is "approximation": uses proxy data and is not fitted to scans')
    elif profile.status != "fitted":
        print(f'note: stock status is "{profile.status}": it exercises the pipeline and is not a look')
    return 0


def _bake_neutral(out_dir, size: int) -> int:
    from .neutral import bake_neutral

    try:
        result = bake_neutral(out_dir, size)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    print(f"wrote {result.directory} (negative and print {result.size}^3, density range {result.density_range})")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="argent-bake", description="Bake Argent stock LUTs.")
    sub = parser.add_subparsers(dest="command", required=True)

    bake = sub.add_parser("bake", help="bake a stock profile into a folder the app loads")
    source = bake.add_mutually_exclusive_group(required=True)
    source.add_argument("--profile", help="stock profile JSON, for example stocks/portra400.json")
    source.add_argument("--neutral", action="store_true",
                        help="bake the Neutral digital stock (camera colour with pleasing tone curve)")
    source.add_argument("--synthetic", action="store_true",
                        help="bake the synthetic stock, which exercises the pipeline and is not a look")
    source.add_argument("--all", action="store_true",
                        help="bake every profile, its print variants, and Neutral into OUT/<id>/")
    bake.add_argument("--print-variant", help="bake this print variant id instead of the default --profile")
    bake.add_argument("--size", type=_size, default=65, help="LUT size per axis (default: 65)")
    bake.add_argument("--out", required=True, help="output folder")

    check = sub.add_parser("check", help="print a profile's gates against its datasheet and exit non-zero if one fails")
    check.add_argument("--profile", required=True, help="stock profile JSON")

    args = parser.parse_args(argv)
    from . import neutral, synthetic
    from .profile import ProfileError, load_profile

    if args.command == "bake":
        if args.print_variant is not None and not args.profile:
            bake.error("--print-variant requires --profile")
        if args.neutral:
            return _bake_neutral(args.out, args.size)
        if args.all:
            paths = sorted((p for p in STOCKS_DIR.iterdir() if p.name.endswith(".json") and p.is_file()),
                           key=lambda p: p.name) if STOCKS_DIR.is_dir() else []
            if not paths:
                print(f"error: no profiles in {STOCKS_DIR}", file=sys.stderr)
                return 2
            failures = 0
            baked_ids = {neutral.STOCK_ID}
            failures += _bake_neutral(Path(args.out) / neutral.STOCK_ID, args.size) != 0
            for path in paths:
                try:
                    with as_file(path) as profile_path:
                        profile = load_profile(profile_path)
                except ProfileError as error:
                    print(f"error: {error}", file=sys.stderr)
                    failures += 1
                    continue
                for stock in (profile, *map(profile.with_print_variant, profile.print_variants)):
                    if stock.id in baked_ids:
                        print(f"error: duplicate stock id {stock.id}", file=sys.stderr)
                        failures += 1
                        continue
                    baked_ids.add(stock.id)
                    failures += _bake_one(stock, Path(args.out) / stock.id, args.size) != 0
            return 2 if failures else 0
        try:
            profile = synthetic.profile() if args.synthetic else load_profile(args.profile)
            if args.print_variant is not None:
                matching = next((v for v in profile.print_variants if v.id == args.print_variant), None)
                if matching is None:
                    raise ProfileError(f"profile {profile.id}: no print variant {args.print_variant!r}")
                profile = profile.with_print_variant(matching)
        except ProfileError as error:
            print(f"error: {error}", file=sys.stderr)
            return 2
        return _bake_one(profile, args.out, args.size)

    if args.command == "check":
        from .negative import check_gates

        try:
            profile = load_profile(args.profile)
        except ProfileError as error:
            print(f"error: {error}", file=sys.stderr)
            return 2
        after = f", after {profile.modelled_film}" if profile.modelled_film else ""
        print(f"{profile.id} ({profile.display_name}{after}, status {profile.status}, box speed {profile.box_speed:.0f})")
        failed = 0
        for gate in check_gates(profile):
            print(f"  {'pass' if gate.passed else 'FAIL'}  {gate.name}: {gate.detail}")
            failed += not gate.passed
        print("all negative gates pass" if not failed else f"{failed} negative gate(s) fail")
        if profile.paper:
            from .print_checks import REFERENCE, check_stock, setup_for
            from .print_tone import print_tone, report_lines

            try:
                setup = setup_for(profile)
                figure = REFERENCE.get(profile.id, ("FIG. 2", ""))[0]
                for line in report_lines(print_tone(profile, None, setup.stage, figure)):
                    print(line)
                if profile.id in REFERENCE:
                    print(f"print stage acceptance checks (advisory; do not affect exit status), {setup.label} (print.md section 3):")
                    for item in check_stock(profile, setup):
                        state = "report" if item.passed is None else ("pass" if item.passed else "FAIL")
                        print(f"  {state:6s}{item.name}: {item.detail}")
            except ValueError as error:  # a paper the bake does not know: nothing to report
                print(f"print tone: not reported ({error})")
        return 0 if not failed else 1
    return 1


if __name__ == "__main__":
    sys.exit(main())
