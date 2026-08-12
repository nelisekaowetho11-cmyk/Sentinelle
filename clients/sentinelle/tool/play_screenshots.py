"""Turns raw phone screenshots into Play-compliant store screenshots.

Google Play wants phone screenshots at exactly 16:9 or 9:16, PNG or JPEG, each
side between 320 and 3840 px, under 8 MB. A modern phone shoots about 9:20, so
a raw screenshot is rejected on aspect ratio alone.

    python tool/play_screenshots.py <input-folder> [-o <output-folder>]

Two ways to reach 9:16, and the default is the safe one:

  contain (default)  Fit the whole screenshot inside the frame and pad the
                     sides. Nothing is lost. The pad colour is sampled from the
                     screenshot's own edge, so on a dark app like this one the
                     padding is invisible and the result reads as a normal shot.

  cover              Fill the frame and crop the overflow. Looks tighter, but
                     on a 9:20 source it eats roughly 240 px from the top and
                     240 px from the bottom -- which on this app is the status
                     bar and the whole Connect/Locations/Accounts tab bar. Use
                     it only after checking what it removes.

Requires Pillow:  pip install pillow
"""

import argparse
import sys
from collections import Counter
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow is not installed. Run:  pip install pillow")

SUFFIXES = {".png", ".jpg", ".jpeg"}
MAX_BYTES = 8 * 1024 * 1024


def edge_colour(img):
    """The most common colour around the border, for padding that disappears."""
    w, h = img.size
    px = img.convert("RGB").load()
    step = max(1, w // 64)
    samples = Counter()
    for x in range(0, w, step):
        samples[px[x, 0]] += 1
        samples[px[x, h - 1]] += 1
    for y in range(0, h, max(1, h // 64)):
        samples[px[0, y]] += 1
        samples[px[w - 1, y]] += 1
    return samples.most_common(1)[0][0]


def convert(src, dst, target, mode):
    img = Image.open(src)
    img = img.convert("RGB") if img.mode not in ("RGB", "RGBA") else img
    tw, th = target
    sw, sh = img.size

    if mode == "cover":
        k = max(tw / sw, th / sh)
        scaled = img.resize((round(sw * k), round(sh * k)), Image.LANCZOS)
        left = (scaled.width - tw) // 2
        top = (scaled.height - th) // 2
        out = scaled.crop((left, top, left + tw, top + th))
        note = f"cropped {scaled.height - th}px vertically"
    else:
        k = min(tw / sw, th / sh)
        scaled = img.resize((round(sw * k), round(sh * k)), Image.LANCZOS)
        out = Image.new("RGB", (tw, th), edge_colour(img))
        out.paste(scaled, ((tw - scaled.width) // 2, (th - scaled.height) // 2))
        pad = (tw - scaled.width) // 2
        note = f"padded {pad}px each side" if pad else "no padding needed"

    out.save(dst, "PNG", optimize=True)
    size = dst.stat().st_size
    if size > MAX_BYTES:  # never hit at 1080x1920, but the limit is real
        dst = dst.with_suffix(".jpg")
        out.save(dst, "JPEG", quality=92, optimize=True)
        size = dst.stat().st_size
        note += ", re-encoded as JPEG to fit 8 MB"
    return f"{sw}x{sh} -> {tw}x{th}  ({note}, {size / 1024:.0f} KB)"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", type=Path, help="folder of raw screenshots")
    ap.add_argument("-o", "--output", type=Path, default=None)
    ap.add_argument("--mode", choices=("contain", "cover"), default="contain")
    ap.add_argument("--width", type=int, default=1080)
    ap.add_argument("--height", type=int, default=1920)
    args = ap.parse_args()

    if not args.input.is_dir():
        sys.exit(f"Not a folder: {args.input}")
    out_dir = args.output or args.input / "play"
    out_dir.mkdir(parents=True, exist_ok=True)

    files = sorted(p for p in args.input.iterdir() if p.suffix.lower() in SUFFIXES)
    if not files:
        sys.exit(f"No PNG or JPEG files in {args.input}")
    if len(files) > 8:
        print(f"note: Play accepts at most 8 phone screenshots; found {len(files)}")

    for i, src in enumerate(files, 1):
        # Landscape sources get 16:9 instead, so a tablet shot is not squashed.
        w, h = Image.open(src).size
        target = (args.width, args.height) if h >= w else (args.height, args.width)
        dst = out_dir / f"{i:02d}-{src.stem}.png"
        print(f"{src.name:<34} {convert(src, dst, target, args.mode)}")

    print(f"\n{len(files)} written to {out_dir}")
    print("Upload these, in this order — the numbering is the order Play shows them.")


if __name__ == "__main__":
    main()
