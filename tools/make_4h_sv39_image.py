#!/usr/bin/env python3
"""Replicate one Sv39 supervisor image under four physical prefixes."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


PHYSICAL_BASE = 0x8000_0000
VIRTUAL_BASE = 0x4000_0000
HARTS = 4
PREFIX_STRIDE = 0x10_0000
MAPPED_BYTES = 0x2_0000
ROOT_OFFSET = 0x2_0000
LEVEL1_OFFSET = 0x2_1000
LEVEL0_OFFSET = 0x2_2000
IMAGE_BYTES = (HARTS - 1) * PREFIX_STRIDE + LEVEL0_OFFSET + 0x1000
PTE_FLAGS_RWXAD = 0xCF


def pte(pointer_or_page: int, flags: int) -> int:
    return ((pointer_or_page >> 12) << 10) | flags


def put_u64(image: bytearray, offset: int, value: int) -> None:
    image[offset:offset + 8] = value.to_bytes(8, "little")


def build(template: bytes) -> bytearray:
    if len(template) > LEVEL0_OFFSET + 0x1000:
        raise ValueError(
            f"template is {len(template):#x} bytes; expected at most 0x23000"
        )

    image = bytearray(IMAGE_BYTES)
    for hart in range(HARTS):
        prefix = hart * PREFIX_STRIDE
        physical_prefix = PHYSICAL_BASE + prefix
        image[prefix:prefix + len(template)] = template

        root = prefix + ROOT_OFFSET
        level1 = prefix + LEVEL1_OFFSET
        level0 = prefix + LEVEL0_OFFSET
        image[root:root + 0x1000] = bytes(0x1000)
        image[level1:level1 + 0x1000] = bytes(0x1000)
        image[level0:level0 + 0x1000] = bytes(0x1000)

        # VA 0x40000000 has VPN[2] == 1 and VPN[1] == 0.
        put_u64(
            image,
            root + 1 * 8,
            pte(physical_prefix + LEVEL1_OFFSET, 0x1),
        )
        put_u64(
            image,
            level1,
            pte(physical_prefix + LEVEL0_OFFSET, 0x1),
        )
        for page in range(MAPPED_BYTES // 0x1000):
            put_u64(
                image,
                level0 + page * 8,
                pte(physical_prefix + page * 0x1000, PTE_FLAGS_RWXAD),
            )
    return image


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("template", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    try:
        result = build(args.template.read_bytes())
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(result)
    except (OSError, ValueError) as exc:
        print(f"make_4h_sv39_image.py: {exc}", file=sys.stderr)
        return 2

    print(
        f"four-hart Sv39 image: {len(result):#x} bytes, "
        f"{HARTS} roots, stride={PREFIX_STRIDE:#x}, "
        f"VA={VIRTUAL_BASE:#x}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
