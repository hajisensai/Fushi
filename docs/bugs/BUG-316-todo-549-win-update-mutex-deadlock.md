## BUG-316 · Windows 自更新 AppMutex 死结：新安装器被旧 app mutex 阻止替换文件
- **Reported**: 2026-06-19 (board TODO-549; regression source TODO-431)
- **Real?**: YES, confirmed by a real Inno install log.
- **[x] (1) Fixed** — commit b19e8a469
- **[x] (2) Automated test added** — commit b19e8a469

### Root cause
App-internal self-update: the old app downloads the new Inno installer and, via
`hibiki_update_launcher.exe`, waits for the current PID to exit before launching
Inno (`hibiki/lib/src/utils/misc/platform_updater.dart:400`
`WindowsInstaller.runAndExit`). But `hibiki.iss` `[Setup]`
`AppMutex=HibikiSingleInstanceMutex` (`hibiki/windows/installer/hibiki.iss:30`)
makes Inno run its built-in mutex check (CheckForMutexes) very early: if any
hibiki.exe / leftover process still holds that mutex, Inno pops "Setup has
detected that Hibiki is currently running". Under `/VERYSILENT` +
`/SUPPRESSMSGBOXES` that OK/Cancel box defaults to Cancel -> `Got EAbort` ->
immediate exit with no files replaced.

Real log (C:\Users\wrds\AppData\Roaming\Hibiki\Hibiki\updates\hibiki-0.9.27-debug.5223-windows-setup.install.log)
lines 13->14->18: `Created temporary directory` -> `Defaulting to Cancel for
suppressed message box ... Setup has detected that Hibiki is currently running`
-> `Got EAbort exception`; the whole setup aborts within 1ms; target dir is the
non-standard `D:\APP\Hibiki`.

Inno source proof (`jrsoftware/issrc` `Projects/Src/Setup.MainFunc.pas`): the
`[Code]` `InitializeSetup` event is called at line 3703; the AppMutex
`CheckForMutexes(ExpandedAppMutex)` loop is at line 3733 -- **InitializeSetup
runs BEFORE the AppMutex check** (line 3746 comment: "the InitializeSetup call
above can't be done earlier"). Inno's CloseApplications / `/CLOSEAPPLICATIONS`
go through RestartManager (by file usage), are fully independent from the
AppMutex check, and cannot suppress this abort.

### Fix
- **P0 (the only real-cure layer)** `hibiki/windows/installer/hibiki.iss`: add
  `[Code] function InitializeSetup(): Boolean;`. Before the AppMutex check:
  `taskkill /IM hibiki.exe /T` (WM_CLOSE, graceful) -> short poll; if still
  alive, `taskkill /F /IM hibiki.exe /T` (with the WebView2 child tree) +
  `taskkill /F /IM msedgewebview2.exe /T`; then bounded-poll (up to ~10s) via
  `external 'OpenMutexW@kernel32.dll stdcall'` until the mutex is gone, returning
  True (on timeout still return True -- never hang -- and let `[Setup] AppMutex`
  fall back to the original prompt). `[Setup] AppMutex=` is kept as fallback.
- **P1 (additive layer + dead-code cleanup)**
  - `hibiki/windows/runner/update_launcher.cpp`: after the parent PID exits and
    before launching Inno, bounded-poll via `OpenMutexW` (`WaitForMutexReleased`)
    until the mutex is released, closing the "only waited on the parent PID"
    blind spot (a second hibiki.exe / orphaned WebView2 still holding the mutex);
    outcome recorded in the marker (`launcherMutexReleased`).
  - `hibiki/lib/src/utils/misc/update_handoff.dart`: delete dead method
    `markPostLaunchObserved` (zero production callers in lib) and the always-null
    ghost fields it alone wrote (`installerProcessRunning` /
    `postLaunchObservationError` / `postLaunchObservedAt`), removing the
    "treat an always-null field as evidence" misleading display. `writePending`
    already builds a fresh record (does not read the old marker), so cross-attempt
    fields are naturally cleared -- a new regression test locks that contract.
  - `hibiki/lib/src/utils/misc/update_checker.dart`: delete the matching dead
    dialog branches and the `processRunning=` log field.
  - i18n: remove orphan keys `update_install_process_observed` /
    `update_install_process_not_observed` (17 files + regenerate strings.g.dart).

### Tests (strongest landable layer = source-scan guards + behaviour tests)
- `hibiki/test/utils/misc/platform_updater_test.dart`: new guard asserting the
  `.iss` `[Code] InitializeSetup` kills processes + polls the mutex before the
  AppMutex check (`[Code]`, `function InitializeSetup(): Boolean`, `OpenMutexW`,
  `@kernel32.dll stdcall`, `HibikiSingleInstanceMutex`, `taskkill`, `hibiki.exe`,
  `msedgewebview2.exe`, `MutexReleasePollAttempts`,
  `Sleep(MutexReleasePollIntervalMs)`); launcher guard changed from "must not
  contain the mutex name" to "no CreateMutex but MAY probe via OpenMutexW"
  (asserts `OpenMutexW` / `WaitForMutexReleased`).
- `hibiki/test/utils/misc/update_handoff_test.dart`: drop `markPostLaunchObserved`
  calls + ghost-field assertions; add a "writePending does not leak the previous
  attempt's launcher fields" regression test (launcherPid / parentProcessId /
  parentExitObserved / installerPid / installerLaunchSucceeded all null).
- `hibiki/test/utils/misc/update_checker_dialog_test.dart`: drop ghost-field
  construction and the `update_install_process_not_observed` assertion.
- Verified: full `flutter analyze` 0; the three target tests +57 green; i18n
  completeness + all update_checker tests +96 green.

### Real-device-only verification
ISCC compile of the `.iss` + a real 5223 -> fixed-version end-to-end install
(no ISCC on this machine); the non-standard `D:\APP\Hibiki` dir; deliberately
leaving a 2nd hibiki.exe / WebView2 holding the mutex (multi-instance). The
`.iss [Code]` Pascal syntax was only human-reviewed (OpenMutexW external decl,
ewWaitUntilTerminated / SW_HIDE built-ins), not ISCC-compiled.
