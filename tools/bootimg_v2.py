#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Android boot image v2 packer/unpacker for the OnePlus Pad Pro (caihong).

The Caihong boot chain consumes an Android boot image v2 (header version 2)
that carries the Linux ``Image`` and the Caihong device tree, and *no*
ramdisk.  The reference project relies on AOSP's ``mkbootimg.py``; this module
reimplements the v2 layout without any third-party dependency so that the
Ubuntu port can be rebuilt offline and audited byte for byte.

Layout (all little endian):

    offset  size  field
    0       8     magic "ANDROID!"
    8       4     kernel_size
    12      4     kernel_addr
    16      4     ramdisk_size
    20      4     ramdisk_addr
    24      4     second_size
    28      4     second_addr
    32      4     tags_addr
    36      4     page_size
    40      4     header_version (2)
    44      4     os_version
    48      16    name
    64      512   cmdline
    576     32    id (SHA-1, zero padded)
    608     1024  extra_cmdline
    1632    4     recovery_dtbo_size
    1636    8     recovery_dtbo_offset
    1644    4     header_size (1660)
    1648    4     dtb_size
    1652    8     dtb_addr

Payloads follow the 4096-byte page aligned header in this order: kernel,
ramdisk, second stage, recovery dtbo, dtb.  Every payload is padded to
``page_size``.
"""

import argparse
import hashlib
import os
import struct
import sys

BOOT_MAGIC = b"ANDROID!"
BOOT_NAME_SIZE = 16
BOOT_ARGS_SIZE = 512
BOOT_EXTRA_ARGS_SIZE = 1024
BOOT_ID_SIZE = 32
VENDOR_BOOT_MAGIC = b"VNDRBOOT"
HEADER_V2_SIZE = 1660

# Caihong boot image geometry, identical to the reference release tooling.
CAIHONG_GEOMETRY = {
    "base": 0x00000000,
    "kernel_offset": 0x00008000,
    "ramdisk_offset": 0x01000000,
    "second_offset": 0x00F00000,
    "tags_offset": 0x00000100,
    "dtb_offset": 0x04000000,
    "page_size": 4096,
    "header_version": 2,
}


class BootImageError(Exception):
    pass


def _pages(n, page_size):
    return (n + page_size - 1) // page_size


def _read(path, what):
    try:
        with open(path, "rb") as handle:
            return handle.read()
    except OSError as exc:
        raise BootImageError(f"cannot read {what} {path}: {exc}") from exc


def parse_os_version(value):
    return ((value >> 25) & 0x7F, (value >> 18) & 0x7F, (value >> 11) & 0x7F,
            (value >> 4) & 0x7F, value & 0xF)


def build_os_version(version: str, patch_level: str) -> int:
    try:
        major, minor, patch = (int(x) for x in version.split("."))
    except ValueError as exc:
        raise BootImageError(f"invalid --os_version {version!r}, expected A.B.C") from exc
    try:
        year, month = (int(x) for x in patch_level.split("-"))
    except ValueError as exc:
        raise BootImageError(f"invalid --os_patch_level {patch_level!r}, expected YYYY-MM") from exc
    if not (2000 <= year <= 2127 and 1 <= month <= 12):
        raise BootImageError("os_patch_level outside the encodable range 2000-01..2127-12")
    for name, part in (("major", major), ("minor", minor), ("patch", patch)):
        if not 0 <= part <= 127:
            raise BootImageError(f"os_version {name} {part} does not fit in 7 bits")
    return ((major << 25) | (minor << 18) | (patch << 11) | ((year - 2000) << 4) | month)


def pack(kernel, dtb, cmdline, output, geometry=None, os_version="16.0.0",
         os_patch_level="2026-06", name="", dtb_addr=None):
    geometry = dict(geometry or CAIHONG_GEOMETRY)
    page_size = geometry["page_size"]
    if page_size <= 0 or page_size & (page_size - 1):
        raise BootImageError("page_size must be a power of two")

    kernel_data = _read(kernel, "kernel")
    dtb_data = _read(dtb, "dtb")
    if not kernel_data:
        raise BootImageError("kernel payload is empty")
    if dtb_data[:4] != b"\xd0\x0d\xfe\xed":
        raise BootImageError(f"dtb payload does not start with the FDT magic: {dtb}")
    if len(cmdline.encode()) >= BOOT_ARGS_SIZE:
        raise BootImageError("cmdline does not fit in the 512-byte boot header field")
    if dtb_addr is None:
        dtb_addr = geometry["base"] + geometry["dtb_offset"]

    header = bytearray(HEADER_V2_SIZE)
    header[0:8] = BOOT_MAGIC
    struct.pack_into("<I", header, 8, len(kernel_data))
    struct.pack_into("<I", header, 12, geometry["base"] + geometry["kernel_offset"])
    # The validated Caihong reference images leave the load address of every
    # absent payload at zero instead of emitting the configured offset, so keep
    # that behaviour: it is what the shipped bootloader was tested against.
    struct.pack_into("<I", header, 16, 0)  # no ramdisk
    struct.pack_into("<I", header, 20, 0)
    struct.pack_into("<I", header, 24, 0)  # no second stage
    struct.pack_into("<I", header, 28, 0)
    struct.pack_into("<I", header, 32, geometry["base"] + geometry["tags_offset"])
    struct.pack_into("<I", header, 36, page_size)
    struct.pack_into("<I", header, 40, geometry["header_version"])
    struct.pack_into("<I", header, 44, build_os_version(os_version, os_patch_level))
    header[48:48 + BOOT_NAME_SIZE] = name.encode()[:BOOT_NAME_SIZE].ljust(BOOT_NAME_SIZE, b"\x00")
    header[64:64 + BOOT_ARGS_SIZE] = cmdline.encode().ljust(BOOT_ARGS_SIZE, b"\x00")
    header[576:576 + BOOT_ID_SIZE] = b"\x00" * BOOT_ID_SIZE
    struct.pack_into("<I", header, 1632, 0)   # recovery_dtbo_size
    struct.pack_into("<Q", header, 1636, 0)   # recovery_dtbo_offset
    struct.pack_into("<I", header, 1644, HEADER_V2_SIZE)
    struct.pack_into("<I", header, 1648, len(dtb_data))
    struct.pack_into("<Q", header, 1652, dtb_addr)

    sha = hashlib.sha1()
    sha.update(header)
    sha.update(kernel_data)
    sha.update(dtb_data)
    # The id field is 32 bytes but only the first 20 carry the SHA-1; the rest
    # stay zero. Assigning a 20-byte value to the whole 32-byte slice would
    # shrink the header by 12 bytes and shift every following field.
    header[576:576 + 20] = sha.digest()

    def pad(blob):
        return blob + b"\x00" * (_pages(len(blob), page_size) * page_size - len(blob))

    payload = pad(bytes(header)) + pad(kernel_data) + pad(dtb_data)
    temporary = f"{output}.part"
    try:
        with open(temporary, "wb") as handle:
            handle.write(payload)
        os.replace(temporary, output)
    except OSError as exc:
        if os.path.exists(temporary):
            os.unlink(temporary)
        raise BootImageError(f"cannot write {output}: {exc}") from exc

    return {
        "output": output,
        "size": len(payload),
        "kernel_size": len(kernel_data),
        "dtb_size": len(dtb_data),
        "kernel_sha256": hashlib.sha256(kernel_data).hexdigest(),
        "dtb_sha256": hashlib.sha256(dtb_data).hexdigest(),
        "id": header[576:576 + BOOT_ID_SIZE].hex(),
        "cmdline": cmdline,
    }


def parse(blob, source="<memory>"):
    if blob[:8] == VENDOR_BOOT_MAGIC:
        raise BootImageError(f"{source}: vendor_boot image, not a boot image")
    if blob[:8] != BOOT_MAGIC:
        raise BootImageError(f"{source}: bad magic {blob[:8]!r}, not an Android boot image")
    (kernel_size, kernel_addr, ramdisk_size, ramdisk_addr, second_size, second_addr,
     tags_addr, page_size, header_version) = struct.unpack_from("<9I", blob, 8)
    if page_size == 0 or page_size & (page_size - 1):
        raise BootImageError(f"{source}: invalid page size {page_size}")
    info = {
        "source": source,
        "file_size": len(blob),
        "kernel_size": kernel_size,
        "kernel_addr": kernel_addr,
        "ramdisk_size": ramdisk_size,
        "ramdisk_addr": ramdisk_addr,
        "second_size": second_size,
        "second_addr": second_addr,
        "tags_addr": tags_addr,
        "page_size": page_size,
        "header_version": header_version,
        "cmdline": None,
        "id": None,
        "dtb_size": 0,
        "dtb_addr": None,
        "header_size": None,
        "offset_kernel": page_size,
    }
    if header_version >= 1:
        os_version, = struct.unpack_from("<I", blob, 44)
        major, minor, patch, year, month = parse_os_version(os_version)
        info["os_version"] = f"{major}.{minor}.{patch}"
        info["os_patch_level"] = f"{2000 + year}-{month:02d}"
        info["name"] = blob[48:64].split(b"\x00")[0].decode("utf-8", "replace")
        info["cmdline"] = blob[64:64 + BOOT_ARGS_SIZE].split(b"\x00")[0].decode("utf-8", "replace")
        info["id"] = blob[576:576 + BOOT_ID_SIZE].hex()
        info["extra_cmdline"] = blob[608:608 + BOOT_EXTRA_ARGS_SIZE].split(b"\x00")[0].decode(
            "utf-8", "replace")
        info["recovery_dtbo_size"], = struct.unpack_from("<I", blob, 1632)
        info["recovery_dtbo_offset"], = struct.unpack_from("<Q", blob, 1636)
        info["header_size"], = struct.unpack_from("<I", blob, 1644)
    if header_version >= 2:
        dtb_size, dtb_addr = struct.unpack_from("<IQ", blob, 1648)
        info["dtb_size"] = dtb_size
        info["dtb_addr"] = dtb_addr

    offset = page_size
    payloads = {}
    for key, size in (("kernel", kernel_size), ("ramdisk", ramdisk_size),
                      ("second", second_size),
                      ("recovery_dtbo", info.get("recovery_dtbo_size", 0))):
        if size:
            payloads[key] = (offset, size)
            offset += _pages(size, page_size) * page_size
    if info["dtb_size"]:
        payloads["dtb"] = (offset, info["dtb_size"])
        offset += _pages(info["dtb_size"], page_size) * page_size
    info["payloads"] = payloads
    info["end_of_payloads"] = offset
    return info


def cmd_info(args):
    blob = _read(args.image, "boot image")
    info = parse(blob, args.image)
    for key in ("source", "file_size", "header_version", "header_size", "page_size",
                "kernel_size", "kernel_addr", "ramdisk_size", "tags_addr", "os_version",
                "os_patch_level", "dtb_size", "dtb_addr", "cmdline", "id",
                "end_of_payloads"):
        if key in info and info[key] is not None:
            value = info[key]
            if isinstance(value, int) and key.endswith("_addr"):
                value = f"0x{value:08x}"
            print(f"{key:16}: {value}")
    for key, (offset, size) in info["payloads"].items():
        digest = hashlib.sha256(blob[offset:offset + size]).hexdigest()
        print(f"{key:16}: offset=0x{offset:x} size={size} sha256={digest}")
    slack = info["file_size"] - info["end_of_payloads"]
    print(f"{'slack':16}: {slack} bytes")
    if slack < 0:
        raise BootImageError("boot image is truncated: payloads exceed the file size")
    if args.expect_cmdline and args.expect_cmdline not in (info["cmdline"] or ""):
        raise BootImageError(f"cmdline does not contain {args.expect_cmdline!r}")
    return 0


def cmd_unpack(args):
    blob = _read(args.image, "boot image")
    info = parse(blob, args.image)
    os.makedirs(args.directory, exist_ok=True)
    written = []
    for key, (offset, size) in info["payloads"].items():
        path = os.path.join(args.directory, key)
        with open(path, "wb") as handle:
            handle.write(blob[offset:offset + size])
        written.append((key, path, size,
                        hashlib.sha256(blob[offset:offset + size]).hexdigest()))
    with open(os.path.join(args.directory, "cmdline"), "w", encoding="utf-8") as handle:
        handle.write((info["cmdline"] or "") + "\n")
    for key, path, size, digest in written:
        print(f"{key:8} {size:>10} {digest}  {path}")
    return 0


def cmd_pack(args):
    with open(args.cmdline, "r", encoding="utf-8") as handle:
        cmdline = handle.read().strip()
    if "\n" in cmdline:
        raise BootImageError(f"{args.cmdline}: command line must be a single line")
    if not cmdline:
        raise BootImageError(f"{args.cmdline}: empty command line")
    if os.path.exists(args.output) and not args.force:
        raise BootImageError(f"refusing to overwrite existing output: {args.output}")
    result = pack(args.kernel, args.dtb, cmdline, args.output,
                  os_version=args.os_version, os_patch_level=args.os_patch_level,
                  name=args.name)
    print(f"created {result['output']} ({result['size']} bytes)")
    print(f"kernel {result['kernel_size']} bytes sha256={result['kernel_sha256']}")
    print(f"dtb    {result['dtb_size']} bytes sha256={result['dtb_sha256']}")
    print(f"cmdline: {result['cmdline']}")
    print(f"id     {result['id']}")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    info = sub.add_parser("info", help="print the boot image header and payloads")
    info.add_argument("image")
    info.add_argument("--expect-cmdline", default="")
    info.set_defaults(func=cmd_info)

    unpack = sub.add_parser("unpack", help="extract payloads from a boot image")
    unpack.add_argument("image")
    unpack.add_argument("directory")
    unpack.set_defaults(func=cmd_unpack)

    packer = sub.add_parser("pack", help="build a Caihong boot image v2")
    packer.add_argument("--kernel", required=True)
    packer.add_argument("--dtb", required=True)
    packer.add_argument("--cmdline", required=True)
    packer.add_argument("--output", required=True)
    packer.add_argument("--os-version", default="16.0.0")
    packer.add_argument("--os-patch-level", default="2026-06")
    packer.add_argument("--name", default="")
    packer.add_argument("--force", action="store_true")
    packer.set_defaults(func=cmd_pack)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except BootImageError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
