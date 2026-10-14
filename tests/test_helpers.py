#!/usr/bin/env python3
"""Unit tests for lib/tf2vr_frame.py. Run: python3 -m unittest discover -s tests"""
import os
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
import tf2vr_frame as t  # noqa: E402


def build_pe(rdata_slack=0x100, refs=1):
    """A minimal PE32+ image: .text with `lea rcx,[rip+X]` loading L"VAD\\Process_Loopback" from .rdata."""
    text_va, rdata_va, data_va = 0x1000, 0x2000, 0x3000
    falign = 0x200
    hdr = bytearray(0x400)
    hdr[0:2] = b"MZ"
    struct.pack_into("<I", hdr, 0x3C, 0x80)
    hdr[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<HH", hdr, 0x84, 0x8664, 3)  # machine, sections
    opt = 0xF0
    struct.pack_into("<H", hdr, 0x84 + 16, opt)
    sec0 = 0x80 + 24 + opt

    string_off = 0x40
    rdata = bytearray(falign)
    rdata[string_off:string_off + len(t.LOOPBACK)] = t.LOOPBACK
    rdata_vsize = falign - rdata_slack

    text = bytearray(b"\x90" * falign)
    for k in range(refs):
        at = 0x10 + 0x20 * k
        disp = (rdata_va + string_off) - (text_va + at + 7)
        text[at:at + 3] = b"\x48\x8d\x0d"
        struct.pack_into("<i", text, at + 3, disp)

    data = bytearray(falign)
    sections = [(b".text", text_va, 0x100, text, 0x60000020),
                (b".rdata", rdata_va, rdata_vsize, rdata, 0x40000040),
                (b".data", data_va, 0x100, data, 0xC0000040)]
    body = bytearray()
    for i, (name, va, vsize, raw, flags) in enumerate(sections):
        o = sec0 + 40 * i
        hdr[o:o + 8] = name.ljust(8, b"\0")
        struct.pack_into("<IIII", hdr, o + 8, vsize, va, len(raw), len(hdr) + len(body))
        struct.pack_into("<I", hdr, o + 36, flags)
        body += raw
    return bytes(hdr + body)


class LoopbackPatch(unittest.TestCase):
    def write(self, data):
        fd, path = tempfile.mkstemp(suffix=".dll")
        os.write(fd, data)
        os.close(fd)
        self.addCleanup(os.remove, path)
        return path

    def test_patch_points_lea_at_render_guid(self):
        path = self.write(build_pe())
        self.assertEqual(t.loopback_state(open(path, "rb").read())[0], "unpatched")
        self.assertEqual(t.patch_loopback(path)[0], "patched")
        data = open(path, "rb").read()
        self.assertEqual(t.loopback_state(data)[0], "patched")
        sections = t.pe_sections(data)
        # the lea now resolves to the GUID string, and .rdata's VirtualSize covers it
        disp = struct.unpack_from("<i", data, 0x400 + 0x10 + 3)[0]
        target = 0x1000 + 0x10 + 7 + disp
        rdata = sections[1]
        off = rdata["rptr"] + target - rdata["va"]
        self.assertEqual(data[off:off + len(t.RENDER)], t.RENDER)
        self.assertLessEqual(target + len(t.RENDER), rdata["va"] + rdata["vsize"])
        # the original string is left in place
        self.assertIn(t.LOOPBACK, data)

    def test_patch_is_idempotent(self):
        path = self.write(build_pe())
        t.patch_loopback(path)
        first = open(path, "rb").read()
        self.assertEqual(t.patch_loopback(path)[0], "patched")
        self.assertEqual(open(path, "rb").read(), first)

    def test_refuses_without_room(self):
        path = self.write(build_pe(rdata_slack=0x10))
        before = open(path, "rb").read()
        self.assertEqual(t.patch_loopback(path)[0], "unknown")
        self.assertEqual(open(path, "rb").read(), before)

    def test_refuses_when_ambiguous(self):
        path = self.write(build_pe(refs=2))
        self.assertEqual(t.patch_loopback(path)[0], "unknown")

    def test_not_a_pe(self):
        path = self.write(b"hello")
        with self.assertRaises(t.PeError):
            t.patch_loopback(path)


class SteamDiscovery(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = self.tmp.name
        self.steam = os.path.join(root, "home/.local/share/Steam")
        self.sd = os.path.join(root, "run/media/mmcblk0p1")
        os.makedirs(os.path.join(self.steam, "steamapps"))
        os.makedirs(os.path.join(self.sd, "steamapps/common/titanfall2"))
        open(os.path.join(self.sd, "steamapps/common/titanfall2/Titanfall2.exe"), "w").close()
        with open(os.path.join(self.steam, "steamapps/libraryfolders.vdf"), "w") as fh:
            fh.write('"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"%s"\n\t\t"apps"\n\t\t{\n\t\t}\n\t}\n'
                     '\t"1"\n\t{\n\t\t"path"\t\t"%s"\n\t\t"apps"\n\t\t{\n\t\t\t"1237970"\t\t"1"\n\t\t}\n\t}\n}\n'
                     % (self.steam, self.sd))
        with open(os.path.join(self.sd, "steamapps/appmanifest_1237970.acf"), "w") as fh:
            fh.write('"AppState"\n{\n\t"appid"\t\t"1237970"\n\t"installdir"\t\t"Titanfall2"\n}\n')

    def test_game_on_sd_card_prefix_on_internal_storage(self):
        # exFAT cards can't hold a prefix, so Steam keeps it in another library
        os.makedirs(os.path.join(self.steam, "steamapps/compatdata/1237970/pfx"))
        game, prefix = t.find_game(self.steam)
        self.assertEqual(game, os.path.realpath(os.path.join(self.sd, "steamapps/common/titanfall2")))
        self.assertEqual(prefix, os.path.realpath(os.path.join(self.steam, "steamapps/compatdata/1237970")))

    def test_prefix_next_to_game_preferred(self):
        os.makedirs(os.path.join(self.steam, "steamapps/compatdata/1237970/pfx"))
        os.makedirs(os.path.join(self.sd, "steamapps/compatdata/1237970/pfx"))
        _, prefix = t.find_game(self.steam)
        self.assertEqual(prefix, os.path.realpath(os.path.join(self.sd, "steamapps/compatdata/1237970")))

    def test_not_installed(self):
        os.remove(os.path.join(self.sd, "steamapps/common/titanfall2/Titanfall2.exe"))
        self.assertEqual(t.find_game(self.steam), (None, None))

    def test_vdf_escapes(self):
        parsed = t.parse_vdf('"a"\n{\n\t"path"\t\t"D:\\\\Games\\\\Steam"\n}\n')
        self.assertEqual(parsed["a"]["path"], "D:\\Games\\Steam")


if __name__ == "__main__":
    unittest.main()
