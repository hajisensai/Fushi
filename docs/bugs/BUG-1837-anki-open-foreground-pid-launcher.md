## BUG-1837 · 制卡后在 Anki 中打开仍不到前台：新版 Anki launcher 下进程识别失效
- **报告**：2026-08-24（用户：制卡后点跳转，有时候 Anki 不会拉到前台，电脑上）
- **真实性**：✅ 真 bug — 根因 `packages/fushi_anki/lib/src/ankiconnect/anki_desktop_foreground.dart:_isAnkiProcess`
  （认 Anki 的唯一判据是「窗口所属进程的 exe 叫 `anki.exe`」）

  BUG-1641 已经修过一次同一现象（让渡前台权限 + 兜底 raise），但那套修复**只有在认得出 Anki 进程时才成立**。
  本机取证（Windows 11，用户日常环境）：

  | 进程 | exe | 顶层窗口 | 监听 8765 |
  |---|---|---|---|
  | pid 79788 | `D:\APP\Anki\anki.exe` | **0 个** | 否 |
  | pid 13324 | `...\AnkiProgramFiles\python\cpython-3.13.5\pythonw.exe`（`-c "import aqt; aqt.run()"`） | 「账户 1 - Anki」+「浏览（已选取 1 张卡片）」 | **是** |

  即：新版 Anki 的 `anki.exe` 只是个 launcher，一个窗口都没有；真正跑 aqt、持有全部窗口、
  监听 AnkiConnect 端口的是 venv 里的 `pythonw.exe`。于是 `findAnkiProcessId()` 恒为 null →
  `grantForegroundToAnki()` 直接返回 → `raiseAnkiWindow(null)` 立即 return → **BUG-1641 的整套修复全程空转**，
  症状精确回到修复前：Anki 的「浏览」窗口没开时新建窗口能弹出来（看着正常），已在后台开着时走复用路径
  被 Windows 前台锁定降级成闪任务栏。用户口中的「有时候」就是这两半。

  真机实测坐实（`grantForegroundToAnki` 走真实 FFI）：旧判据 `findRunningAnkiExecutable()` → `null`，
  新判据 → `pid=13324`。
- **[x] ① 已修复** — 换数据源，而不是给 `pythonw.exe` 加特例：认 Anki 的首选判据改成
  **「谁在监听我们正在对话的这个 AnkiConnect 端口」**（`GetExtendedTcpTable` +
  `TCP_TABLE_OWNER_PID_LISTENER`，IPv4 表优先、IPv6 兜底），那必然就是要授权和要拉前台的那个进程，
  与 exe 叫什么、装在哪、是不是 venv 全无关系。
  - `anki_desktop_foreground.dart`：backend 新增 `findProcessListeningOnPort(int port)` +
    `_WindowsAnkiForeground` 的 iphlpapi 实现；`grantForegroundToAnki({required int ankiConnectPort})`
    经 `resolveAnkiProcessId` 端口优先、进程名兜底（旧版单进程 Anki 在读不到监听表的环境下仍认得出）。
  - `ankiconnect_repository.dart`：`openNoteInAnki` 传 `service.port`（不是硬编码 8765——用户可以改端口）。
  - fail-soft 口径不变：两个判据都空 / 非 Windows / FFI 不可用一律退回「什么都不做」。
- **[x] ② 已加自动化测试** — `fushi/test/anki/anki_desktop_foreground_test.dart` 新增 group「认 Anki 进程（BUG-1837）」3 例
  （共 12 例通过）：进程名判据落空时仍按端口找到 Anki 且让渡/兜底都打在该 pid 上、端口取自 `service.port` 而非硬编码、
  监听表读不到时退回进程名判据。已做变异实测：把 `resolveAnkiProcessId` 改回只用 `findAnkiProcessId()` → 6 处红；
  把 `service.port` 换成硬编码 `8765` → 1 处红（正是端口透传那条）。
- **备注**：同根因第二受害点**未在本轮修**——`findRunningAnkiExecutable()`（AnkiConnect 一键代装，
  `ankiconnect_installer.dart:99`）用的还是同一个「有窗口 + exe 叫 anki.exe」判据，在新 launcher 下同样恒为 null，
  会把「Anki 明明开着」误报成 `ankiNotRunning`（本机实测 `legacyExe=null` 已坐实）。
  它不能照抄端口判据：installer 要的是能 `launch(exe, <file>.ankiaddon)` 的**入口 exe**，而端口判据给出的是
  `pythonw.exe`，拿它启动是错的。正确修法应是「遍历全部进程（不要求有窗口）找 launcher `anki.exe`」，
  但**前提是先验证新 launcher 会把 `.ankiaddon` 参数转发给运行中的实例**——没有这个证据不能盲改，
  否则可能起第二个实例。已另立 BUG-1838。
