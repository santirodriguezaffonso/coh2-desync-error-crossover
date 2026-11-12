# CoH2 CrossOver setup

- Use this workflow when the user asks to apply or undo the CoH2 fix on their Mac.
- For repository maintenance, work on the requested files. Reading this file alone is not a request to change a bottle.
- Use the existing scripts. Read them before running them.
- Local file and terminal access to the user's Mac is required to apply the fix. If that access is unavailable, explain which steps the user must run.
- Follow the assistant's tool permissions. Request access when the environment requires it.

## Find the installation

- Find this repository and run commands from its directory. A GitHub ZIP works. Git is not required.
- Check that `python3` and `/usr/bin/bsdtar` are available.
- Find CrossOver. The script defaults to `/Applications/CrossOver.app`. Pass `--crossover` for another installation.
- Find the bottle containing Windows CoH2. Start with `~/Library/Application Support/CrossOver/Bottles`.
- Use `--bottle-path` for the selected bottle so commands target its exact location.
- If several bottles contain CoH2 and the intended bottle is unclear, ask the user which one to use.
- Confirm CoH2 is at `drive_c/Program Files (x86)/Steam/steamapps/common/Company of Heroes 2/RelicCoH2.exe` inside the bottle. The fix script does not support custom Steam game-library locations.
- Confirm the bottle reports Windows 10. The fix script does not change the Windows version.
- Confirm native Microsoft `concrt140.dll`, `vcruntime140.dll`, and `vcruntime140_1.dll` exist in the bottle's `drive_c/windows/system32`.
- CrossOver's Steam/bottle setup may already have installed those runtime files. If that step failed or was skipped, help the user install or repair the current Microsoft Visual C++ x64 runtime in the same bottle.

## Prepare the UCRT

- Use an existing Microsoft installer or an already-extracted DLL. Download nothing unless the user requests it.
- Look for the installer in Downloads first. Ask for its location if it cannot be found.
- The tested source is Microsoft's older Visual C++ 2015 x64 installer. Extract this package without installing it over the current runtime.
- The required `ucrtbase.dll` is Windows x64, version `10.0.10137.0`.
- Its SHA-256 must be `05fdef5f91cd38055021c6e7ae83b32936b30b6032f7ccf05b2b50233ab7fe9b`.
- If an existing DLL matches that checksum, skip extraction.
- Otherwise, run the extractor with the actual installer path:

```bash
bash extract-ucrtbase.sh "/path/to/vc_redist.x64.exe"
```

- The extractor saves `ucrtbase.dll` beside the installer, regardless of the repository location.
- Check the output and checksum. Recent installers can omit the DLL. Report that case instead of substituting another runtime version.
- If a different DLL already exists at the extraction destination, inspect it and resolve the conflict with the user before using `--force`.

## Apply the fix

- Ask the user to close CoH2 and Windows Steam if either is running. Do not terminate an active match.
- Keep Graphics, MSync, Steam Cloud, and unrelated bottle settings as configured.
- Pass `--dll` with the actual extracted file path when applying or validating the fix. The flag is required for those commands. Undo uses the saved backup and does not need it.
- Replace the example paths below with the selected bottle and DLL paths. Add `--crossover` to every fix or undo command if CrossOver is installed elsewhere.
- Validate first:

```bash
bash fix-coh2.sh --bottle-path "/path/to/bottle" --dll "/path/to/ucrtbase.dll" --dry-run
```

- Resolve validation errors before applying. Then run:

```bash
bash fix-coh2.sh --bottle-path "/path/to/bottle" --dll "/path/to/ucrtbase.dll"
```

- The script backs up the previous system DLL and CoH2-specific overrides in `coh2-ucrt-fix-backup` inside the bottle. Preserve that folder and its first backup.
- The script replaces `drive_c/windows/system32/ucrtbase.dll` and sets native-then-builtin overrides for `ucrtbase`, `concrt140`, `vcruntime140`, and `vcruntime140_1` for `RelicCoH2.exe` only.
- Use the script's backup and rollback. Do not manually replace more DLLs to work around a script error.

## Verify the result

- Verify the installed system DLL's checksum and the CoH2-specific registry overrides.
- With the user's local tools, inspect a loader trace or the running game's mapped DLLs to confirm the actual CoH2 process loads Microsoft's runtime files. A registry setting alone does not prove which DLL loaded.
- The game must use the Microsoft UCRT from the bottle's `windows/system32`. A copy beside `RelicCoH2.exe` was ignored in the setup that prompted this project.
- Report whether runtime loading was verified. If it could not be checked, state that limitation.
- Leave multiplayer validation to the user. Ask them to play a multiplayer match for at least 10 minutes and finish it if possible. Offline skirmishes do not verify synchronization with another computer.
- Installation success does not establish that multiplayer desyncs are resolved.
- If the problem returns, inspect the latest `warnings.log` in the game's Documents folder and `bugsplat.log` in the bottle's temporary folder. Match timestamps to the failed run. Keep the sync reports for that run.
- Finish with the bottle used, what changed, verification results, the backup location, and the undo command.

## Undo

- Close CoH2 and Windows Steam first.
- Use the same bottle and CrossOver installation as the apply command:

```bash
bash fix-coh2.sh --bottle-path "/path/to/bottle" --undo
```

- Undo restores the state before this script's first application. It does not undo earlier manual fixes.
- CoH2 does not need to remain installed for undo. The extracted DLL is not required either.
- If the script reports that a DLL or override changed separately, investigate rather than overwriting that change.

## Credit

- This workflow uses the [UCRT workaround documented by jrbergen](https://gist.github.com/jrbergen/0ce746676c4fbcc2becd6054d1bba2ed), adapted with CrossOver-specific DLL overrides.
