# Titanfall 2 VR on the Steam Frame

Play [CircuitLord's Titanfall 2 VR mod](https://github.com/CircuitLord/CircuitLordVRModInstaller) directly on a Steam Frame, with no PC to stream from.

The official installer only runs on Windows, and [tf2vr-linux](https://github.com/Monkellie/tf2vr-linux) only runs on x86_64 Linux PCs that stream to the headset. This repo installs the same mod files, but starts the game through Steam itself, so Steam's own x86 emulation (FEX) and Proton on the Frame do the work.

- Your normal Titanfall 2 stays playable: add `-flat` to start it without VR.
- Everything is downloaded from the official release links and checked against the official checksums. This repo contains no game or mod files.
- No path is hardcoded. Steam and the game are found from Steam's `libraryfolders.vdf`, so the game can be on internal storage, a microSD card or an external drive. At launch, every path comes from the command line Steam itself builds.

> **Status: untested on real Steam Frame hardware.** The scripts are tested against a simulated Steam launch (see [Tests](#tests)), and the audio fix is checked against the current mod release (1.0.17). Whether the Frame's standalone mode runs Proton VR games well enough for Titanfall 2 is the open question; see [What isn't known yet](#what-isnt-known-yet). Reports welcome.

## What you need

- **A Steam Frame** (or any SteamOS / Linux device with Steam: ARM64 or x86_64)
- **Titanfall 2 on Steam**, installed on the Frame, and **started once the normal way**: sign in to the EA app, wait for the main menu, then quit. That creates the game's Wine prefix and installs the EA app in it.
- A terminal on the Frame: desktop mode's Konsole, or SSH
- About 1 GB of free space for the download and the staged files (removed after the first launch)

## Install

1. **Run the installer on the Frame:**
   ```sh
   git clone https://github.com/MWGIH/TF2SteamFrame.git
   cd TF2SteamFrame
   ./install.sh
   ```
   It checks your setup first and says what's missing, if anything.
2. **Set Titanfall 2's launch options in Steam.** Titanfall 2 → Properties → General → Launch options, and paste the line `install.sh` printed. It looks like this, with your own home folder:
   ```
   /home/steamos/.local/share/tf2vr-frame/tf2vr-frame-launch %command%
   ```
   It's also saved in `~/.local/share/tf2vr-frame/launch-options.txt` to copy from.
3. **Press Play.** The first launch builds the mod's game assets first, which takes a few minutes before the EA app and the game appear. Later launches go straight into VR.

Leave Titanfall 2's Compatibility setting on whatever Proton Steam picks. Unlike tf2vr-linux, no custom Proton is needed.

## Play

Press **Play** in Steam. The launcher starts the EA app, waits for it to sign in, then starts the VR mod.

**Normal, flat game:** add `-flat` after `%command%` in the launch options, or switch it for every launch:
```sh
echo flat > ~/.config/tf2vr-frame/mode    # normal game
echo vr   > ~/.config/tf2vr-frame/mode    # VR again
```

Anything else you put after `%command%` is passed to the game, for example `+map sp_crashsite`.

For mod settings, controls and help with the mod itself, see [CircuitLord's Discord](https://discord.gg/MTKwud2cCP).

## Update

```sh
cd TF2SteamFrame
git pull
./install.sh
```
Then press Play. When there's a new mod release, the first launch after updating builds its assets again. `./install.sh --beta` installs the mod's beta channel instead.

## Uninstall

```sh
./install.sh --uninstall
```
Then clear Titanfall 2's launch options in Steam, or it won't start. Your VR campaign saves are kept.

## If something goes wrong

The launcher writes everything to `~/.local/state/tf2vr-frame/launch.log`.

| What you see | What to do |
|---|---|
| The game starts flat | Check the launch options are exactly what `install.sh` printed, and that `~/.config/tf2vr-frame/mode` doesn't say `flat`. |
| Titanfall 2 doesn't start at all | Look at the end of `launch.log`. If it's unreadable, remove the launch options to get the normal game back. |
| `install.sh`: `Titanfall 2 isn't installed in any Steam library` | Install it in Steam, or point at it: `./install.sh --game /path/to/Titanfall2`. |
| `install.sh`: `Steam not found` | Run `STEAM_DIR=/path/to/Steam ./install.sh`. |
| `install.sh`: `has no Wine prefix yet` | Start Titanfall 2 once normally from Steam (remove the launch options, or add `-flat`), sign in to the EA app, then quit. |
| `Setting up the mod failed` after the first Play | See `~/.local/state/tf2vr-frame/asset_patcher.log`, run `./install.sh` again, and press Play again. |
| `couldn't apply the audio fix to Titanfall2VR.dll` | A new mod release changed the code this patches. Open an issue. |
| The game says you're logged out of Origin, then quits | If the EA app's window asks you to sign in, do. Start the flat game once to check the EA app is signed in. |
| Crash with code `0xC0000409` (3221226505) | The audio fix isn't in place: run `./install.sh --force`. |
| Crash in `MSVCP140.dll` right after the mod loads | Run `./install.sh` again. |
| `Another mod replaced DirectX files` | Remove `dxgi.dll` and `d3d11.dll` (ReShade and similar) from the game folder. |

Logs worth attaching to an issue, collected after the game has closed:
- `~/.local/state/tf2vr-frame/launch.log`
- `Titanfall2/TF2VR/plugins/Titanfall2VR-data/engine.txt`
- the newest `Titanfall2/TF2VR/logs/nslog*.txt`
- the newest folder in `Titanfall2/TF2VR/crashes/`

`Titanfall2/` is the game folder: `<Steam library>/steamapps/common/Titanfall2`.

## How it works

### What stopped the mod from running on the Frame

Both existing ways of running the mod assume a PC:

1. **The official installer is a Windows program** (WPF/.NET). It finds the game through the Windows registry and `C:\Program Files (x86)\Steam`, and starts `crash_monitor.exe` itself.
2. **tf2vr-linux runs Proton's x86_64 Wine directly, outside Steam.** On the Frame, x86 programs only run through FEX inside Steam's own runtime, so `install.sh` there stops with "Proton's Wine can't run directly on this system". That affects every step that runs a Windows program: the asset build, the VC++ runtime install, and the game launch.
3. **tf2vr-linux's audio fix patches 6 bytes of x86_64 code in one particular Proton build** (`files/lib/wine/x86_64-windows/mmdevapi.dll`), and then needs Steam to use that private copy of Proton. On the Frame, Steam chooses the Proton build, and an ARM build of Proton doesn't have that code at all.
4. **tf2vr-linux starts SteamVR itself and clears Steam's VR environment** (`XR_RUNTIME_JSON`, `VR_*`), which is right for a PC streaming to a headset, but not when Steam sets up VR for a game on the headset itself.

### What this repo does instead

- **Steam starts everything.** `tf2vr-frame-launch` is set as the launch options' wrapper, so Steam hands it the exact command it was about to run: its runtime, its Proton (under FEX on the Frame), and the path to `Titanfall2.exe`. The wrapper runs that same command and only swaps `Titanfall2.exe` for itself, running inside Steam's runtime. From there it uses Steam's own `proton` to start the EA app, wait for it to sign in, and start `crash_monitor.exe` → `Titanfall2VRLauncher.exe` with the TF2VR profile and the arguments from the mod's `launch.json`, the same as the Windows installer's Play button. `SteamGameId`, the prefix and Proton's VR bridge are all set up by Steam, as for any game.
- **The asset build runs on the first Play.** The mod ships some files as patches that `asset_patcher.exe` builds from your game files. `install.sh` downloads and stages everything without touching the game folder; the first launch runs `asset_patcher.exe` the same way as above, then `install.sh --finish` checks every built file against the mod's checksums and copies the mod into the game folder, in the same layout as the official installer. `Titanfall2.exe` is never modified.
- **The VC++ runtime is copied, not installed.** The mod needs Microsoft's VC++ runtime 14.40 or newer in the prefix. `install.sh` unpacks the DLLs from Microsoft's `vc_redist.x64.exe` with `bsdtar` (part of SteamOS) and copies them into the prefix, so no Windows program has to run. Steam updates Proton on its own, so the launcher checks the runtime on every launch and puts it back if a Proton update replaced it.
- **The audio fix moves from Proton into the mod.** See below.

### Why is Titanfall2VR.dll patched?

The mod captures the game's audio (for haptics) by opening Windows' `VAD\Process_Loopback` device. Wine doesn't know that device, the call fails, and the mod crashes with `0xC0000409`. [polar421](https://github.com/polar421/Titanfall-2-VR-linux-fix) found that sending the request to the default playback device instead works, because Wine's PulseAudio driver supports loopback capture there; tf2vr-linux does it by patching Proton.

This repo makes the same change on the mod's side instead: in `Titanfall2VR.dll`, the one instruction that loads the `VAD\Process_Loopback` string is pointed at the string `{E6327CAD-DCEC-4949-AE8A-991E976A79D2}`, Windows' ID for "the default playback device", which Wine maps to exactly the device the Proton patch opens ([`get_mmdevice_by_activatepath`](https://github.com/ValveSoftware/wine/blob/experimental_10.0/dlls/mmdevapi/main.c)). The mod's DLL is x86_64 code on every device, so this works whatever Proton build Steam uses, and Steam can keep Proton up to date.

The patch is found by its pattern rather than at a fixed offset, writes the new string into unused space at the end of the DLL's read-only data, and is checked after it's applied. If a future mod release no longer matches, `install.sh` refuses and says so rather than guessing. Only the copy installed on the Frame is patched; the downloaded release is left as it is.

## What isn't known yet

These need someone with a Steam Frame to try:

- **VR from Proton games in standalone mode.** The mod renders through OpenXR via Proton's `wineopenxr`, which on a PC talks to SteamVR. Whether the Frame provides that to Proton games running under FEX on the headset is up to Valve's Frame software. Because Steam starts the game here exactly as it starts any Proton VR game, whatever Valve supports for those applies to this one too.
- **Performance.** Titanfall 2 plus the VR mod under x86 emulation on a mobile GPU may be too slow to be comfortable. The window size passed to the game can be changed with `TF2VR_FRAME_WIDTH` and `TF2VR_FRAME_HEIGHT` (default 1280×720, as on Windows).
- **The exact command line Steam builds on the Frame.** The wrapper looks for `Titanfall2.exe` and the `proton` script in it, and falls back to whatever follows the last `--`. If it finds neither, it starts the game unchanged and says so in `launch.log`; that log line is what's needed to adapt it.
- **The EA app on the Frame.** It has to install and sign in through Steam's normal first launch, as on any Linux device.

The same approach also works on x86 SteamOS (Steam Deck) and desktop Linux with Steam, which is a good way to test changes without a Frame.

## Tests

```sh
python3 -m unittest discover -s tests   # Steam library discovery and the Titanfall2VR.dll patch
bash tests/test_launch.sh               # the launch wrapper against a simulated Steam command and Proton
```

## Credits

- **[CircuitLord](https://github.com/CircuitLord/CircuitLordVRModInstaller)** for the Titanfall 2 VR mod and its installer (MIT).
- **[Monkellie's tf2vr-linux](https://github.com/Monkellie/tf2vr-linux)** (MIT), which this repo is based on: the install steps, the EA app handling and the VC++ runtime handling come from it. See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
- **[polar421](https://github.com/polar421/Titanfall-2-VR-linux-fix)** for getting the mod running on Proton first, and for finding the audio fix.
- **[Northstar](https://github.com/R2Northstar/Northstar)**, the mod loader the VR mod runs on.

This is a community project. It isn't affiliated with or endorsed by Respawn, EA, Valve or CircuitLord.

## License

[GPL-3.0](LICENSE). Parts derived from tf2vr-linux keep its MIT notice in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). The mod, Northstar and the game have their own licenses and aren't included here.
