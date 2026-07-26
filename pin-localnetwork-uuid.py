# Overwrite this binary's LC_UUID with the one that holds this Mac's Local
# Network grant, per-arch. The grant is UUID-keyed and the grant DB is wedged
# (new UUIDs never get granted), so pinning the UUID is what keeps a rebuilt
# Ellipse Control reachable. Run from build.sh before codesign.
import struct, sys, uuid

path = sys.argv[1]
# arch cputype -> target uuid
TARGETS = {
    0x0100000C: uuid.UUID("F628CF84-5755-333F-947A-D0AB99FE6EEE"),  # arm64
    0x01000007: uuid.UUID("D59D3C7C-C532-3F2A-BD39-8C707A9116F1"),  # x86_64
}
LC_UUID = 0x1B

data = bytearray(open(path, "rb").read())

def patch_thin(base, target):
    magic = struct.unpack_from("<I", data, base)[0]
    if magic in (0xFEEDFACF,):        # 64-bit LE
        ncmds = struct.unpack_from("<I", data, base+16)[0]
        off = base + 32
    elif magic in (0xFEEDFACE,):      # 32-bit LE
        ncmds = struct.unpack_from("<I", data, base+16)[0]
        off = base + 28
    else:
        print("  onbekende thin magic %#x" % magic); return False
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == LC_UUID:
            data[off+8:off+24] = target.bytes
            print("  LC_UUID @%d -> %s" % (off, target))
            return True
        off += cmdsize
    return False

magic = struct.unpack_from(">I", data, 0)[0]
if magic in (0xCAFEBABE, 0xCAFEBABF):        # fat
    nfat = struct.unpack_from(">I", data, 4)[0]
    p = 8
    for _ in range(nfat):
        if magic == 0xCAFEBABE:
            cputype, cpusub, offset, size, align = struct.unpack_from(">IIIII", data, p); p += 20
        else:
            cputype, cpusub, offset, size, align, res = struct.unpack_from(">IIQQII", data, p); p += 32
        tgt = TARGETS.get(cputype)
        if tgt: patch_thin(offset, tgt)
        else:   print("  arch %#x niet in doelen" % cputype)
else:
    # thin: pick target by header cputype
    cputype = struct.unpack_from("<I", data, 4)[0]
    patch_thin(0, TARGETS.get(cputype))

open(path, "wb").write(data)
print("geschreven:", path)
