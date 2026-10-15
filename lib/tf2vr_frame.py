#!/usr/bin/env python3
"""Helpers for install.sh and tf2vr-frame-launch.

Everything here is plain Python 3 with no third-party modules, so it runs natively on the
Steam Frame (ARM64 SteamOS), on x86 SteamOS and inside Steam's container runtime.

    tf2vr_frame.py find-game [STEAM_DIR...]      print STEAM, GAME, PREFIX lines (shell-quoted)
    tf2vr_frame.py has-steamvr STEAM             exit 0 if SteamVR is installed in any Steam library
    tf2vr_frame.py patch-loopback DLL            retarget the mod's process-loopback capture
    tf2vr_frame.py check-loopback DLL            print patched / unpatched / unknown
    tf2vr_frame.py verify-assets MANIFEST DIR    check asset_patcher.exe's output
    tf2vr_frame.py launch-args LAUNCH_JSON       the game arguments, one per line
    tf2vr_frame.py vc-version DLL                version of a Microsoft msvcp140.dll
    tf2vr_frame.py extract ZIP DEST [MEMBER...]  unzip (SteamOS has no unzip by default)
    tf2vr_frame.py split-cabs EXE DIR            cut the cabinets out of vc_redist.x64.exe
    tf2vr_frame.py set-launch-options STEAM WRAPPER    put the wrapper in Titanfall 2's launch options
    tf2vr_frame.py clear-launch-options STEAM WRAPPER  take it out again
    tf2vr_frame.py check-launch-options STEAM WRAPPER  exit 0 if it's already in for every account
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


STEAMVR_APPID = "250820"


def app_installed(steam, appid):
    """True if any Steam library has app APPID installed (it has an appmanifest there)."""
    return any(os.path.isfile(os.path.join(lib, "steamapps", "appmanifest_%s.acf" % appid))
               for lib in libraries(steam))


def cmd_has_steamvr(args):
    return 0 if app_installed(args[0], STEAMVR_APPID) else 1


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



# ------------------------------------------------------ launch options --
#
# Steam keeps each account's launch options in userdata/<account>/config/localconfig.vdf, under
# UserLocalConfigStore > Software > Valve > Steam > apps > <appid> > LaunchOptions. Steam reads it
# at start and writes it back on exit, so it may only be edited while Steam is closed.
# The file is edited structurally but otherwise kept byte-for-byte in its string contents: strings
# stay in their escaped form, only the one value we write is escaped by us.


class VdfError(Exception):
    pass


def vdf_load_raw(text):
    """[[key, value], ...] where value is a raw (still escaped) string or a nested list."""
    pos, n = 0, len(text)
    root = []
    stack = [root]
    key = None
    token = re.compile(r'\s+|//[^\n]*|"((?:[^"\\]|\\.)*)"|([{}])')
    while pos < n:
        m = token.match(text, pos)
        if not m:
            raise VdfError(f"unexpected text at offset {pos}: {text[pos:pos + 20]!r}")
        pos = m.end()
        quoted, brace = m.group(1), m.group(2)
        if brace == "{":
            if key is None:
                raise VdfError("block without a key")
            child = []
            stack[-1].append([key, child])
            stack.append(child)
            key = None
        elif brace == "}":
            if len(stack) == 1 or key is not None:
                raise VdfError("unbalanced braces")
            stack.pop()
        elif quoted is not None:
            if key is None:
                key = quoted
            else:
                stack[-1].append([key, quoted])
                key = None
    if len(stack) != 1 or key is not None:
        raise VdfError("file ends inside a block")
    return root


def vdf_dump_raw(node, depth=0):
    out = []
    tabs = "\t" * depth
    for key, value in node:
        if isinstance(value, list):
            out.append(f'{tabs}"{key}"\n{tabs}{{\n')
            out.append(vdf_dump_raw(value, depth + 1))
            out.append(f"{tabs}}}\n")
        else:
            out.append(f'{tabs}"{key}"\t\t"{value}"\n')
    return "".join(out)


def vdf_child(node, key, create=False):
    for entry in node:
        if entry[0].lower() == key.lower() and isinstance(entry[1], list):
            return entry[1]
    if not create:
        return None
    child = []
    node.append([key, child])
    return child


def vdf_escape(value):
    return value.replace("\\", "\\\\").replace('"', '\\"')


def vdf_unescape(value):
    return value.replace('\\"', '"').replace("\\\\", "\\")


def localconfigs(steam):
    base = os.path.join(steam, "userdata")
    try:
        accounts = sorted(os.listdir(base))
    except OSError:
        return []
    paths = (os.path.join(base, a, "config", "localconfig.vdf") for a in accounts if a.isdigit() and a != "0")
    return [p for p in paths if os.path.isfile(p)]


def with_wrapper(current, wrapper):
    """Launch options with the wrapper in front of %command%, keeping whatever else was there."""
    if wrapper in current:
        return current
    current = current.strip()
    if "%command%" in current:
        return current.replace("%command%", f"{wrapper} %command%", 1)
    return f"{wrapper} %command% {current}".strip()


def without_wrapper(current, wrapper):
    result = current.replace(f"{wrapper} %command%", "%command%").replace(wrapper, "").strip()
    return "" if result == "%command%" else result


def edit_launch_options(steam, wrapper, change):
    changed = []
    for path in localconfigs(steam):
        with open(path, encoding="utf-8", errors="surrogateescape") as fh:
            text = fh.read()
        tree = vdf_load_raw(text)
        node = vdf_child(tree, "UserLocalConfigStore")
        if node is None:
            continue
        for key in ("Software", "Valve", "Steam", "apps", APPID):
            node = vdf_child(node, key, create=True)
        entry = next((e for e in node if e[0].lower() == "launchoptions" and not isinstance(e[1], list)), None)
        old = vdf_unescape(entry[1]) if entry else ""
        new = change(old, wrapper)
        if new == old:
            continue
        if entry:
            entry[1] = vdf_escape(new)
        else:
            node.append(["LaunchOptions", vdf_escape(new)])
        backup = path + ".tf2vr-frame.bak"
        if not os.path.exists(backup):
            with open(backup, "w", encoding="utf-8", errors="surrogateescape") as fh:
                fh.write(text)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8", errors="surrogateescape") as fh:
            fh.write(vdf_dump_raw(tree))
        os.replace(tmp, path)
        changed.append(path)
    return changed


def cmd_set_launch_options(args):
    steam, wrapper = args
    if not localconfigs(steam):
        print("no Steam account found in userdata - sign in to Steam first", file=sys.stderr)
        return 1
    for path in edit_launch_options(steam, wrapper, with_wrapper):
        print(path)
    return 0


def launch_options_set(steam, wrapper):
    """True if every Steam account's Titanfall 2 launch options already run the wrapper."""
    paths = localconfigs(steam)
    for path in paths:
        with open(path, encoding="utf-8", errors="surrogateescape") as fh:
            node = vdf_child(vdf_load_raw(fh.read()), "UserLocalConfigStore")
        for key in ("Software", "Valve", "Steam", "apps", APPID):
            node = vdf_child(node, key) if node is not None else None
        entry = next((e for e in node or [] if e[0].lower() == "launchoptions" and not isinstance(e[1], list)), None)
        if entry is None or wrapper not in vdf_unescape(entry[1]):
            return False
    return bool(paths)


def cmd_check_launch_options(args):
    steam, wrapper = args
    return 0 if launch_options_set(steam, wrapper) else 1


def cmd_clear_launch_options(args):
    steam, wrapper = args
    for path in edit_launch_options(steam, wrapper, without_wrapper):
        print(path)
    return 0

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
    "has-steamvr": cmd_has_steamvr,
    "check-loopback": cmd_check_loopback,
    "patch-loopback": cmd_patch_loopback,
    "verify-assets": cmd_verify_assets,
    "launch-args": cmd_launch_args,
    "vc-version": cmd_vc_version,
    "split-cabs": cmd_split_cabs,
    "extract": cmd_extract,
    "set-launch-options": cmd_set_launch_options,
    "clear-launch-options": cmd_clear_launch_options,
    "check-launch-options": cmd_check_launch_options,
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
    except VdfError as e:
        print(f"couldn't read Steam's localconfig.vdf: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
