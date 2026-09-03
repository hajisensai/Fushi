## BUG-1838 · AnkiConnect 一键代装误报 Anki 没运行：新版 launcher 下找不到入口 exe
- **报告**：2026-08-24（查 BUG-1837 时顺带发现，非用户报告）
- **真实性**：✅ 真 bug（本机实测坐实，尚未修） — 根因
  `packages/fushi_anki/lib/src/ankiconnect/anki_desktop_foreground.dart:findRunningAnkiExecutable`
  → `ankiconnect_installer.dart:99`

  与 [BUG-1837](BUG-1837-anki-open-foreground-pid-launcher.md) 同根因：判据是「**有可见顶层窗口**且 exe 叫 `anki.exe`」。
  新版 Anki 的 `anki.exe` 只是 launcher，**一个窗口都没有**；持有全部窗口的是 venv 里的 `pythonw.exe`。
  两个条件互斥，判据必然落空 → `findRunningAnkiExecutable()` 恒 null → `install()` 在 Anki 明明开着时
  直接返回 `AnkiAddonInstallStatus.ankiNotRunning`，一键代装整条路在这类环境下不可用。

  本机实测（Anki 正在运行，主窗 + 浏览窗都在）：`findRunningAnkiExecutable()` → `null`。
- **[ ] ① 未修复** — 不能照抄 BUG-1837 的端口判据：installer 要的是能
  `launch(exe, <file>.ankiaddon)` 的**入口 exe**，而端口判据给出的是 `pythonw.exe`，拿它启动是错的
  （它会把 `.ankiaddon` 当 python 脚本）。

  方向：把进程枚举与「有没有窗口」解耦——遍历全部进程（`EnumProcesses` / Toolhelp32）找 `anki.exe`，
  launcher 常驻，能被找到（本机 pid 79788 = `D:\APP\Anki\anki.exe`）。

  **前置证据（必须先取，否则不许动手）**：新版 anki-launcher 是否会把命令行里的 `.ankiaddon`
  透传给已运行的 aqt 实例（Anki 的 single-instance 转发）。若不透传，改完只会起第二个实例或弹更新窗，
  比现在的「明确报错」更糟。
- **[ ] ② 未加自动化测试** — 修复时与 ① 同批补：至少钉「属主进程没有窗口时仍能找到 launcher」。
- **备注**：与 BUG-1837 共用 `AnkiDesktopForegroundBackend`，但语义必须分开——
  **前台目标进程**（要授权 + raise 的，= 跑 aqt 的那个）和**入口 exe**（要拿去 launch 的，= launcher）
  在旧架构下重合、在新 launcher 架构下分裂，把两者混成一个函数正是这两条 bug 的共同源头。
