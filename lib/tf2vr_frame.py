#!/usr/bin/env python3
"""Helpers for install.sh and tf2vr-frame-launch.

Everything here is plain Python 3 with no third-party modules, so it runs natively on the
Steam Frame (ARM64 SteamOS), on x86 SteamOS and inside Steam's container runtime.

    tf2vr_frame.py find-game [STEAM_DIR...]      print STEAM, GAME, PREFIX lines (shell-quoted)
    tf2vr_frame.py patch-loopback DLL            retarget the mod's process-loopback capture
    tf2vr_frame.py check-loopback DLL            print patched / unpatched / unknown
    tf2vr_frame.py verify-assets MANIFEST DIR    check asset_patcher.exe's output
    tf2vr_frame.py launch-args LAUNCH_JSON       the game arguments, one per line
    tf2vr_frame.py vc-version DLL                version of a Microsoft msvcp140.dll
    tf2vr_frame.py extract ZIP DEST [MEMBER...]  unzip (SteamOS has no unzip by default)
    tf2vr_frame.py split-cabs EXE DIR            cut the cabinets out of vc_redist.x64.exe
"""
import hashlib
import json
import os
import re
import shlex
import struct
import sys
import zipfile

APPID = "1237970"

# --------------------------------------------------------------- Steam --


def parse_vdf(text):
    """Minimal parser for Steam's text KeyValues (libraryfolders.vdf, appmanifest_*.acf)."""
    tokens = re.findall(r'"((?:[^"\\]|\\.)*)"|([{}])', text)
    stack = [{}]
    key = None
    for quoted, brace in tokens:
        if brace == "{":
            child = {}
            stack[-1][key] = child
            stack.append(child)
            key = None
        elif brace == "}":
            if len(stack) > 1:
                stack.pop()
            key = None
        else:
            value = quoted.replace("\\\\", "\\").replace('\\"', '"')
            if key is None:
                key = value
            else:
                stack[-1][key] = value
                key = None
    return stack[0]


def lower_keys(node):
    if isinstance(node, dict):
        return {k.lower(): lower_keys(v) for k, v in node.items()}
    return node


def steam_candidates(extra):
    home = os.path.expanduser("~")
    for c in list(extra) + [
        os.path.join(home, ".local/share/Steam"),
        os.path.join(home, ".steam/steam"),
        os.path.join(home, ".steam/root"),
        os.path.join(home, ".steam/debian-installation"),
        os.path.join(home, ".var/app/com.valvesoftware.Steam/.local/share/Steam"),
    ]:
        if c and os.path.isfile(os.path.join(c, "steamapps", "libraryfolders.vdf")):
            yield os.path.realpath(c)


def libraries(steam):
    """Every Steam library folder: the Steam root, then each entry of libraryfolders.vdf
    (internal storage, microSD cards, external drives), in Steam's order."""
    seen = []

    def add(path):
        path = os.path.realpath(path)
        if path not in seen and os.path.isdir(os.path.join(path, "steamapps")):
            seen.append(path)

    add(steam)
    try:
        with open(os.path.join(steam, "steamapps", "libraryfolders.vdf"), encoding="utf-8", errors="replace") as fh:
            data = lower_keys(parse_vdf(fh.read()))
    except OSError:
        data = {}
    folders = data.get("libraryfolders", {})
    for entry in folders.values():
        if isinstance(entry, dict) and entry.get("path"):
            add(entry["path"])
        elif isinstance(entry, str) and entry.startswith("/"):
            add(entry)  # very old format: "1" "/path"
    return seen


def find_game(steam):
    """(game dir, prefix dir) for Titanfall 2 in any of this Steam's libraries."""
    libs = libraries(steam)
    game = None
    for lib in libs:
        manifest = os.path.join(lib, "steamapps", f"appmanifest_{APPID}.acf")
        installdir = "Titanfall2"
        if os.path.isfile(manifest):
            try:
                with open(manifest, encoding="utf-8", errors="replace") as fh:
                    state = lower_keys(parse_vdf(fh.read())).get("appstate", {})
                installdir = state.get("installdir") or installdir
            except OSError:
                pass
        common = os.path.join(lib, "steamapps", "common")
        candidate = nocase(os.path.join(common, installdir))
        if candidate and has_exe(candidate):
            game = os.path.realpath(candidate)
            game_lib = lib
            break
    if not game:
        return None, None
    # Steam keeps the prefix in the game's library, unless that drive can't hold one (exFAT/NTFS),
    # in which case it lives in another library.
    prefix = None
    for lib in [game_lib] + [l for l in libs if l != game_lib]:
        p = os.path.join(lib, "steamapps", "compatdata", APPID)
        if os.path.isdir(os.path.join(p, "pfx")):
            prefix = os.path.realpath(p)
            break
    if prefix is None:
        prefix = os.path.join(game_lib, "steamapps", "compatdata", APPID)
    return game, prefix


def has_exe(folder):
    try:
        return any(e.lower() == "titanfall2.exe" for e in os.listdir(folder))
    except OSError:
        return False


def nocase(path):
    """Resolve path case-insensitively; Windows games are often installed with odd casing."""
    if os.path.exists(path):
        return path
    cur = "/"
    for part in [x for x in path.split("/") if x]:
        nxt = os.path.join(cur, part)
        if not os.path.exists(nxt):
            try:
                match = [e for e in os.listdir(cur) if e.lower() == part.lower()]
            except OSError:
                return None
            if not match:
                return None
            nxt = os.path.join(cur, match[0])
        cur = nxt
    return cur


def cmd_find_game(args):
    for steam in steam_candidates(args):
        game, prefix = find_game(steam)
        print(f"STEAM={shlex.quote(steam)}")
        print(f"GAME={shlex.quote(game or '')}")
        print(f"PREFIX={shlex.quote(prefix or '')}")
        return 0
    print("STEAM=''\nGAME=''\nPREFIX=''")
    return 0


# ------------------------------------------------------ loopback patch --
#
# The mod captures the game's own audio (for haptics) with
#   ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, ...)
# Wine's mmdevapi doesn't know the "VAD\Process_Loopback" device, the call fails, and the mod
# fast-fails with 0xC0000409. tf2vr-linux fixes that by patching a jump inside Proton's
# x86_64 mmdevapi.dll so unknown paths fall through to the default render endpoint.
#
# That patch is tied to one x86_64 build of Proton. On the Steam Frame, Steam picks the Proton
# build (and it may be an ARM64/ARM64EC build run with FEX), so a byte patch of Proton can't be
# relied on. Instead we make the same change on the mod's side: point the one instruction that
# loads the "VAD\Process_Loopback" string at the DEVINTERFACE_AUDIO_RENDER GUID string, which
# every Wine/Proton maps to the default render endpoint (dlls/mmdevapi/main.c,
# get_mmdevice_by_activatepath). Wine then opens exactly the device the Proton patch opened, and
# the mod's AUDCLNT_STREAMFLAGS_LOOPBACK capture on it works through winepulse as before.
# The mod's DLL is x86_64 code on every platform, so this works whatever Proton Steam uses.

LOOPBACK = "VAD\\Process_Loopback\0".encode("utf-16-le")
RENDER = "{E6327CAD-DCEC-4949-AE8A-991E976A79D2}\0".encode("utf-16-le")
IMAGE_SCN_CNT_CODE = 0x20
IMAGE_SCN_MEM_EXECUTE = 0x20000000


class PeError(Exception):
    pass


def pe_sections(data):
    if data[:2] != b"MZ":
        raise PeError("not a PE file")
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        raise PeError("not a PE file")
    count = struct.unpack_from("<H", data, pe + 6)[0]
    opt_size = struct.unpack_from("<H", data, pe + 20)[0]
    sections = []
    for i in range(count):
        o = pe + 24 + opt_size + 40 * i
        vsize, va, rsize, rptr = struct.unpack_from("<IIII", data, o + 8)
        flags = struct.unpack_from("<I", data, o + 36)[0]
        sections.append({"header": o, "name": data[o:o + 8].rstrip(b"\0").decode("ascii", "replace"),
                         "va": va, "vsize": vsize, "rptr": rptr, "rsize": rsize, "flags": flags})
    return sections


def off_to_rva(sections, off):
    for s in sections:
        if s["rptr"] <= off < s["rptr"] + s["rsize"]:
            return s["va"] + off - s["rptr"]
    return None


def lea_refs(data, sections, rva):
    """File offsets of `lea r64, [rip+disp32]` instructions in code sections that load rva."""
    hits = []
    for s in sections:
        if not s["flags"] & (IMAGE_SCN_CNT_CODE | IMAGE_SCN_MEM_EXECUTE):
            continue
        start, end = s["rptr"], s["rptr"] + s["rsize"] - 7
        o = data.find(b"\x8d", start + 1)
        while 0 <= o < end + 1:
            i = o - 1
            if data[i] in (0x48, 0x4C) and (data[i + 2] & 0xC7) == 0x05:
                disp = struct.unpack_from("<i", data, i + 3)[0]
                if s["va"] + (i - s["rptr"]) + 7 + disp == rva:
                    hits.append(i)
            o = data.find(b"\x8d", o + 1)
    return hits


def loopback_state(data):
    """('patched'|'unpatched'|'unknown', detail)"""
    sections = pe_sections(data)
    found = []
    for needle, state in ((LOOPBACK, "unpatched"), (RENDER, "patched")):
        pos = data.find(needle)
        while pos >= 0:
            rva = off_to_rva(sections, pos)
            if rva is not None:
                for ref in lea_refs(data, sections, rva):
                    found.append((state, ref, pos))
            pos = data.find(needle, pos + 2)
    states = {f[0] for f in found}
    if len(found) == 1:
        return found[0][0], found[0]
    if not found:
        return "unknown", "no instruction loads the loopback device path"
    if states == {"patched"} or states == {"unpatched"}:
        return "unknown", f"{len(found)} instructions load the device path; expected one"
    return "unknown", "partly patched"


def patch_loopback(path):
    with open(path, "rb") as fh:
        data = bytearray(fh.read())
    state, detail = loopback_state(bytes(data))
    if state != "unpatched":
        return state, detail
    _, ref, _ = detail
    sections = pe_sections(bytes(data))
    lea_rva = off_to_rva(sections, ref)
    # Put the GUID string in the unused tail of a read-only data section: between the end of
    # its data (VirtualSize) and the end of its file space (SizeOfRawData), and before the
    # next section starts in memory. Then grow VirtualSize to cover it.
    ordered = sorted(sections, key=lambda s: s["va"])
    for idx, s in enumerate(ordered):
        if s["flags"] & (IMAGE_SCN_CNT_CODE | IMAGE_SCN_MEM_EXECUTE) or not s["rsize"]:
            continue
        if s["flags"] & 0x80000000:  # writable: keep the string read-only like the original
            continue
        start = (s["vsize"] + 15) & ~15
        end = start + len(RENDER)
        next_va = ordered[idx + 1]["va"] if idx + 1 < len(ordered) else None
        if end > s["rsize"] or (next_va is not None and s["va"] + end > next_va):
            continue
        if any(data[s["rptr"] + start:s["rptr"] + end]):
            continue
        data[s["rptr"] + start:s["rptr"] + end] = RENDER
        struct.pack_into("<I", data, s["header"] + 8, end)
        target = s["va"] + start
        struct.pack_into("<i", data, ref + 3, target - (lea_rva + 7))
        break
    else:
        return "unknown", "no room in the DLL for the device path"
    state, detail = loopback_state(bytes(data))
    if state != "patched":
        return "unknown", f"patch didn't verify: {detail}"
    tmp = path + ".tmp"
    with open(tmp, "wb") as fh:
        fh.write(data)
    os.replace(tmp, path)
    return "patched", detail


def cmd_check_loopback(args):
    with open(args[0], "rb") as fh:
        state, detail = loopback_state(fh.read())
    print(state)
    if state == "unknown":
        print(detail, file=sys.stderr)
    return 0


def cmd_patch_loopback(args):
    state, detail = patch_loopback(args[0])
    print(state)
    if state != "patched":
        print(detail, file=sys.stderr)
        return 1
    return 0


# -------------------------------------------------------------- assets --


def cmd_verify_assets(args):
    with open(args[0], encoding="utf-8") as fh:
        outputs = json.load(fh)["outputs"]
    bad = []
    for rel, sha in outputs.items():
        p = os.path.join(args[1], rel)
        if not os.path.isfile(p):
            bad.append(rel)
            continue
        h = hashlib.sha256()
        with open(p, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
        if h.hexdigest() != sha:
            bad.append(rel)
    if bad:
        print(f"{len(bad)} of {len(outputs)} built files are missing or wrong, e.g. {bad[0]}", file=sys.stderr)
        return 1
    print(f"{len(outputs)} files verified")
    return 0


def cmd_launch_args(args):
    """Arguments from the mod's launch.json, filled in the way the Windows installer does."""
    with open(args[0], encoding="utf-8") as fh:
        s = json.load(fh)
    width = os.environ.get("TF2VR_FRAME_WIDTH", "1280")
    height = os.environ.get("TF2VR_FRAME_HEIGHT", "720")
    for arg in s["arguments"] + s.get("vrArguments", []):
        print(arg.replace("{profile}", "TF2VR").replace("{width}", width)
                 .replace("{height}", height).replace("{sound}", "1"))
    return 0


# ---------------------------------------------------------- VC runtime --


def cmd_vc_version(args):
    """Version of msvcp140.dll when it's Microsoft's own build; nothing for Wine's built-in copy."""
    try:
        with open(args[0], "rb") as fh:
            data = fh.read()
    except OSError:
        return 0
    i = data.find("VS_VERSION_INFO".encode("utf-16-le"))
    j = data.find(b"\xbd\x04\xef\xfe", i) if i >= 0 else -1
    if j >= 0 and b"Wine builtin DLL" not in data[:0x100]:
        ms, ls = struct.unpack_from("<II", data, j + 8)
        print(f"{ms >> 16}.{ms & 0xffff}.{ls >> 16}.{ls & 0xffff}")
    return 0


def cmd_split_cabs(args):
    data = open(args[0], "rb").read()
    i = n = 0
    while (i := data.find(b"MSCF\0\0\0\0", i)) >= 0:
        size = struct.unpack_from("<I", data, i + 8)[0]
        if 0 < size <= len(data) - i:
            with open(os.path.join(args[1], f"bundle{n}.cab"), "wb") as fh:
                fh.write(data[i:i + size])
            n, i = n + 1, i + size
        else:
            i += 4
    return 0 if n else 1


# ---------------------------------------------------------------- misc --


def cmd_extract(args):
    archive, dest, members = args[0], args[1], args[2:]
    dest_real = os.path.realpath(dest)
    with zipfile.ZipFile(archive) as z:
        for info in z.infolist():
            name = info.filename
            if members and not any(name == m or (m.endswith("/") and name.startswith(m)) for m in members):
                continue
            target = os.path.realpath(os.path.join(dest, name))
            if not (target == dest_real or target.startswith(dest_real + os.sep)):
                raise SystemExit(f"refusing to extract {name} outside {dest}")
            z.extract(info, dest)
    return 0


COMMANDS = {
    "find-game": cmd_find_game,
    "check-loopback": cmd_check_loopback,
    "patch-loopback": cmd_patch_loopback,
    "verify-assets": cmd_verify_assets,
    "launch-args": cmd_launch_args,
    "vc-version": cmd_vc_version,
    "split-cabs": cmd_split_cabs,
    "extract": cmd_extract,
}


def main(argv):
    if len(argv) < 2 or argv[1] not in COMMANDS:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        return COMMANDS[argv[1]](argv[2:])
    except PeError as e:
        print("unknown")
        print(e, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
