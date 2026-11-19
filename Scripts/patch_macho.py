#!/usr/bin/env python3
"""Append an idempotent LC_LOAD_WEAK_DYLIB command into a 64-bit Mach-O (thin or universal)."""

import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA
LC_LOAD_WEAK_DYLIB = 0x80000018


def patch_slice(data: bytearray, slice_offset: int, dylib_install_name: bytes) -> bool:
    magic, _cpu, _sub, _ft, ncmds, sizeofcmds, _flags, _res = struct.unpack_from(
        "<IIIIIIII", data, slice_offset
    )
    if magic != MH_MAGIC_64:
        raise RuntimeError(f"Unsupported Mach-O slice magic at {slice_offset}: {hex(magic)}")

    header_end = slice_offset + 32 + sizeofcmds
    if dylib_install_name in data[slice_offset : header_end]:
        return False

    raw_name = dylib_install_name + b"\x00"
    pad = (8 - (len(raw_name) % 8)) % 8
    padded_name = raw_name + b"\x00" * pad
    cmdsize = 24 + len(padded_name)

    if any(b != 0 for b in data[header_end : header_end + cmdsize]):
        raise RuntimeError(
            f"Not enough zero header padding at offset {header_end} (need {cmdsize} bytes)"
        )

    lc = (
        struct.pack("<IIIIII", LC_LOAD_WEAK_DYLIB, cmdsize, 24, 2, 0x00010000, 0x00010000)
        + padded_name
    )
    data[header_end : header_end + cmdsize] = lc
    struct.pack_into("<II", data, slice_offset + 16, ncmds + 1, sizeofcmds + cmdsize)
    return True


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <macho-binary> <@rpath/Name.dylib>", file=sys.stderr)
        return 2

    bin_path = sys.argv[1]
    dylib_name = sys.argv[2].encode("utf-8")

    with open(bin_path, "rb") as f:
        data = bytearray(f.read())

    magic_be = struct.unpack_from(">I", data, 0)[0]
    magic_le = struct.unpack_from("<I", data, 0)[0]

    patched = 0
    if magic_le == MH_MAGIC_64:
        if patch_slice(data, 0, dylib_name):
            patched += 1
    elif magic_be == FAT_MAGIC or magic_le == FAT_CIGAM:
        nfat = struct.unpack_from(">I", data, 4)[0]
        for i in range(nfat):
            _cpu, _sub, offset, _size, _align = struct.unpack_from(">IIIII", data, 8 + i * 20)
            if patch_slice(data, offset, dylib_name):
                patched += 1
    else:
        raise RuntimeError(f"Unsupported binary format (magic {hex(magic_le)})")

    if patched > 0:
        with open(bin_path, "wb") as f:
            f.write(data)
        print(f"Injected LC_LOAD_WEAK_DYLIB ({dylib_name.decode()}) into {patched} slice(s).")
    else:
        print(f"Already linked with {dylib_name.decode()}; no change needed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
