#!/usr/bin/env python3
"""Install one shared Sv39 root into a linked four-hart supervisor image."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


PHYSICAL_BASE = 0x8000_0000
VIRTUAL_BASE = 0x4000_0000
MAPPED_BYTES = 0x2_0000
ROOT_OFFSET = 0x2_0000
LEVEL1_OFFSET = 0x2_1000
LEVEL0_OFFSET = 0x2_2000
IMAGE_BYTES = LEVEL0_OFFSET + 0x1000
PTE_FLAGS_RWXAD = 0xCF


def pte(pointer_or_page: int, flags: int) -> int:
    return ((pointer_or_page >> 12) << 10) | flags


def put_u64(image: bytearray, offset: int, value: int) -> None:
    image[offset:offset + 8] = value.to_bytes(8, "little")


def build(template: bytes) -> bytearray:
    if len(template) > IMAGE_BYTES:
        raise ValueError(
            f"template is {len(template):#x} bytes; expected at most "
            f"{IMAGE_BYTES:#x}"
        )

    image = bytearray(IMAGE_BYTES)
    image[:len(template)] = template
    image[ROOT_OFFSET:IMAGE_BYTES] = bytes(IMAGE_BYTES - ROOT_OFFSET)

    # VA 0x40000000 has VPN[2] == 1 and VPN[1] == 0.
    put_u64(
        image,
        ROOT_OFFSET + 1 * 8,
        pte(PHYSICAL_BASE + LEVEL1_OFFSET, 0x1),
    )
    put_u64(
        image,
        LEVEL1_OFFSET,
        pte(PHYSICAL_BASE + LEVEL0_OFFSET, 0x1),
    )
    for page in range(MAPPED_BYTES // 0x1000):
        put_u64(
            image,
            LEVEL0_OFFSET + page * 8,
            pte(PHYSICAL_BASE + page * 0x1000, PTE_FLAGS_RWXAD),
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
        print(f"make_shared_sv39_image.py: {exc}", file=sys.stderr)
        return 2

    root_ppn = (PHYSICAL_BASE + ROOT_OFFSET) >> 12
    print(
        f"shared Sv39 image: {len(result):#x} bytes, "
        f"satp.ppn={root_ppn:#x}, VA={VIRTUAL_BASE:#x}, "
        f"mapped={MAPPED_BYTES:#x}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
