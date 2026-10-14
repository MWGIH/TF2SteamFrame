# Titanfall 2 VR on the Steam Frame

Play [CircuitLord's Titanfall 2 VR mod](https://github.com/CircuitLord/CircuitLordVRModInstaller) directly on a Steam Frame, with no PC to stream from.

The official installer only runs on Windows, and [tf2vr-linux](https://github.com/Monkellie/tf2vr-linux) only runs on x86_64 Linux PCs that stream to the headset. This repo installs the same mod files, but starts the game through Steam itself, so Steam's own x86 emulation (FEX) and Proton on the Frame do the work.

- Your normal Titanfall 2 stays playable: add `-flat` to start it without VR.
- Everything is downloaded from the official release links and checked against the official checksums. This repo contains no game or mod files.
- No path is hardcoded. Steam and the game are found from Steam's `libraryfolders.vdf`, so the game can be on internal storage, a microSD card or an external drive. At launch, every path comes from the command line Steam itself builds.

> Made with AI assistance and a human in the loop; see [AI disclosure](#ai-disclosure).
>
> **Status: untested on real Steam Frame hardware.** The scripts are tested against a simulated Steam launch (see [Tests](#tests)), and the audio fix is checked against the current mod release (1.0.17). Whether the Frame's standalone mode runs Proton VR games well enough for Titanfall 2 is the open question; see [What isn't known yet](#what-isnt-known-yet). Reports welcome.

## Based on

This repo adapts two existing projects for the Steam Frame. All credit for the mod and the Linux groundwork goes to their authors:

| Project | What it is | What this repo uses from it |
|---|---|---|
| [CircuitLord/CircuitLordVRModInstaller](https://github.com/CircuitLord/CircuitLordVRModInstaller) by [CircuitLord](https://github.com/CircuitLord) | The Titanfall 2 VR mod and its official Windows installer (MIT) | The mod itself, its release manifest and checksums, the Northstar version it pins, and the file layout and launch arguments its Play button uses |
| [Monkellie/tf2vr-linux](https://github.com/Monkellie/tf2vr-linux) by [Monkellie](https://github.com/Monkellie) | Runs the mod on x86_64 Linux PCs through Proton (MIT) | The install steps, the EA app handling and the VC++ runtime handling, reworked to run through Steam on the Frame |
| [polar421/Titanfall-2-VR-linux-fix](https://github.com/polar421/Titanfall-2-VR-linux-fix) by [polar421](https://github.com/polar421) | The first working Proton setup for the mod | The audio fix (sending the mod's loopback capture to the default playback device), applied here to the mod's DLL instead of to Proton |
| [R2Northstar/Northstar](https://github.com/R2Northstar/Northstar) | The Titanfall 2 mod loader the VR mod runs on | Downloaded at the version CircuitLord's installer pins |

## Install on the Steam Frame

Two things in Steam first, then one command.

**1. Start Titanfall 2 once the normal way.** Install Titanfall 2 in Steam and press Play. Sign in to the EA app when it appears, wait for the game's main menu, then quit. This sets up the EA app and the game's Wine prefix, which VR reuses.

**2. Open Konsole.** Switch to desktop mode from the power menu (as on the Steam Deck) and open **Konsole** from the application launcher. Any terminal on the Frame works, including SSH from another computer.

**3. Paste this command and press Enter:**

```sh
curl -fsSL https://raw.githubusercontent.com/MWGIH/TF2SteamFrame/main/setup.sh | bash
```

That's the whole install. The command:
- downloads this repo into `~/TF2SteamFrame`,
- finds Steam, Titanfall 2 and its Wine prefix in any of your Steam libraries (internal storage, microSD card or external drive),
- downloads the mod and Northstar from their official releases and checks their checksums,
- copies Microsoft's VC++ runtime into the game's prefix and applies the audio fix,
- **sets Titanfall 2's launch options in Steam for you.** Steam only reads launch options when it starts, so the installer asks `Close Steam now? [Y/n]`: press Enter, and it closes Steam, sets them, and opens Steam again.

When it says **All set**, go back to game mode, put the headset on and press **Play** on Titanfall 2. The first launch builds the mod's game assets before anything appears, which takes a few minutes. After that, Play goes straight into VR.

Nothing needs installing with `pacman`, and SteamOS's read-only system isn't touched: everything goes into your home folder and the game folder. You need an internet connection and about 1 GB of free space.

### If you'd rather set the launch options yourself

Run the installer with `--no-launch-options`:
```sh
curl -fsSL https://raw.githubusercontent.com/MWGIH/TF2SteamFrame/main/setup.sh | bash -s -- --no-launch-options
```
Then in Steam open Titanfall 2 → **Properties** → **General** → **Launch options** and paste the line the installer printed. It looks like this, with your own home folder:
```
/home/steamos/.local/share/tf2vr-frame/tf2vr-frame-launch %command%
```
It's also saved in `~/.local/share/tf2vr-frame/launch-options.txt` to copy from. If Titanfall 2 already had launch options, the installer keeps them and adds its part in front of `%command%`.

Leave Titanfall 2's **Compatibility** setting on whatever Proton Steam picks. No custom Proton is needed.

### Other install options

Add these after `bash -s --` in the command above, or pass them to `~/TF2SteamFrame/install.sh`:

| Option | What it does |
|---|---|
| `--check` | Only check your setup, change nothing |
| `--beta` | Install the mod's beta channel |
| `--force` | Reinstall even if it's up to date |
| `--yes` | Close and reopen Steam without asking |
| `--game DIR` | Use this Titanfall 2 folder, if it isn't found |

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

Run the same command again:
```sh
curl -fsSL https://raw.githubusercontent.com/MWGIH/TF2SteamFrame/main/setup.sh | bash
```
Then press Play. When there's a new mod release, the first launch after updating builds its assets again.

## Uninstall

```sh
~/TF2SteamFrame/install.sh --uninstall
```
It removes the mod files and takes the launcher back out of Titanfall 2's launch options (closing Steam for a moment, like the install). Your VR campaign saves are kept.

## If something goes wrong

The launcher writes everything to `~/.local/state/tf2vr-frame/launch.log`.

| What you see | What to do |
|---|---|
| `launch options not set - set them by hand` | Steam wasn't closed, or no Steam account was found. Set them by hand as in [If you'd rather set the launch options yourself](#if-youd-rather-set-the-launch-options-yourself). |
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

## AI disclosure

This repo was written with the help of AI (Anthropic's Claude), with a human in the loop. Martin ([MWGIH](https://github.com/MWGIH)) set the goals, directed the work and reviews every change before it's merged. The AI investigated the original projects, wrote the scripts, tests and documentation, and checked the audio fix against the mod's binary.

It hasn't been tested on Steam Frame hardware yet (see [What isn't known yet](#what-isnt-known-yet)), so please report anything that doesn't work. The mod itself, Northstar and the projects in [Based on](#based-on) are their authors' own work.

## Credits

- **[CircuitLord](https://github.com/CircuitLord)** made the [Titanfall 2 VR mod and its installer](https://github.com/CircuitLord/CircuitLordVRModInstaller). For help with the mod itself, use [CircuitLord's Discord](https://discord.gg/MTKwud2cCP).
- **[Monkellie](https://github.com/Monkellie)** made [tf2vr-linux](https://github.com/Monkellie/tf2vr-linux), which this repo is based on. Its MIT notice is kept in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
- **[polar421](https://github.com/polar421)** got the mod [running on Proton first](https://github.com/polar421/Titanfall-2-VR-linux-fix) and found the audio fix.
- **[Northstar](https://github.com/R2Northstar/Northstar)** is the mod loader the VR mod runs on.

See [Based on](#based-on) for what this repo takes from each. This is a community project. It isn't affiliated with or endorsed by Respawn, EA, Valve, CircuitLord or the authors above.

## License

[GPL-3.0](LICENSE). Parts derived from tf2vr-linux keep its MIT notice in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). The mod, Northstar and the game have their own licenses and aren't included here.
