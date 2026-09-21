#!/usr/bin/env python3
"""Verify memory dump file against expected pattern.

Tolerates a small percentage of pages modified by GIC/ITS table restore.
Passes if >99% of pages match the expected pattern.
"""
import sys

def main():
    dump_path = sys.argv[1]
    offset = int(sys.argv[2])
    size = int(sys.argv[3])
    pattern = int(sys.argv[4], 16)  # e.g. "AA" -> 0xAA
    label = sys.argv[5]

    PAGE_SIZE = 4096

    with open(dump_path, "rb") as f:
        f.seek(offset)
        data = f.read(size)

    if len(data) != size:
        print(f"  FAIL {label}: read {len(data)} bytes, expected {size}")
        return 1

    expected_byte = bytes([pattern])
    total_pages = size // PAGE_SIZE
    matching_pages = 0
    mismatch_pages = []

    for i in range(total_pages):
        page_start = i * PAGE_SIZE
        page = data[page_start:page_start + PAGE_SIZE]
        if page == expected_byte * PAGE_SIZE:
            matching_pages += 1
        else:
            if len(mismatch_pages) < 5:
                mismatch_pages.append((i, page[0]))

    pct = matching_pages / total_pages * 100 if total_pages > 0 else 0

    if pct > 99.0:
        print(f"  PASS {label}: {matching_pages}/{total_pages} pages match 0x{pattern:02X} "
              f"({pct:.2f}%)"
              + (f" [{total_pages - matching_pages} GIC-modified pages]" if matching_pages < total_pages else ""))
        return 0
    else:
        print(f"  FAIL {label}: only {matching_pages}/{total_pages} pages match 0x{pattern:02X} "
              f"({pct:.2f}%)")
        for page_idx, first_byte in mismatch_pages:
            abs_offset = offset + page_idx * PAGE_SIZE
            print(f"    page {page_idx} (abs offset {abs_offset}): first byte 0x{first_byte:02X}")
        return 1

if __name__ == "__main__":
    sys.exit(main())
