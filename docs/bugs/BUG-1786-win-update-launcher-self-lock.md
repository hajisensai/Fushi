## BUG-1786 · 自更新永远装不上 app.so：launcher 占着自己的文件让 Inno 整包回滚
- **报告**：2026-08-23（用户：「设置里面进去浏览器扩展没有退出按钮」+「我记得修复了这个问题，怎么没生效」+「我是用 app 自身的更新更新的」）
- **真实性**：✅ 真 bug —— 三层独立缺陷叠加，现场证据齐全（Inno 安装日志 + 安装目录时间戳 + 进程启动时刻）

### 用户现场

用户报的表象是 UI 问题（BUG-1748 的返回键），但那条**早在 2026-08-19 23:19（`679e3244ac`）就修好了**，
且本轮用真 widget 测试复验：push 成全屏路由时页头确实渲染出 `Icons.arrow_back`。真正的问题是
**用户机器上跑的根本不是那份代码**：

| 证据 | 值 |
|---|---|
| `D:\APP\Hibiki\data\app.so`（全部 Dart 代码） | **2026-08-19 05:12** |
| BUG-1748 修复提交时间 | 2026-08-19 23:19 |
| `D:\APP\Hibiki\fushi.exe` | 2026-08-22 18:26（12067 包的构建时刻） |
| app 内显示版本 | 2.2.1+**12067**（= `git rev-list --count` 10067 + 地板 2000 = 当前 develop HEAD `075d4f3`） |

即：exe 是新的、Dart 代码比修复还早 18 小时。8-22 那次「更新」只换掉了 9 个**根目录**文件
（`ffmpeg.exe` / `fushi.exe` / 几个 plugin dll…），`data\`、`magpie_bundle\`、`mihon_bridge\`
等**所有子目录一个都没动**，`unins000.dat` 也停在 8-19。

`updates\fushi-2.2.1-debug.12067-windows-setup.install.log`（今天 14:58）给出全部真相：

```
Dest filename: D:\APP\Hibiki\fushi_update_launcher.exe
Installing the file.
DeleteFile: The existing file appears to be in use (5). Retrying.   ×4
Defaulting to Abort for suppressed message box (Abort/Retry/Ignore):
    DeleteFile failed; code 5. 拒绝访问。
User canceled the installation process.
Rolling back changes.
```

### 根因（三层，各自独立）

**① 自噬：launcher 住在它自己要重写的目录里。**
`fushi_update_launcher.exe` 是自更新拉起 Inno 的那个进程，并且**必须活到安装结束**——BUG-1708
把「安装失败后谁把 app 拉回来」这一环交给了它（app 为让出文件锁已 `exit(0)`，Inno 走不到
`[Run]` 就没人负责）。可它自己就在 `{app}` 下，于是复制阶段必然 `DeleteFile code 5`，而
`/SUPPRESSMSGBOXES` 对 Abort/Retry/Ignore 弹窗**默认取 Abort** ⇒ 整包回滚。
这是 100% 复现的死锁：**只要走应用内更新就必然踩**，与占用者是谁无关。
`PrepareToInstall` 里的 `KillProcessesUnderDir({app})` 救不了——而且**不该**救：杀掉 launcher
等于用 BUG-1708 的复发换这次复制成功（实测证据：安装 14:58:32 回滚，app 14:58:35 被拉起，
说明 launcher 全程活着）。这是个设计冲突，只要 launcher 还住在安装目录里就无解。

**② 回滚不完整 ⇒ 半更新态。**
Inno 的回滚只撤销了 `[InstallDelete]` 建的目录，**已经复制成功的文件原样保留**。文件按字母序
安装，`fushi.exe` 排在 `fushi_update_launcher.exe` 之前、`data\app.so` 排在它之后，于是稳定
落在「新 exe + 旧 Dart 代码」。

**③ 失败被误判成成功 ⇒ 用户零感知。**
`WindowsUpdateHandoff.reconcile` 用 `currentVersion >= targetVersion` 判断装没装上，而 Windows 上
`package_info_plus` 的版本号**读自 exe 的版本资源**——exe 恰恰是已经被换掉的那个。于是握手宣告
`installed`，用户收到「更新成功」，继续跑旧代码。这就是用户连着几天觉得「修好的 bug 没生效」的
直接原因：每一次自更新都在同一处静默回滚，而每一次都报成功。

误判还会**顺手销毁重试材料**：`reconcile` 的 installed 分支按 TODO-1089 立刻回收
`updates\*-windows-setup.exe`。用户现场 updates 目录里只剩一堆 `.meta.json`，安装包一个不剩
——本来只要重跑一次那个包就能自愈，判据错了之后连包都没了。修好 ③ 之后这条自然消失
（判为失败就不再走回收分支），无需为它单独加特例。

### 修复

1. **`platform_updater.dart`**：新增 `stageWindowsUpdateLauncher()`，把 launcher 复制到 updates
   目录（**安装目录之外**）再从副本运行；`windowsUpdateLauncherArgs` 增发 `--app-exe`。
   与 BUG-1708 处理注入运行时同一原则：**谁要在安装期间存活，谁就不能住在安装目录里**。
   副本失败则回退原地运行（退化成旧行为，不阻断更新）。顺带消除了「KillProcessesUnderDir
   可能误杀 launcher 导致 app 回不来」这个潜在问题——副本不在 `{app}` 下，扫不到。
2. **`update_launcher.cpp`**：`AppExecutablePath(explicit_path)` 优先用 `--app-exe`，回退「同目录」
   旧判据（副本同目录没有 `fushi.exe`，不传就拉不回 app）。老调用方与手工执行不受影响。
3. **`fushi.iss`**：`PrepareToInstall` 里 `MakeWayForRunningLauncher()`——探测到 launcher 被占用就
   **改名**（Windows 允许给运行中的 exe 改名，只是不能删除/覆盖）让路，不杀进程，兜底能力不受损。
   这一条是给**存量用户**的救援：他们跑的仍是安装目录里的旧 launcher，只有靠它才能把这一版装完整。
4. **`update_handoff.dart`**：新增纯函数 `windowsInnoLogReportsAbortedInstall()`，让 **Inno 日志的
   收尾结论否决版本号判据**。判据取最后一条结论行而非「出现过某词」，且 `\b` 词边界是关键——
   回滚收尾写的是「**Un**installation process succeeded.」，裸 `contains` 会把**回滚自身的成功**
   读成安装成功，正好在最该报失败的那条日志上给出相反结论。

- **[x] ① 已修复** — 上述四处
- **[x] ② 已加自动化测试** — `fushi/test/utils/misc/update_launcher_self_lock_test.dart`（9 条，
  含用**用户真实失败日志**做 fixture）+ `fushi/test/build/update_launcher_relaunch_guard_test.dart`
  更新（BUG-1708 守卫跟随新契约：`--app-exe` 优先、同目录回退仍在）

### 验证

- **A/B 端到端实测**（独立最小复现，不碰用户实例）：造一个运行中的 `fushi_update_launcher.exe`
  占住自己的文件，用同样的 `/VERYSILENT /SUPPRESSMSGBOXES` 口径静默安装，两组唯一差别是
  有没有「改名让路」：

  | | setup 退出码 | 回滚 | 字母序在前的文件 | `data\app.so` |
  |---|---|---|---|---|
  | control（无修复） | 5 | 是 | **NEW** | **OLD** ← 精确复现用户现场 |
  | fixed（带修复） | 0 | 否 | NEW | **NEW** |

- 变异实测：`\b` 去掉退化成 `contains` → 精确红 1 条（`Expected: true, Actual: false`，
  即回滚被读成成功）；还原后 sha256 与变异前逐字节一致
  （`894ad1ee2eedc80c307f47f7885fd1042e15344fa1465e5758bd015e4cbd28e6`）。
- `update_launcher.cpp`：MSVC `cl /c /utf-8 /std:c++17` 编译通过（exit 0）。
- `fushi.iss`：ISCC 6.7.1 完整编译通过（exit 0），`[Code]` 段编译无误。
- `flutter analyze`（含 test）：No issues found。
- 定向：`test/utils/misc/` + `test/build/` + 扩展页两条守卫 **412 绿**。
- BUG-1748 复验（本轮新增行为测试）：push 成全屏路由时页头确实渲染 `Icons.arrow_back` —— 确认
  那条修复本身没问题，用户看不到纯粹因为代码没装上。

### 备注

- **生效节奏**：③④ 随新版落地即生效；①② 中 `.iss` 那一半（改名让路）对**存量用户下一次更新**
  即生效——正是它让这一版能装完整；`--app-exe` + 副本运行要等这一版装上之后的**再下一次**更新
  才走新路径。
- 用户机器当前处于半更新态（新 exe + 8-19 的 app.so），需**手动跑一次完整安装包**恢复一致；
  在装上带本修复的版本之前，再点应用内更新仍会重蹈覆辙。
- 未做（明确记一句）：Dart 侧没有独立于 exe 版本资源的「运行中代码版本」常量，所以
  「exe 与 app.so 不同步」目前只能靠 Inno 日志间接发现，无法自检。要根治得在构建期把版本注入
  Dart（`--dart-define`）并让关于页/握手同时比对两个来源，属独立改动，本轮未做。
