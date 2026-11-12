# CoH2 Desync Error CrossOver

## Description

These scripts apply a workaround for Company of Heroes 2 multiplayer desync error in CrossOver.

- `extract-ucrtbase.sh` extracts Microsoft's x64 `ucrtbase.dll` from a local Visual C++ installer.
- `fix-coh2.sh` backs up the bottle's existing DLL and CoH2-specific overrides, installs the extracted DLL, and configures `RelicCoH2.exe` to prefer Microsoft's native C/C++ runtime libraries.

This is intended to address runtime differences that can cause multiplayer desyncs; verify the result in a multiplayer match. The scripts download nothing, and `--undo` restores the backed-up DLL and overrides.

*This is based on the UCRT workaround documented by [jrbergen](https://gist.github.com/jrbergen/0ce746676c4fbcc2becd6054d1bba2ed), with CrossOver-specific DLL overrides.*

## AI-assisted setup

- Open this repository folder in an assistant with local file and terminal access to your Mac.
- Paste this prompt:

> Read AGENTS.md in this folder and apply the CoH2 CrossOver fix on my Mac. Ask me for any details you cannot determine locally.

- AGENTS.md contains the setup, backup, verification, and undo instructions.
- After setup, test a multiplayer match as described in step 4.

## Prerequisites

- macOS with CrossOver installed, Python 3 available as `python3`, and macOS's built-in `/usr/bin/bsdtar` for extraction.
- Confirm Microsoft Visual C++ x64 runtime installed successfully during CrossOver's Steam/bottle setup. It provides native `concrt140.dll`, `vcruntime140.dll`, and `vcruntime140_1.dll`. If setup skipped or failed this step, install or repair the [current x64 runtime](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist/) inside the Windows 10 bottle.
- The Windows version of CoH2 installed through Steam in a CrossOver bottle, using Steam's default game-library location inside that bottle.
- A trusted local Microsoft Visual C++ installer containing the required x64 `ucrtbase.dll`, version `10.0.10137.0`, or an already-extracted copy of that DLL. The tested source is the older Visual C++ 2015 x64 package.
- Close CoH2 and Windows Steam before applying or undoing.

## Step by Step

### 1. Download Installer

Download the older [Visual C++ 2015 x64 installer](https://www.microsoft.com/en-us/download/details.aspx?id=48145) to extract `ucrtbase.dll`. Save `vc_redist.x64.exe` in Downloads, or adjust the installer path in step 2. Extract this older package without installing it. The current x64 runtime listed in the prerequisites must already be installed inside the bottle.

**Non-dev:**
If you don't have `git` on your Mac: **Click Code** → **Download ZIP**. If the ZIP isn't already extracted, double-click it in Finder to extract it. Proceed.

---

### 2. Extract from Microsoft Installer

**Non-dev:**
Open the **Terminal** native app. (Look for it in **Apps**, is already built in on every Mac), and place the terminal where the scripts are. Paste and run the next command:

```bash
 cd "$HOME/Downloads/coh2-desync-error-crossover-main"
 ```

"coh2-desync-error-crossover-main" is the name of the downloaded ZIP of the previous step. If it is different, you need to change it here as well.

Once you placed the terminal in the folder with the scripts you need to run the next one:

```bash
bash extract-ucrtbase.sh "$HOME/Downloads/vc_redist.x64.exe"
```

- The extractor writes `ucrtbase.dll` beside the installer `.exe`, regardless of where the script is located.
- It does not run the installer or access the network.
- It checks the extracted DLL is Windows x64, prints its SHA-256, and reports whether it matches the DLL expected by `fix-coh2.sh`.
- It preserves a different existing DLL unless `--force` is supplied. An identical existing DLL is left as it is.
- Installers without `ucrtbase.dll` produce an error. The tested source is the older Visual C++ 2015 x64 package; recent v14 packages can omit it.
- **Extraction does not verify the installer's Microsoft digital signature; use a trusted local installer.**

---

### 3. Apply the Fix

Paste and run the next command:

```bash
bash fix-coh2.sh --bottle "Company of Heroes 2" --dll "$HOME/Downloads/ucrtbase.dll"
```

- The script saves the previous system DLL and CoH2-specific overrides in `coh2-ucrt-fix-backup` inside the bottle. Repeat runs preserve that first backup.
- It installs the new system DLL in `drive_c/windows/system32` and selects native `ucrtbase`, `concrt140`, `vcruntime140`, and `vcruntime140_1` only for `RelicCoH2.exe`.
- It leaves Graphics, MSync, Windows version, and Steam Cloud settings as configured.

**Non-dev:**

`fix-coh2.sh` is the name of the script file.

`--bottle "Company of Heroes 2"` is the name of your bottle. Where you have the game installed, change it if different.

`--dll "$HOME/Downloads/ucrtbase.dll"` is required when applying the fix, including runs with `--dry-run`. Pass the path of the extracted file. The script does not choose a default DLL path.

- If Ctrl+C interrupts a change, the script restores the previous DLL and overrides before exiting. An interrupted backup is removed before any DLL or override changes.

---

### 4. Test multiplayer

- Open Windows Steam in the same CrossOver bottle and launch CoH2.
- Start a multiplayer match with another player. An offline skirmish cannot test synchronization between computers.
- Play for at least 10 minutes and finish the match if possible. Check whether a Sync-Error occurs.
- A successful script run confirms the file and registry changes. Multiplayer testing checks whether the desync still occurs.
- If a Sync-Error returns, keep `warnings.log` and `bugsplat.log` from that run for troubleshooting.

---

### 5. Issues and Custom Paths

In case something went wrong and you don't want to re-create the bottle, run the prev command with the `--undo` flag

```bash
bash fix-coh2.sh --bottle "Company of Heroes 2" --undo
```

- Undo restores the state before this script's first application. It does not undo earlier manual fixes.
- Undo uses the saved backup. It requires neither an installed copy of CoH2 nor the extracted DLL, so omit `--dll`.

Custom paths:

```bash
bash fix-coh2.sh --bottle-path "/Volumes/Games/CrossOver/CoH2" --dll "/path/to/ucrtbase.dll"
```

- Custom Steam game-library locations are not supported. Custom bottle locations are supported with `--bottle-path`.
- File and registry verification confirms installation. Confirm actual native runtime loading and multiplayer stability in the game afterward.
