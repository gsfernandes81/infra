#!/usr/bin/env python3
"""Writes a hand-built btrfs send stream, protocol 1, to stdout: what a compromised zero
could send to three's mirror-receive, and `btrfs send` itself never emits. host/three.sh
pipes each one through the backup key and three-backup.sh checks what it changed.

Each stream makes one new subvolume, then uses paths with `..` that `btrfs receive
--chroot` resolves inside the name's directory, beside every earlier snapshot:

  symlink <abs> <rel>  subvolume junk-symlink, then ../evil-abs -> <abs> and
                     ../evil-rel -> <rel>: links a clean-up that went by name would follow
                     into a root delete of the subvolume they name
  rename <old>       subvolume junk-rename, then rename ../<old> to ../.moved
  dot                subvolume .junk-dot, a name a shell glob does not list

The format is btrfs-progs' send-stream.h: a 17-byte header, then commands, each a 10-byte
header (payload length, command, CRC32C) and attributes (type, length, value). The CRC is
the kernel's crc32c with seed 0 over the command with its CRC field zeroed.
"""
import os
import struct
import sys

SUBVOL, SYMLINK, RENAME, END = 1, 8, 9, 21
A_UUID, A_CTRANSID, A_INO, A_PATH, A_PATH_TO, A_PATH_LINK = 1, 2, 3, 15, 16, 17

_TABLE = []
for i in range(256):
    c = i
    for _ in range(8):
        c = (c >> 1) ^ 0x82F63B78 if c & 1 else c >> 1
    _TABLE.append(c)


def crc32c(data, crc=0):
    for b in data:
        crc = _TABLE[(crc ^ b) & 0xFF] ^ (crc >> 8)
    return crc


def tlv(kind, value):
    if isinstance(value, str):
        value = value.encode()
    return struct.pack("<HH", kind, len(value)) + value


def u64(n):
    return struct.pack("<Q", n)


def cmd(kind, *attrs):
    payload = b"".join(attrs)
    head = struct.pack("<IHI", len(payload), kind, 0)
    crc = crc32c(head + payload)
    return struct.pack("<IHI", len(payload), kind, crc) + payload


def subvol(name):
    return cmd(SUBVOL, tlv(A_PATH, name), tlv(A_UUID, os.urandom(16)), tlv(A_CTRANSID, u64(7)))


def main():
    kind = sys.argv[1] if len(sys.argv) > 1 else ""
    out = [b"btrfs-stream\0" + struct.pack("<I", 1)]
    if kind == "symlink" and len(sys.argv) == 4:
        out += [
            subvol("junk-symlink"),
            cmd(SYMLINK, tlv(A_PATH, "../evil-abs"), tlv(A_INO, u64(257)), tlv(A_PATH_LINK, sys.argv[2])),
            cmd(SYMLINK, tlv(A_PATH, "../evil-rel"), tlv(A_INO, u64(258)), tlv(A_PATH_LINK, sys.argv[3])),
        ]
    elif kind == "rename" and len(sys.argv) == 3:
        out += [subvol("junk-rename"), cmd(RENAME, tlv(A_PATH, "../" + sys.argv[2]), tlv(A_PATH_TO, "../.moved"))]
    elif kind == "dot":
        out += [subvol(".junk-dot")]
    else:
        sys.exit("usage: bad-stream.py symlink <abs> <rel> | rename <old snapshot> | dot")
    out.append(cmd(END))
    sys.stdout.buffer.write(b"".join(out))


main()
