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

**③ 「更新成功」这句话根本不看装没装上。**
`WindowsUpdateHandoff.reconcile` 判成功的唯一判据是 `currentVersion >= targetVersion`，而这条判据
在 debug/beta 通道**恒为真**：

- `targetVersion` 取自下载 meta，形如 `2.2.1-debug.12067`（现场 `*.meta.json` 实物为证）；
- `currentVersion` 是 `packageInfo.version`，Windows 上读 exe 的版本资源，只有语义版本 `2.2.1`，
  **不带** `-debug.N` 后缀；
- `_compareVersions` 按 SemVer 规矩办事：`leftPre == null` 时 `return 1`（正式版 > 同号预发布版）
  ⇒ `2.2.1 > 2.2.1-debug.12067` ⇒ 恒真。

所以它既不是「因为 exe 被换了才误判」，也不是偶发——**安装中途 Abort 回滚要报成功，安装器压根
没跑起来、日志一个字节都没写也照样报成功**。用户连着几天收到「更新成功」，跑的却始终是旧
Dart 代码。（正式版通道下这条判据尚有意义：target 无预发布后缀时，exe 没被换掉会比出 false。
但那也只挡得住「exe 没换」，挡不住本 bug 的「exe 换了、app.so 没换」。）

误判还会**顺手销毁重试材料**：`reconcile` 的 installed 分支按 TODO-1089 立刻回收
`updates\*-windows-setup.exe`。用户现场 updates 目录里只剩一堆 `.meta.json`，安装包一个不剩
——本来只要重跑一次那个包就能自愈，判据错了之后连包都没了。

修好 ③ 之后回收安装包这条自然消失（判为失败就不再走 installed 分支），无需单独加特例。

**④ `KillProcessesUnderDir` 是发哑弹（32 位 Inno × 64 位进程）。**
`PrepareToInstall` 本来就想在复制前清掉安装目录下的占用进程，它却从来没生效过：本安装器是
**32 位**进程（安装日志「64-bit install mode: No」，`[Setup]` 里没有
`ArchitecturesInstallIn64BitMode`），`ExpandConstant('{sys}')` 被 WOW64 重定向到
`SysWOW64`，拿到的是 **32 位 PowerShell**；而 32 位 PowerShell 读不到 64 位进程的 `.Path`
（底层 `MainModule` 跨位宽访问失败，属性取到空串），于是过滤条件 `$_.Path -and ...` 对
**每一个** 64 位进程恒假 —— `fushi.exe` / `fushi_voice_injector.exe` / `ffmpeg.exe` 一个都杀不掉。

实测（同一份命令、同一个 x64 目标进程）：

| 调用者 | 目标存活 | 文件可写 | 32 位 PS 看到的 Path |
|---|---|---|---|
| 64 位 PowerShell | 否（被杀） | True | — |
| **32 位 PowerShell** | **是** | **False** | **空串** |

这条也正面证实了 ①：launcher 全程活着（用户现场 14:58:32 安装回滚、14:58:35 app 被拉起，
正是 launcher 的 `EnsureAppBack` 干的），而不是「被杀掉后由杀软持有句柄」。

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
4. **`update_handoff.dart`**：判「装成功」改为**必须拿到正面证据**。新增
   `windowsInnoLogVerdict()` 返回三态 `succeeded / aborted / unknown`，`reconcile` 只在
   `succeeded && 版本到位` 时才判 `installed`；`aborted`（回滚）与 `unknown`（日志缺失 =
   安装没跑起来）一律走失败分支，让用户看见诊断而不是一句成功。
   `unknown` 必须判失败而不是「大概成了」——旧判据恒真的那一半正是靠「没看到失败」蒙混过关的。
   两个细节：判据取**最后一条**结论行而非「出现过某词」（Inno 在 `Rolling back changes.` 之后
   还会写回滚自身的进度）；`\b` 词边界是关键——回滚收尾写的是「**Un**installation process
   succeeded.」，裸 `contains` 会把**回滚自身的成功**读成安装成功，正好在最该报失败的那条日志上
   给出相反结论。版本判据保留为 AND 条件（正式版通道下它仍能识别「exe 根本没被换掉」）。

5. **`fushi.iss`（④）**：`KillProcessesUnderDir` 改走 `{sysnative}`（64 位 Windows 上绕过 WOW64
   重定向指向真正的 System32；32 位 Windows 上等同 `{sys}`，无平台回归），并**显式排除
   `fushi_update_launcher`**——清扫一旦真正生效，杀掉 launcher 就等于 BUG-1708 当场复发；
   它占住的文件已由 ③ 的改名让路处理。实测：修好后 helper 进程被杀、launcher 存活。

- **[x] ① 已修复** — 上述五处
- **[x] ② 已加自动化测试** — `fushi/test/utils/misc/update_launcher_self_lock_test.dart`（9 条，
  含用**用户真实失败日志**做 fixture）
  + `fushi/test/utils/misc/update_handoff_success_verdict_test.dart`（3 条，走真实 `reconcile`
  黑盒断言「回滚不报成功 / 装完仍报成功 / **日志缺失不得报成功**」；第三条在改判据前实测为红，
  即旧代码确实会把「安装压根没跑起来」说成更新成功）
  + `fushi/test/build/windows_installer_launcher_lock_guard_test.dart`
  （2 条，钉住「改名让路而非杀进程」与「sysnative + 放过 launcher」）
  + `fushi/test/build/update_launcher_relaunch_guard_test.dart`
  更新（BUG-1708 守卫跟随新契约：`--app-exe` 优先、同目录回退仍在）

### 验证

- **A/B 端到端实测**（独立最小复现，不碰用户实例）：造一个运行中的 `fushi_update_launcher.exe`
  占住自己的文件，用同样的 `/VERYSILENT /SUPPRESSMSGBOXES` 口径静默安装，两组唯一差别是
  有没有「改名让路」：

  | | setup 退出码 | 回滚 | 字母序在前的文件 | `data\app.so` |
  |---|---|---|---|---|
  | control（无修复） | 5 | 是 | **NEW** | **OLD** ← 精确复现用户现场 |
  | fixed（带修复） | 0 | 否 | NEW | **NEW** |

- 变异实测（三处，每次还原后 sha256 与变异前逐字节一致）：
  - `\b` 去掉退化成 `contains` → 精确红 1 条（`Expected: true, Actual: false`，即回滚被读成
    成功）；`update_handoff.dart` 还原校验
    `894ad1ee2eedc80c307f47f7885fd1042e15344fa1465e5758bd015e4cbd28e6`。
  - `{sysnative}` 退回 `{sys}` → 精确红 1 条；`fushi.iss` 还原校验
    `7164c29a6a42a2516d0295835a1582154754df76a8a7f780f394fde543357ad4`。
  - 删掉 launcher 的 `ProcessName` 排除 → 精确红 1 条；同一 sha256 还原。
- ④ 的行为实测：同目录下同时跑 launcher 与一个 helper，用修好的命令清扫 →
  `launcher alive=True` / `helper alive=False`（兜底保住、占用真被清掉）。
- `update_launcher.cpp`：MSVC `cl /c /utf-8 /std:c++17` 编译通过（exit 0）。
- `fushi.iss`：ISCC 6.7.1 完整编译通过（exit 0），`[Code]` 段编译无误。
- `flutter analyze`（含 test）：No issues found。
- 定向：`test/utils/misc/` + `test/build/` + 扩展页两条守卫 **412 绿**。
- BUG-1748 复验（本轮新增行为测试）：push 成全屏路由时页头确实渲染 `Icons.arrow_back` —— 确认
  那条修复本身没问题，用户看不到纯粹因为代码没装上。

### 备注

- **存量用户不需要手动操作**，下一次应用内更新即自愈。关键在于**安装器的行为由新包决定**：
  旧 app 下载新包 → 旧 launcher（仍在安装目录、仍占着自己）拉起**新包的 Inno** →
  新 `.iss` 的 `PrepareToInstall` 探测到占用 → 改名让路 → 整包装完。
  这条通道不要求用户先装上新 launcher，所以不存在「先有鸡还是先有蛋」。
  A/B 实测正是这个场景（运行中的 launcher + 仅 `.iss` 有无修复之差）：control 组回滚、
  `app.so` 停在旧版；fixed 组装完整。
  **已经卡在半更新态的用户同样自愈**，只是要等下一次发版：他们的 exe 版本号已被换成上一版
  （更新器按 `releaseSequence` 全序比较，同号不提示），所以在更高版本发布之前收不到更新提示；
  一旦发布含本修复的新版（版本号天然更高），他们点更新就走上面那条通道装完整。
  手动跑一次完整安装包只是「不想等下一版」的捷径（本轮用户即走此路）。
- **仅 Windows 受影响**：这条链路是 Inno + `fushi_update_launcher.exe` 专有，
  Android（`AndroidInstaller`）/ macOS（`MacInstaller` 解压替换）/ Linux 不走这里。
- **生效节奏**：`.iss` 那三条（改名让路 / `{sysnative}` / 放过 launcher）与握手判据修复随新版
  落地，对**存量用户下一次更新**即生效；`--app-exe` + 副本运行要等这一版装上之后的
  **再下一次**更新才走新路径（那之后安装目录里的 launcher 根本不再被持有，连改名都不需要）。
- 用户机器当前处于半更新态（新 exe + 8-19 的 app.so），需**手动跑一次完整安装包**恢复一致；
  在装上带本修复的版本之前，再点应用内更新仍会重蹈覆辙。
- ~~未做~~ **已补做**（2026-08-24，见 [BUG-1836](BUG-1836-manual-install-rescue-reports-failure.md)）：
  构建期 `--dart-define=FUSHI_BUILD_VERSION` 已注入 Dart（`fushi/lib/src/utils/misc/build_version.dart`），
  握手判据改吃这条与产物同体的证据，关于页在两个来源基版本不一致时并排显示 exe 版本
  ——「exe 与 app.so 不同步」从此可自检，不再只能靠 Inno 日志间接发现。
