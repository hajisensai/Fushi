## BUG-1836 · 手动跑安装包救援成功后仍必报更新失败（Inno 日志判据拿不到证据）
- **报告**：2026-08-24（现场：用户按 BUG-1786 / BUG-1831 的指引手动跑 `fushi-2.2.1-debug.12215-windows-setup.exe` 救援，装完重启后 app 又弹了一次「更新失败」）
- **真实性**：✅ 真 bug —— 沿真实代码路径验证：判据必然拿不到证据，不是偶发

### 现场

救援本身**成功**（磁盘证据齐）：`data\app.so` 8-19 05:12/42.7MB → 8-24 09:22/48.1MB，
`fushi.exe` / `fushi_update_launcher.exe` / 全部 plugin dll 统一在 8-24 09:2x（同一次构建），
`data/` `galgame_helper/` `magpie_bundle/` `mihon_bridge/` `unins000.*` 全部 21:11 落地，
`fushi_update_launcher.old.exe` 已清除。半更新态解除。

但 `%APPDATA%\Fushi\Fushi\updates\update-handoff.json` 里 `lastPromptedAt` = 2026-08-24
13:12:46Z（本地 21:12，即安装完成后 app 重启那一刻），仍带着 19:35 那次的
`installerFailureType: launch_error`。也就是**装成功之后又报了一次失败**。

### 根因

`WindowsUpdateHandoff.reconcile`（`fushi/lib/src/utils/misc/update_handoff.dart:648`）判「装成功」
要求 `verdict == succeeded`，而 verdict 来自 **Inno 日志**（`record.innoLogPath`）。那条日志路径
是 app 自己发起更新时经 `/LOG=` 传给 Inno 的；**用户手动双击安装包时 Inno 不写任何日志**
⇒ 文件不存在 ⇒ `windowsInnoLogVerdict` 返回 `unknown` ⇒ 按 BUG-1786 的规矩「unknown 一律走
失败分支」⇒ 报失败。

BUG-1786 那条规矩在**应用内更新**语境下是对的（日志缺失 = 安装器没跑起来）。但它把
「安装器没跑起来」和「安装器跑了、只是不是我拉起的」混成了同一件事，于是 BUG-1786 / BUG-1831
自己写进备注的救援指引（「手动跑一次完整安装包」）必然以一句「更新失败」收尾。

影响有界：失败分支**不重试、不重新下载**，且 `lastPromptedFailureFingerprint` 去重让它只弹
一次，之后静默。所以是**误导**，不是功能损坏。

### 可行修法（未实施）

判据缺的是「运行中的这份代码到底是不是 target」这条正面证据，有两条路：

1. **构建期把版本注入 Dart**（`--dart-define`），让 app 能报出自己这份 `app.so` 的
   `-debug.N`，reconcile 直接比 `运行中代码版本 == targetVersion` ⇒ 无论谁装的都判成功。
   这正是 BUG-1786 备注最后一段列为「未做」的那条，做了能同时根治「exe 与 app.so 不同步
   无法自检」。
2. **拿 `unins000.dat` 的 mtime 当安装时刻**：它由 Inno 运行期重写，是真实安装时刻（现场
   21:11），而 `[Files]` 装出来的 exe/so 带的是**源文件时间戳**（09:2x，构建时刻），不能用。
   若 `unins000.dat` 的 mtime 晚于 marker 的 `installerLaunchFailedAt` / `startedAt`，说明
   marker 写下之后确实发生过一次完整安装。比 ① 轻，但依赖 Inno 实现细节，属兜底而非首选。

- **[ ] ① 未修复** — 需先定版本注入方案（与 BUG-1786 的「未做」项同源，建议合并处理）
- **[ ] ② 未加自动化测试** —

### 备注

- **仅 Windows**：Inno 日志判据是 Windows 专有。
- 与 [BUG-1831](BUG-1831-win-update-launcher-vanished.md) 相邻但不同因：1831 是 launcher 消失
  导致**安装器起不来**，本条是安装器**跑成功了却判不出来**。
- 严重性低（一次性误报、不触发重试），但它命中的正是「用户刚照着指引把机器修好」的时刻，
  体验上最伤——用户会以为救援没成功而重复操作。
