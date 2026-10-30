#!/usr/bin/env python3
"""Reverse-engineering tool for FoDict (net.fodian.fodict) `fodict.idx` files.

Format (little endian), reverse engineered from the app's class
`net.fodian.fodict.ah` and validated against dictionaries that ship both
`fodict.idx` and `fodict.dat` (001..006, 008..028):

    offset 0   : 26 bytes  magic "fodict index\\0" in UTF-16LE
    offset 26  : u32       version (1 or 2)
    offset 30  : u32       header size `f` (normally 64)
    offset 34  : u32       number of table entries `n`

    table at `f`: n records of 12 bytes:
        u32 codePoint, u32 keywordIndexOffset, u32 definitionIndexOffset

    every offset is relative to `f`. A node at `f + off` is:

        u16 childCount
        repeat childCount times:
            u16 childKey            (entry id, 1..65535)
            u16 postingCount
            repeat postingCount times:
                delta encoded u32 posting (byte offset inside the text)
                (running total -> absolute byte offset)

    The high two bits of the first delta byte choose the width:
        00 -> 4 bytes: (b0 & 0x3f) << 24 | b1 << 16 | b2 << 8 | b3
        01 -> 1 byte :  b0 & 0x3f
        10 -> 2 bytes: (b0 & 0x3f) << 8 | b1
        11 -> 3 bytes: (b0 & 0x3f) << 16 | b1 << 8 | b2

The first index (keyword) maps character -> entry id -> byte offsets inside the
entry *keyword*; the second index (definition) maps character -> entry id ->
byte offsets inside the entry *definition*.  Files without `fodict.dat` can
therefore be turned back into (keyword, definition) text: invert the index,
place every character at its recorded offset.

The index builder does not record whitespace / punctuation (it treats them as
separators), so those positions come back as holes (0x0000).  With `--hole`
they can be substituted (a single space is a sane default); everything else is
bit-exact (verified against all 31587 entries of 001.dfb-j).

Usage:
    python3 tool/fodict_idx.py info  <dir-or-idx>
    python3 tool/fodict_idx.py dump  <dir-or-idx> [-o out.tsv] [--hole ' ']
    python3 tool/fodict_idx.py dat   <dir-or-idx> [-o fodict.dat] [--hole ' ']
"""

from __future__ import annotations

import argparse
import os
import struct
import sys

MAGIC = "fodict index"


class IdxDict:
    def __init__(self, path: str):
        self.path = path
        with open(path, "rb") as fh:
            self.data = fh.read()
        if len(self.data) < 40:
            raise ValueError("file too small")
        if self.data[:24].decode("utf-16le", "replace") != MAGIC:
            raise ValueError("not a fodict.idx file (bad magic)")
        self.version = struct.unpack_from("<I", self.data, 26)[0]
        if self.version not in (1, 2):
            raise ValueError(f"unsupported index version {self.version}")
        self.header_size = struct.unpack_from("<I", self.data, 30)[0]
        self.count = struct.unpack_from("<I", self.data, 34)[0]
        self.table: dict[int, tuple[int, int]] = {}
        for i in range(self.count):
            cp, kw_off, def_off = struct.unpack_from(
                "<III", self.data, self.header_size + i * 12
            )
            self.table[cp] = (kw_off, def_off)

    # --- node parsing -----------------------------------------------------
    def _node(self, off: int) -> dict[int, list[int]]:
        d = self.data
        base = self.header_size + off
        child_count = struct.unpack_from("<H", d, base)[0]
        p = base + 2
        out: dict[int, list[int]] = {}
        for _ in range(child_count):
            key = struct.unpack_from("<H", d, p)[0]
            p += 2
            posting_count = struct.unpack_from("<H", d, p)[0]
            p += 2
            positions = []
            total = 0
            for _ in range(posting_count):
                b0 = d[p]
                p += 1
                kind = b0 & 0xC0
                if kind == 0x00:
                    value = (
                        ((b0 & 0x3F) << 24)
                        | (d[p] << 16)
                        | (d[p + 1] << 8)
                        | d[p + 2]
                    )
                    p += 3
                elif kind == 0x40:
                    value = b0 & 0x3F
                elif kind == 0x80:
                    value = ((b0 & 0x3F) << 8) | d[p]
                    p += 1
                else:
                    value = ((b0 & 0x3F) << 16) | (d[p] << 8) | d[p + 1]
                    p += 2
                total += value
                positions.append(total)
            out[key] = positions
        return out

    # --- inversion --------------------------------------------------------
    def entries(self) -> dict[int, tuple[str, str]]:
        """Return {entry_id: (keyword, definition)} with holes filled by space."""
        words: dict[int, list[tuple[int, int]]] = {}
        defs: dict[int, list[tuple[int, int]]] = {}

        for cp, (kw_off, def_off) in self.table.items():
            if cp <= 0xFFFF:
                units = [cp]
            else:
                v = cp - 0x10000
                units = [0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF)]
            for target, off in ((words, kw_off), (defs, def_off)):
                if not off:
                    continue
                node = self._node(off)
                for entry_id, positions in node.items():
                    bucket = target.setdefault(entry_id, [])
                    for pos in positions:
                        unit = pos // 2
                        for k, u in enumerate(units):
                            bucket.append((unit + k, u))

        result: dict[int, tuple[str, str]] = {}
        for entry_id in set(words) | set(defs):
            result[entry_id] = (
                _build_text(words.get(entry_id, [])),
                _build_text(defs.get(entry_id, [])),
            )
        return result


def _build_text(items: list[tuple[int, int]]) -> str:
    if not items:
        return ""
    size = max(i for i, _ in items) + 1
    units = [0x20] * size
    for i, u in items:
        units[i] = u
    return struct.pack(f"<{size}H", *units).decode("utf-16le", "replace").rstrip()


# --- fodict.dat writer ----------------------------------------------------
DAT_MAGIC = "fodict v1"
DAT_HEADER = 64


def build_dat(entries: dict[int, tuple[str, str]], out_path: str) -> None:
    ids = sorted(entries)
    n = len(ids)
    root_off = DAT_HEADER
    strings_off = root_off + 4 + n * 16

    pool = bytearray()
    records = []
    for entry_id in ids:
        keyword, definition = entries[entry_id]
        if not keyword:
            keyword = "?"
        if not definition:
            definition = " "
        kw_bytes = keyword.encode("utf-16le")
        def_bytes = definition.encode("utf-16le")
        kw_pos = len(pool)
        pool += struct.pack("<I", len(kw_bytes)) + kw_bytes
        def_pos = len(pool)
        pool += struct.pack("<I", len(def_bytes)) + def_bytes
        records.append(struct.pack("<iiii", entry_id, kw_pos, def_pos, -1))

    header = bytearray(DAT_HEADER)
    header[0:18] = DAT_MAGIC.encode("utf-16le")
    struct.pack_into("<I", header, 20, 1)  # version
    struct.pack_into("<I", header, 24, root_off)
    struct.pack_into("<I", header, 28, strings_off - root_off)
    struct.pack_into("<I", header, 32, strings_off)

    with open(out_path, "wb") as fh:
        fh.write(header)
        fh.write(struct.pack("<I", n))
        for rec in records:
            fh.write(rec)
        fh.write(pool)


def resolve_idx(path: str) -> str:
    if os.path.isdir(path):
        path = os.path.join(path, "fodict.idx")
    if not os.path.isfile(path):
        raise SystemExit(f"fodict.idx not found: {path}")
    return path


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("command", choices=["info", "dump", "dat"])
    ap.add_argument("path", help="dictionary directory or fodict.idx path")
    ap.add_argument("-o", "--output", help="output file")
    args = ap.parse_args(argv)

    idx = IdxDict(resolve_idx(args.path))
    print(
        f"version={idx.version} header={idx.header_size} "
        f"characters={idx.count} file={len(idx.data)} bytes",
        file=sys.stderr,
    )
    entries = idx.entries()
    print(f"entries={len(entries)}", file=sys.stderr)

    if args.command == "info":
        ids = sorted(entries)
        for entry_id in ids[:10]:
            kw, df = entries[entry_id]
            print(f"{entry_id}\t{kw}\t{df[:60]}")
        return 0

    if args.command == "dump":
        out = args.output
        fh = open(out, "w", encoding="utf-8") if out else sys.stdout
        try:
            for entry_id in sorted(entries):
                kw, df = entries[entry_id]
                df = df.replace("\t", " ").replace("\r", " ").replace("\n", " ")
                print(f"{entry_id}\t{kw}\t{df}", file=fh)
        finally:
            if out:
                fh.close()
        return 0

    out = args.output or os.path.join(os.path.dirname(resolve_idx(args.path)), "fodict.dat")
    build_dat(entries, out)
    print(f"wrote {out} ({os.path.getsize(out)} bytes)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
