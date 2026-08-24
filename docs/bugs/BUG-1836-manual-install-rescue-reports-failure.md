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

### 修复

判据缺的是「运行中的这份代码到底是不是 target」这条正面证据。此前两个证据源**都不是被
替换的产物本身**：Inno 日志是安装器的旁证，exe 版本资源和 `app.so` 是两个文件。

新增第三个证据源 `kFushiBuildVersionDefine`（`fushi/lib/src/utils/misc/build_version.dart`）：
构建期 `--dart-define=FUSHI_BUILD_VERSION=<build-name>` 注入，编译进 AOT 快照，**与被替换的
产物同体**——`app.so` 没被换掉它就报旧值，谁也伪造不了。

判据收敛成一张三源证据表 `isWindowsUpdateInstalled`（`update_handoff.dart`）：

| Inno 日志 | 代码版本证据 | 结果 |
|---|---|---|
| aborted | 任意 | 失败（回滚保留被覆盖的文件，整包仍可能是半更新态） |
| unknown | 达标 | **成功** ← 本条 bug |
| 任意 | 达标 | 成功 |
| 任意 | 未达标 | 失败（日志说成功也不能给旧代码背书） |
| succeeded | 不可比 | 看 exe 版本（旧判据） |
| unknown | 不可比 | 失败（旧判据） |

「代码版本证据」刻意**不是 bool**：版本号之间并不总是可比。`2.2.1-debug.12215` 和
`2.2.1-beta.30` 谁新，SemVer 只会按字符串把 `debug` 排在 `beta` 之后，那是巧合不是事实；
同理 SemVer 规定「正式版 > 同号预发布版」，于是 `2.2.1` 恒 > `2.2.1-debug.12215`——BUG-1786
抱怨的「判据恒为真」正是这条。所以基版本相同时只有**通道标签一致**才比序号，否则标
`inconclusive` 退回日志判据。少了这一层，一次失败的跨通道安装会被硬判成成功。

代码版本未知时（本次改动之前发布的历史版本、本地 `flutter run`）逐行退化成 BUG-1786 的旧
判据，**行为逐字不变**——所以这条修复对存量用户零风险，但也**要装上带注入的新包之后才生效**。

顺带修掉两处同源缺陷：

- **幂等键**（`lastPromptedAppVersion`）改用代码版本。Windows 上 exe 版本资源在同 base 的两个
  debug 构建上完全相同（`2.2.1` == `2.2.1`），marker 因 AV 占用删不掉时会把**下一次**更新的
  提示一并吞掉。
- **关于页与日志上传**改报真实构建版本；两者基版本不一致时关于页并排显示 `≠ exe <ver>`
  ——「新 exe + 旧 app.so」的半更新态第一次变得可自查（这正是 BUG-1786 备注里列的「未做」项）。

守卫 `fushi/test/build/build_version_define_guard_test.dart` 按 `- name:` 切步骤（**不用固定行
窗口**——BUG-1831 踩过一次：新增注释把被断言的语句顶出窗口，守卫悄悄失效），钉死 7 处
`--build-name` 每处都配同值的 `--dart-define`，漏一处 CI 红。

- **[x] ① 已修复** — commit `83b6df61e8`
- **[x] ② 已加自动化测试** — `fushi/test/utils/misc/update_install_evidence_test.dart`（三源
  判定表 8 例 + reconcile 端到端 3 例）、`fushi/test/build/build_version_define_guard_test.dart`
  （构建期注入配对守卫）、`fushi/test/settings/app_version_display_format_test.dart`（关于页
  展示 4 例）。四个变异（漏注入一处 / 两侧 define 名字对不上 / 判据忽略代码版本 / 回滚不再
  一票否决）实测各自精确变红。

### 备注

- **仅 Windows**：Inno 日志判据是 Windows 专有。macOS 的 `Info.plist` 用
  `$(FLUTTER_BUILD_NAME)`，**完整保留** `-debug.N`，版本判据本来就有效，未改动。
- **更新检查**不受后缀丢失影响：`currentReleaseSequence()` 早已用 `buildNumber` 反解 seq
  绕过（BUG-457 / BUG-846），本轮未动那条链。
- **生效节奏**：注入在构建期，所以只有装上带本修复的包之后，下一次更新的判据才吃到代码
  版本；在那之前逐行退化成旧判据（行为不变）。
- 与 [BUG-1831](BUG-1831-win-update-launcher-vanished.md) 相邻但不同因：1831 是 launcher 消失
  导致**安装器起不来**，本条是安装器**跑成功了却判不出来**。
- 严重性低（一次性误报、不触发重试），但它命中的正是「用户刚照着指引把机器修好」的时刻，
  体验上最伤——用户会以为救援没成功而重复操作。
