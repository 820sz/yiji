#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Pack the dafeiyu meme library into Android-ready WebP assets.

Reads the source library (SQLite index + image files) read-only, writes
compressed WebP files plus ``index.json`` under ``assets/memes/``.

Re-runnable: the output directory is fully rebuilt on every run, and the
result depends only on the source library and the parameters below.

Usage:
    python tool/pack_memes.py            # pack using the parameters below

Parameters that matter are all in the CONFIG block.
"""

from __future__ import annotations

import io
import json
import os
import shutil
import sqlite3
import sys
from collections import Counter, defaultdict
from pathlib import Path, PurePosixPath

# --------------------------------------------------------------------------
# CONFIG
# --------------------------------------------------------------------------

# Source library (read-only; never modified).
SRC_ROOT = Path(r"C:\Users\xi283\.dsh\meme-packs\dafeiyu-desktop")
SRC_DB = SRC_ROOT / "index.db"
SRC_TABLE = "memes"

# Output; rebuilt from scratch on every run.
OUT_ROOT = Path(r"D:\Projects\yiji\assets\memes")
OUT_INDEX = OUT_ROOT / "index.json"

# Which value labels the output directory and the ``tag`` field:
#   "db"  -> index.db ``tag`` column. Authoritative: the DB was re-captioned
#            and re-tagged after import, so 48 of 108 rows disagree with the
#            folder they physically sit in. Yields 9 tags.
#   "dir" -> the ``memes/<dir>/`` folder name. Yields exactly 6 tags, but
#            contradicts the DB tag for those 48 rows.
TAG_SOURCE = "db"

# Compression ladder, tried in order; the first level that satisfies BOTH
# budgets wins. Each entry is (max_long_edge_px, webp_quality).
LEVELS = [
    (512, 80),
    (448, 80),
    (448, 72),
    (384, 72),
    (320, 65),
]

# Budgets the chosen level must meet.
TARGET_TOTAL_BYTES = 8 * 1024 * 1024   # total size of assets/memes
TARGET_AVG_BYTES = 60 * 1024           # mean bytes per packed image

# Safety net for single outliers: if one image still exceeds this after the
# level's quality, re-encode that image alone at successively lower quality
# (never below MIN_QUALITY). Keeps a few heavy photos from eating the average.
PER_IMAGE_MAX_BYTES = 96 * 1024
MIN_QUALITY = 55

# WebP encoder effort (0-6). 6 = slowest/best; 108 small images is fast either
# way and the output is deterministic.
WEBP_METHOD = 6

# Animated sources (7 GIFs) are packed as their first frame. Static WebP is
# what Flutter's Image.asset and Android BitmapFactory actually decode, and
# animated WebP cannot fit the size budget.
ANIMATED = False

# --------------------------------------------------------------------------


def stem_of(file_name: str) -> str:
    """Return the numeric main name used for the .webp output, e.g.
    ``1785381947299.png`` -> ``1785381947299``."""
    return PurePosixPath(file_name).stem


def load_rows() -> list[sqlite3.Row]:
    con = sqlite3.connect(f"file:{SRC_DB}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    try:
        return con.execute(
            f"SELECT path, tag, file_name, caption, keywords FROM {SRC_TABLE}"
        ).fetchall()
    finally:
        con.close()


def out_tag_for(row: sqlite3.Row) -> str:
    if TAG_SOURCE == "db":
        return row["tag"]
    src_dir = PurePosixPath(row["path"].replace("\\", "/")).parts[1]
    return src_dir


def normalize(path: Path):
    """Open ``path`` and return an RGB(A) image, first frame only, EXIF-rotated,
    with the alpha channel dropped when it is fully opaque."""
    from PIL import Image, ImageOps

    im = Image.open(path)
    try:
        im.seek(0)
    except EOFError:
        pass
    transposed = ImageOps.exif_transpose(im)
    if transposed is not None:
        im = transposed

    transparent = im.mode in ("RGBA", "LA") or (
        im.mode == "P" and "transparency" in im.info
    )
    if transparent:
        im = im.convert("RGBA")
        if im.getchannel("A").getextrema()[0] == 255:
            im = im.convert("RGB")
    else:
        im = im.convert("RGB")
    return im


def resize(im, max_edge: int):
    from PIL import Image

    if max(im.size) <= max_edge:
        return im
    out = im.copy()
    out.thumbnail((max_edge, max_edge), Image.LANCZOS)
    return out


def encode(im, quality: int) -> bytes:
    buf = io.BytesIO()
    im.save(buf, "WEBP", quality=quality, method=WEBP_METHOD)
    return buf.getvalue()


def encode_with_cap(im, quality: int) -> tuple[bytes, int]:
    """Encode at ``quality``, lowering quality while the result exceeds
    PER_IMAGE_MAX_BYTES. Returns (bytes, quality actually used)."""
    data = encode(im, quality)
    q = quality
    while len(data) > PER_IMAGE_MAX_BYTES and q > MIN_QUALITY:
        q = max(MIN_QUALITY, q - 10)
        data = encode(im, q)
        if q == MIN_QUALITY:
            break
    return data, q


def human(n: float) -> str:
    for unit in ("B", "KB", "MB"):
        if abs(n) < 1024 or unit == "MB":
            return f"{n:,.1f} {unit}" if unit != "B" else f"{int(n)} B"
        n /= 1024
    return f"{n} B"


def main() -> int:
    problems: list[str] = []

    expected = os.path.realpath(str(OUT_ROOT))
    if not (expected.endswith(os.sep + os.path.join("assets", "memes"))):
        print(f"refusing to clean unexpected output path: {expected}", file=sys.stderr)
        return 2

    if not SRC_DB.is_file():
        print(f"source index not found: {SRC_DB}", file=sys.stderr)
        return 2

    rows = load_rows()
    print(f"source rows        : {len(rows)}")

    # Resolve every row to an existing source file.
    todo: list[tuple[sqlite3.Row, Path, str, str]] = []
    for row in rows:
        rel = PurePosixPath(row["path"].replace("\\", "/"))
        src = SRC_ROOT.joinpath(*rel.parts)
        if not src.is_file():
            problems.append(f"missing source file: {row['path']}")
            continue
        tag = out_tag_for(row)
        todo.append((row, src, tag, stem_of(row["file_name"])))

    raw_total = sum(src.stat().st_size for _, src, _, _ in todo)
    print(f"source files found : {len(todo)}")
    print(f"source total size  : {human(raw_total)}")

    if not todo:
        print("nothing to pack", file=sys.stderr)
        return 2

    # Try each rung of the ladder until both budgets are met.
    chosen = None
    for max_edge, quality in LEVELS:
        results: list[tuple[sqlite3.Row, Path, str, str, bytes, int]] = []
        for row, src, tag, stem in todo:
            im = normalize(src)
            im = resize(im, max_edge)
            data, used_q = encode_with_cap(im, quality)
            results.append((row, src, tag, stem, data, used_q))
        total = sum(len(r[4]) for r in results)
        avg = total / len(results)
        print(
            f"  level {max_edge}px/q{quality}: total {human(total)}, "
            f"avg {human(avg)}"
            + ("  <-- within budget" if total <= TARGET_TOTAL_BYTES and avg <= TARGET_AVG_BYTES else "")
        )
        chosen = (max_edge, quality, results)
        if total <= TARGET_TOTAL_BYTES and avg <= TARGET_AVG_BYTES:
            break

    assert chosen is not None
    max_edge, quality, results = chosen

    # Rebuild the output tree.
    shutil.rmtree(OUT_ROOT, ignore_errors=True)
    OUT_ROOT.mkdir(parents=True, exist_ok=True)

    entries: list[dict[str, str]] = []
    written: list[tuple[str, int, int, int, int]] = []  # rel, bytes, w, h, q
    packed_bytes: dict[str, int] = {}
    skipped: list[tuple[str, str]] = []

    for row, src, tag, stem, data, used_q in results:
        rel_out = f"{tag}/{stem}.webp"
        dest = OUT_ROOT / tag / f"{stem}.webp"
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)

        from PIL import Image

        with Image.open(io.BytesIO(data)) as chk:
            w, h = chk.size

        entries.append(
            {
                # ``or ""`` keeps the JSON contract (always a string, never
                # null) even if a future source DB has nullable columns.
                "file": rel_out,
                "tag": tag,
                "caption": row["caption"] or "",
                "keywords": row["keywords"] or "",
            }
        )
        written.append((rel_out, len(data), w, h, used_q))
        packed_bytes[row["path"]] = len(data)

    # Skipped = source rows that produced no output.
    for row in rows:
        rel = PurePosixPath(row["path"].replace("\\", "/"))
        if row["path"] not in packed_bytes:
            reason = (
                "source file missing on disk"
                if not SRC_ROOT.joinpath(*rel.parts).is_file()
                else "encode failed"
            )
            skipped.append((row["path"], reason))

    entries.sort(key=lambda e: (e["tag"], e["file"]))

    with open(OUT_INDEX, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(entries, fh, ensure_ascii=False, indent=2)
        fh.write("\n")

    # ---- report -----------------------------------------------------------
    total = sum(w[1] for w in written)
    largest = max(written, key=lambda w: w[1])

    print()
    print("================ PACK REPORT ================")
    print(f"tag source         : {TAG_SOURCE}")
    print(f"level used         : max edge {max_edge}px, quality {quality}")
    print(f"entries written    : {len(entries)}")
    print(f"raw total          : {human(raw_total)}")
    print(f"packed total       : {human(total)}  ({total:,} bytes)")
    print(f"ratio              : {raw_total / total:.1f}x smaller")
    print(f"avg per image      : {human(total / len(written))}")
    print(f"largest image      : {largest[0]} {human(largest[1])} {largest[2]}x{largest[3]} q{largest[4]}")
    print(f"total <= 8 MB      : {total <= TARGET_TOTAL_BYTES}")
    print(f"avg <= 60 KB       : {total / len(written) <= TARGET_AVG_BYTES}")
    print("per tag            : " + ", ".join(
        f"{t}={n}" for t, n in sorted(Counter(e['tag'] for e in entries).items())
    ))
    q_used = Counter(w[4] for w in written)
    print(f"qualities used     : {dict(sorted(q_used.items()))}")

    dims = Counter(f"{w[2]}x{w[3]}" for w in written)
    print(f"longest edge max   : {max(max(w[2], w[3]) for w in written)}px")
    print(f"top 5 dimensions   : {dims.most_common(5)}")

    print()
    print(f"skipped            : {len(skipped)}")
    for path, reason in skipped:
        print(f"  - {path}: {reason}")
    for p in problems:
        print(f"  ! {p}")

    # Verify what we just wrote.
    check = json.loads(OUT_INDEX.read_text(encoding="utf-8"))
    bad = [e["file"] for e in check if not (OUT_ROOT / e["file"]).is_file()]
    print()
    print(f"index.json entries : {len(check)}")
    print(f"dangling entries   : {len(bad)} {bad[:5]}")
    print("============================================")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
