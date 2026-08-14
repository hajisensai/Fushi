## BUG-1641 · 制卡后「在 Anki 中打开」只闪任务栏，Anki 不到前台
- **报告**：2026-08-14（用户：）
- **真实性**：✅ 真 bug — 根因 `packages/fushi_anki/lib/src/ankiconnect/ankiconnect_repository.dart:1141`（`openNoteInAnki` 只发 `guiBrowse`，没有在 Hibiki 侧解开 Windows 前台锁定）

  用户观察把根因直接框死成两半：Anki 的「浏览」窗口**没开**时点跳转能弹出来，**已在后台开着**时只闪任务栏图标。
  对应 AnkiConnect `guiBrowse` → `aqt.dialogs.open('Browser')` 的两条路径：
  - 未开 → 新建窗口，新窗口首次 show 仍能进前台；
  - 已开 → 复用路径，只对一个**已存在**的窗口 `raise_()` + `activateWindow()`。Windows 的前台锁定规则里，
    非前台进程调 `SetForegroundWindow` 不会置前，而是被降级成「闪任务栏按钮」——正是用户看到的现象。

  有权解开这个锁的只有**当时的前台进程**，也就是用户刚点下按钮的 Hibiki 自己，所以修复只能落在 Hibiki 侧，
  Anki/AnkiConnect 那边无论怎么调都绕不过去。
- **[x] ① 已修复** — `packages/fushi_anki/lib/src/ankiconnect/anki_desktop_foreground.dart`（新增 `AnkiDesktopForeground`）
  + `ankiconnect_repository.dart` 的 `openNoteInAnki` 前后各夹一步：
  1. 发 `guiBrowse` **前**按 Z 序找到 `anki.exe` 的 pid，`AllowSetForegroundWindow(ankiPid)` **定向**让渡前台权限
     （不用 `ASFW_ANY` 放开给任意进程），让 Anki 自己的 activate 直接生效，两条路径一并覆盖；
  2. 发完**后**兜底：前台仍不属于 Anki 时，取它 Z 序最顶的可见顶层窗口（Anki 刚 `raise_()` 过「浏览」，
     Z 序里就是它），`IsIconic` 则 `ShowWindow(SW_RESTORE)`，再 `SetForegroundWindow`；带 3 次上限的正向确认循环。

  只在 AnkiConnect host 是 loopback 时生效（远端 Anki 在别的机器上，激活本机窗口无意义）；非 Windows 与
  FFI 加载失败全 fail-soft 退回原行为，绝不让制卡链路因此报错。
- **[x] ② 已加自动化测试** — `fushi/test/anki/anki_desktop_foreground_test.dart`（6 例）：钉「让渡在 guiBrowse 前 /
  兜底在其后」的调用时间线、前台已归 Anki 时不再强拉、非 loopback 完全不碰本机窗口、找不到 Anki 时降级、
  重试次数上限、后端抛错不影响返回值。已做变异实测：去掉 loopback 门、把兜底挪到 `guiBrowse` 之前，两次都被测试抓红。
- **备注**：Win32 调用面由 `AnkiDesktopForegroundBackend` 抽象隔离，测试环境注入替身；真实 `_WindowsAnkiForeground`
  用 `GetTopWindow` + `GW_HWNDNEXT` 遍历（等价 `EnumWindows` 且天然按 Z 序，省掉一次性的 `NativeCallable` 回调）。
  AnkiDroid / AnkiMobile 后端不走这条路径，不受影响。
