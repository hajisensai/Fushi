# 内置 Magpie 超分：阶段一落地 + 关键调研结论

- **当前实现说明（2026-07-29 / BUG-1246）**：本文保留阶段一“按需下载”方案作为历史调研，
  但运行时已经收口为 Windows 主包随附精简版的唯一来源。客户端不再包含下载确认、HTTP/
  镜像兜底或后台自更新；缺包视为正式包交付错误并明确报告“安装包不完整”。以下涉及 `needsDownload`、
  `magpie_download_confirm.dart` 和远端更新的章节均已被 BUG-1246 取代。
- 日期：2026-07-26
- 状态：`implemented_unverified` —— **阶段一 + 阶段二代码已实现**；**真机验证仍为零**
  （详见文末阶段二 §6）。BUG-1246 的随包收口同样未经真机验收，不得据此宣称
  「窗口超分已支持/已修好」。
- 需求原文（用户拍板，不再论证）：「我们自己编译吧，mpv，hook 等一样。方便修改。和 hook 一样启动游戏之前下载」
- 上游：[Blinue/Magpie](https://github.com/Blinue/Magpie)，GPL-3.0，基线 `v0.12.1`（2025-08-27）
- 我们的 fork：<https://github.com/hajisensai/Magpie>（public，分支 `dev`，fork 自上游 `e6167ef`）

---

## 0. 核心判断

```text
【核心判断】
✅ 值得做，但**最重要的前提是错的**——继续做，方案要改。

【关键洞察】
- 数据结构：客户端侧只有一个核心状态——「exe 同级 magpie\ 目录的完整性 + 一枚
  installed.sha256 装机标记」。下载/校验/换入/自更新全部围绕这一个标记展开，
  与已验证的 galgame helper 安装器共用同一套原语，零第二实现。
- 复杂度：**便携配置这块的复杂度可以归零**。原计划「预写 config.json 强制便携模式，
  并按 CONFIG_VERSION 做 schema 兼容」是伪需求：Magpie 只看文件是否存在，不看内容；
  而写一个 `{}` 反而会毁掉缩放（见 §3.2）。正确实现是**写一个 0 字节文件**。
- 风险点：「浮窗夺焦会打断全屏缩放」这个立项前提**在 v0.12.1 上不成立**（见 §3.1）。
  真正会踢掉缩放的是另一条路径——自动缩放的 50ms 前台轮询。
```

---

## 1. 阶段一交付物

### 1.1 我们自己的 Magpie fork 与自编产物

| 项 | 事实 | 证据 |
|---|---|---|
| fork 仓库 | `hajisensai/Magpie`，public，默认分支 `dev` | `gh repo view hajisensai/Magpie` |
| fork 基线 | 上游 `dev` 的 `e6167ef`（release 基线 `v0.12.1`） | `git log -1` on fork |
| 我们的 commit | `ca6491c` ci: add Hibiki self-build release workflow + GPL fork attribution | fork `dev` |
| 源码改动 | **`src/` 下零改动**；只加了 workflow + `HIBIKI-FORK.md` + README 顶部指针 | 同上 |
| GPL 合规 | fork 为 public、上游 `LICENSE` 与版权声明未动、`HIBIKI-FORK.md` 记录基线 commit 与全部改动 | `HIBIKI-FORK.md` |

### 1.2 Magpie 构建体系（权威来源 = 上游 CI 定义，非记忆）

| 维度 | 事实 | 证据 |
|---|---|---|
| 构建入口 | `python scripts/publish.py`，内部调 `msbuild Magpie.slnx -m -t:Rebuild -restore` | `scripts/publish.py:62-64` |
| 无 CMake / 无 build.ps1 | 顶层没有 CMake；CMake 只被 Conan 内部用来编依赖 | `src/_ConanDeps/_ConanDeps.vcxproj:117` |
| CI runner | `windows-2025-vs2026`（**不是** windows-latest；GitHub 官方镜像，见 runner-images 的 `Windows2025-VS2026-Readme.md`） | `.github/workflows/build.yml`、`release.yml` |
| 编译器 | 上游正式 release 只用 **ClangCL**；CI 日常构建 MSVC×ClangCL 各出 x64/ARM64 | `release.yml`（`--compiler=ClangCL`）、`build.yml` matrix |
| 工具链 | VS2022 或 VS2026 + 「使用 C++ 的桌面开发」+「通用 UWP 开发」；Windows SDK **10.0.26100**；C++20；C++/WinRT 3.0；WinUI **2.8.7**（UWP XAML Islands，不是 WinAppSDK / 不是 C#） | `docs/编译指南.md:1-21`；`src/Magpie/Magpie.vcxproj:17-20`；`src/Magpie/packages.config` |
| 依赖 | NuGet（packages.config 老式，靠 `-restore -p:RestorePackagesConfig=true`）+ **Conan**（fmt/spdlog/imgui/rapidjson… `--build=missing`）；**无 vcpkg、无 git submodule** | `src/Magpie/conanfile.txt`；无 `.gitmodules` |
| .NET | **不需要**（全仓 0 个 `.csproj`） | — |
| 产物目录 | `publish/<platform>/`（publish.py 用 `-p:OutDir` 覆盖默认 `bin/`） | `scripts/publish.py:63` |
| 产物内容 | zip 根平铺：`Magpie.exe` / `Microsoft.UI.Xaml.dll` / `resources.pri` / `TouchHelper.exe` / `Updater.exe` + `effects/`（实测 x64 包 10,832,614 B，共 173 个条目） | 实测 `Magpie-v0.12.1-x64.zip` 解包清单 |
| 上游校验和 | 只有 **MD5**，写在仓库 `version.json` 里给它自己的更新器用；**没有 sha256 侧车** | `scripts/release.py`；`src/Magpie/UpdateService.cpp` |
| 构建耗时 | **无证据**。上游 workflow 无 `timeout-minutes`，文档也无耗时描述。定性上首次冷构建偏慢（`-t:Rebuild` 全量 + LTCG/LTO + Conan `--build=missing` 现编 9 个依赖 + C++/WinRT 代码生成 + XAML 编译），故上游 CI 专门缓存 `~/.conan2/p` | `.github/workflows/build.yml` 的 Conan cache 步 |

### 1.3 我们的 release workflow

`hajisensai/Magpie` 的 `.github/workflows/hibiki-release.yml`（上游 `release.yml` **未动**）：

- 只 `workflow_dispatch`（照本仓 `.github/workflows/ffmpeg-min.yml` 的手动触发范式）。
- 固定 tag **`magpie-hibiki`** 反复 upsert 同一 prerelease、非 Latest（照 `hibiki-hook` 的
  `voice-hook-helper` 约定）。
- 产物 `Magpie-hibiki-<platform>.zip` + **`.sha256` 侧车**，platform ∈ {x64, ARM64}。
- 包内多塞一个 `hibiki-magpie.json`：`upstreamVersion` / `forkCommit` / `forkRepo` /
  **`configVersion`（从 `src/Magpie/AppSettings.cpp` 现场 regex 提取，提不到直接让 job 失败）**
  / `platform` / `builtAt`。这是客户端与 Magpie 私有实现之间唯一的契约面。
- 发布前守卫：必需文件存在 + `effects/` 文件数 ≥ 100，否则 job 失败（防止发一个装了等于没装的包）。
- **不签名**：签名需要 `secrets.MAGPIE_PFX_PASSWORD`，fork 没有；`publish.py` 只在传
  `--pfx-path` 时才签名，省略即可。代价是 Magpie 的 TouchHelper UIAccess 注册不可用（Hibiki 不用触摸）。
- 不传 `--version-*`：产物版本号为 `0.0.0`，即 Magpie 自己的「开发版」标识。**故意的** ——
  自编二进制不应冒充某个官方版本号。

> ⚠️ **产物文件名有意偏离用户原话**。用户要求 `Magpie-hibiki-<ver>-x64.zip`；实际发的是
> `Magpie-hibiki-x64.zip`（无版本号）。理由：固定 tag 的价值就在于**直链永不变**，文件名一旦
> 含版本号，每次升级客户端的硬编码 URL 就失效，等于退回「查 Release API」的老路。版本信息
> 改放 release body + 包内 `hibiki-magpie.json`，可读性不减。这与 `voice_hook_<arch>.zip` 的
> 既有约定也一致。

### 1.4 客户端安装器 `hibiki/lib/src/mining/magpie_installer.dart`

照 `galgame_helper_installer.dart`（857 行，已在生产验证）的结构新建，**复用而非复制**其纯工具
（`galgameHelperCandidateUrls` / `parseSha256Sidecar` / `sha256Matches` /
`galgameHelperSwapInstall` / `galgameHelperSweepStaleFiles`），只新增 Magpie 特有部分。

对外接口：

| 符号 | 语义 |
|---|---|
| `kMagpieRepo` / `kMagpieReleaseTag` / `kMagpieUpstreamVersion` | 固定仓库 / 固定 tag / 基线版本 |
| `magpieZipName(arch)` / `magpieDownloadUrl(arch)` / `magpieSha256Url(arch)` | 稳定直链拼装（不查 Release API） |
| `magpieArchForProcessorArchitecture(procArch, procArchW6432)` | 纯函数架构判定；认不出回落 x64 |
| `magpieMissingFiles(present)` / `kMagpieRequiredRootFiles` / `kMagpieRequiredDirs` | 安装完整性清单 |
| `magpieNeedsUpdate(localSha, remoteSha)` | 自更新判据（任一为 null 一律不更新） |
| `magpiePortableConfigContent()` | 便携标记内容 = **空字符串**（见 §3.2） |
| `MagpiePackageMetadata.parse(json)` | 包内元数据解析；坏数据一律 null，绝不抛 |
| `magpieCanWritePortableConfig(metadata)` | configVersion 门；不一致 → 只装不配 |
| `MagpieInstaller.installDirectory()` / `.executablePath()` / `.portableConfigPath()` | 落点（`Hibiki.exe` 同级 `magpie\`，免提权） |
| `MagpieInstaller.isInstalled()` / `.missingInstalledEntries()` | 零网络零副作用的就绪查询 |
| `MagpieInstaller().ensureInstalled({confirm, onProgress, arch})` → `MagpieInstallResult` | 交互路径主入口 |
| `MagpieInstaller.updateInstalledMagpieInBackground()` | app 启动后台静默自更新 |

设计要点（与 helper 安装器的差异都是有意的）：

1. **不含任何 UI**。是否下载由调用方通过 `confirm` 回调决定，安装器不持有 `BuildContext`、
   不引 i18n。阶段一因此**不新增任何 i18n key、不改 `strings.g.dart`**——这是三个并发代理
   共享的最高冲突文件。
2. **BUG-1076 的时序教训固化进类型**：`MagpieDownloadPrompt.sizeProbe` 是一个**已发起、
   未 await** 的 Future，`ensureInstalled` 在调 `confirm` 之前绝不等它。已完整安装时零网络
   直接返回。这两条有源码扫描守卫兜底。
3. **换入式安装**：复用 `galgameHelperSwapInstall`——旧文件 rename 成 `.stale` 让位（被进程
   映射的 DLL 在 Windows 上可改名不可覆盖），任一步失败逆序回滚。Magpie 正在运行时更新不会
   留半版本残局。
4. **降级不崩**：非 Windows → `unsupportedPlatform`；下载/校验/换入失败 → `failed`；后台
   自更新任何异常静默吞掉。绝不影响 app 或游戏启动。

### 1.5 测试

`hibiki/test/mining/magpie_installer_test.dart`，**42 passed / 2 skipped**（跳过的两条是
Windows 上不能跑真实安装路径的平台边界断言，在 Linux CI 上会真跑）。覆盖：架构判定（含
ARM64-on-x64-emulation）、zip 名与 URL 拼装、镜像候选、完整性清单大小写、自更新判据、包元数据
解析容错、便携标记的四种行为（写/不写/不覆盖/版本不符）、**解压目录结构 + zip-slip 防护
（`../` 逃逸与绝对路径条目）**、staging 元数据读取、以及 4 条 BUG-1076 时序契约的源码守卫。

---

## 2. 与 Magpie 交互的既有契约（不需要 fork 就能用的部分）

来源：上游 `docs/以编程方式与 Magpie 交互.md` 与源码交叉核对。

- 广播消息 `RegisterWindowMessage(L"MagpieScalingChanged")`：
  - `wParam=1` → 缩放开始，或源窗口回到前台；`lParam` = 缩放窗口句柄
  - `wParam=0` → **两种情况靠 lParam 区分**：`lParam=0` 缩放真正结束（`WM_DESTROY`）；
    `lParam=1` 只是源窗口转到后台，**缩放仍在跑**
    （`src/Magpie.Core/ScalingWindow.cpp:1985-1990` 与 `:900-903`）
  - `wParam=2` 窗口模式下位置/大小变化；`wParam=3` 用户开始拖动
- 缩放窗口类名 `Window_Magpie_967EB565-6F73-4E94-AE53-00CC42592A22`；其上挂只读窗口属性
  `Magpie.SrcHWND` / `Magpie.Windowed` / `Magpie.Src{Left,Top,Right,Bottom}` /
  `Magpie.Dest{...}`（`ScalingWindow.cpp:1394-1417`）
- 生命周期：注册消息 `WM_MAGPIE_SHOWME` / `WM_MAGPIE_QUIT`（**实际注册串就是这两个字面量**，
  不是 `MagpieShowMe`）+ 单实例互斥体 `{4C416227-4A30-4A2F-8F23-8701544DD7D6}`
  （`src/Shared/CommonSharedConstants.h:4,32-41`）
- **Magpie 目前没有任何双向控制通道**：全仓 0 处 `CreateNamedPipe` / `WM_COPYDATA` /
  共享内存 / socket。只有单向广播 + 只读窗口属性。

---

## 3. 三条调研结论（阶段二的输入，本轮不实现）

### 3.1 「浮窗夺焦会打断全屏缩放」——**这个立项前提在 v0.12.1 上不成立**

官方文档把「缩放结束」和「源窗口失焦」塞进了同一个 `wParam=0`，容易误读成失焦即退出。
实际源码里这是两条完全不同的路径：

- **非 3D 游戏模式（默认）**：源窗口失焦**不会**结束缩放。缩放线程每 2ms 轮询一次
  （`src/Magpie.Core/ScalingRuntime.cpp:178-186`），`ScalingWindow::_UpdateSrcState()` 取
  `GetForegroundWindow()`（`ScalingWindow.cpp:1286-1312`），`SrcTracker::UpdateState()` 只翻转
  `_isFocused` 标志、**不返回 false**（`src/Magpie.Core/SrcTracker.cpp:199-202`）。后果仅两个：
  ① 广播 `wParam=0, lParam=1`；② 缩放窗口取消置顶并把新前台窗口抬到最上
  （`ScalingWindow.cpp:1978-1980`、`_CalcTopmostState()` @ `:1993-2006`）。
- **3D 游戏模式**：唯一真正因失焦退出的分支在
  `ScalingWindow::_CheckForegroundFor3DGameMode()`（`ScalingWindow.cpp:1369-1392`），返回 false
  后走 `_DelayedStop()`（`:2143-2164`）→ `Stop()` → `Destroy()` → `WM_DESTROY`（`:869-904`）。
  该函数**已有两级例外**：系统窗口硬编码白名单 `WindowHelper::IsForbiddenSystemWindow()`
  （`src/Magpie.Core/WindowHelper.cpp:28-50`，判据是 `(exe 文件名小写, 窗口类名原样)` 二元组）
  与「重叠面积 < 8px 放行」的容差。
- Magpie 自己的缩放窗口不需要白名单：它用 `WS_EX_NOACTIVATE` + `WM_MOUSEACTIVATE` 返回
  `MA_NOACTIVATE`（`ScalingWindow.cpp:666-670`），拿不到焦点。

**改造可行性**（若阶段二实测确有问题）：

| 方案 | 位置 | 规模 | 副作用 |
|---|---|---|---|
| A. 给 3D 模式加我们自己的窗口白名单 | `ScalingWindow.cpp:1369-1376` 函数开头加一条 `hwndFore == 我们的 hwnd`（或同 PID）即 `return true` | **~3 行** | 最小；不动 z-order / 光标语义 |
| B. 不改代码，config 顶层 `"disableTopmost": true` | `AppSettings.cpp:596`(写)/`:795`(读)，消费点 `ScalingWindow.cpp:2002` | **0 行** | 缩放窗口永不置顶；但**源窗口自身置顶时仍无条件置顶**（`:1995-1997`），galgame 开了「窗口置顶」就救不了 |
| C. 把我们的浮窗当作「源窗口仍聚焦」 | `SrcTracker.cpp:199` | ~1 行 + setter | **侵入最深**：光标黑边阻挡与坐标映射跟着变（`CursorManager.cpp:760-767`、`:1153`），鼠标移到浮窗上时坐标会错 |

**真正的风险不在失焦，在别处**——UI 层有个 **50ms 前台轮询**，只要新前台窗口命中某个
`autoScale != Disabled` 的 Profile，就会 `force=true` 重启缩放（先 `Stop()` 掉当前的）：
`src/Magpie/ScalingService.cpp:42-45` + `:250-273`。
→ **硬规则：绝不能给 Hibiki 自己的 exe 建 autoScale 的 Profile**，否则浮窗一弹就把 galgame
的缩放踢掉。

### 3.2 便携配置：**原计划的 schema 兼容是伪需求，而且写 `{}` 会毁掉缩放**

- 便携判定只看文件是否存在，不看内容：
  `AppSettings::Initialize()` @ `src/Magpie/AppSettings.cpp:203-216`
  （`_isPortableMode = FileExists("config\config.json")`；CWD 在 `main.cpp:56` 已被设成 exe 目录）。
  `CONFIG_VERSION = 4` @ `AppSettings.cpp:27`，且**版本号根本不写进 config.json**，只体现在
  非便携模式的目录名 `%LOCALAPPDATA%\Magpie\config\v4\`（`AppSettings.cpp:1312`）。
- 关键陷阱：默认 scalingModes **只在配置文件不存在或内容为空时**才灌入
  （`AppSettings.cpp:218-245` 的两个分支各调一次 `_SetDefaultScalingModes()`）。若我们写一个
  `{}`，Magpie 会认为这是「有效但没有 scalingModes 的配置」→ scalingModes 数组为空 →
  所有 profile 的 `scalingMode` 索引被钳到 -1（`AppSettings.cpp:990-993`）→ 缩放报
  `InvalidScalingMode`。
- 正确实现：**写一个 0 字节的 `config\config.json`**。已核对 `Win32Helper::ReadTextFile`
  （`src/Magpie.Core/Win32Helper.cpp:350-370`）对 0 字节文件返回 true + 空串，走
  `configText.empty()` 分支灌默认值并回存。**一个 Magpie 私有字段都不用写**，schema 漂移风险归零。
- `configVersion` 门（`magpieCanWritePortableConfig`）仍保留，但它守的**不是内容**，而是
  「便携判定机制本身」：上游若哪天把标记挪走，configVersion 变化是最早的信号，此时退回
  「只装不配」比装一个假的隔离诚实。

**若阶段二真要预置一条 galgame 的自动缩放 Profile**，schema 事实（`src/Magpie/Profile.h:36-106`、
写 `AppSettings.cpp:64-147`、读 `:926-1147`、匹配 `src/Magpie/ProfileService.cpp:214-251`）：

- 顶层键是 **`profiles`**（不是 `scalingProfiles`），**数组第 0 项固定是默认/全局 Profile**。
- `packaged`（**不是** `isPackaged`）、`pathRule`、`classNameRule`、`autoScale`
  （**uint 枚举** 0=Disabled / 1=Fullscreen / 2=Windowed，**不是 bool**）、`launcherPath`、
  `launchParameters`、`name`（`name` 为空的条目会被整条丢弃）。
- `pathRule` 是 **完整路径且大小写敏感**（`ProfileService.cpp:246` 的 `std::wstring ==`，无
  `_wcsicmp`、无路径规范化）；`packaged: true` 时 `pathRule` 存的是 AUMID 而非路径。
- **没有 `scalingFlags` 这个 key**：它被拆成 `3DGameMode` / `captureTitleBar` /
  `adjustCursorSpeed` / `disableDirectFlip` 四个 bool（`AppSettings.cpp:109-116`）。
- `scalingMode` 是 **scalingModes 数组的索引（int）**，不是名字；写 profiles 就必须同时保证
  scalingModes 存在，否则又踩回上面的 -1 陷阱。
- → 结论：**不要手写 profiles**。正确做法是先让 Magpie 自己跑一次生成完整 config，阶段二再
  在既有 config 上做增量修改（或走 §3.3 的 CLI 方案彻底绕开 config）。

### 3.3 窗口化缩放（Windowed）在 v0.12 的能力与限制

不是独立代码路径，是 `ScalingOptions.flags` 的 1 号 bit
（`src/Magpie.Core/include/ScalingOptions.h:150,173`），**不存 Profile**，由触发方式决定
（`ScalingService.cpp:369`）。

能力：缩放窗口用 `WS_OVERLAPPED | WS_CAPTION | WS_THICKFRAME` 创建、owner 是源窗口
（`ScalingWindow.cpp:220-233`），**双向联动**——拖缩放窗会同步移动源窗口（保持中心重合，
`:2035-2047`），拖源窗口缩放窗跟随（`:1349-1363`），调整大小强制等比（`WM_SIZING` @ `:694-722`），
记忆上次尺寸（`:1320-1324`）。

限制（全部有 file:line）：

| 限制 | 位置 |
|---|---|
| 3D 游戏模式**不支持**窗口化 | `ScalingWindow.cpp:80-86`；预检 `ScalingService.cpp:341-343` |
| DesktopDuplication 捕获**不支持**窗口化 | `ScalingWindow.cpp:83-85` |
| 源窗口已最大化 → 直接拒绝 | `ScalingWindow.cpp:109-116` |
| `allowScalingMaximized` / `simulateExclusiveFullscreen` 被强制忽略 | `ScalingOptions.h:226-232` |
| 缩放窗口必须比源窗口大 100 DIP | `ScalingWindow.cpp:19`（`WINDOWED_MODE_MIN_SPACE_AROUND`） |

**对我们最要命的一条**：窗口模式下 `WM_WINDOWPOSCHANGED` 里有个 OS bug 兜底，会主动
`_srcTracker.SetFocus()` 把焦点抢回源窗口（`ScalingWindow.cpp:816-823`，**仅窗口模式**）。
→ 浮窗焦点会被抢走。**阶段二应优先用全屏模式，不要用窗口化缩放。**

### 3.4 给 fork 加真正的 CLI / 控制面：改动面

现状：`main.cpp:58-70` 用**整条命令行的字符串相等比较**识别参数，全仓无
`CommandLineToArgvW` / argv / tokenizer。现有参数只有三个：`-r`（注册 TouchHelper）、
`-ur`（反注册）、`-t`（静默启动不建主窗口，常量 `OPTION_LAUNCH_WITHOUT_WINDOW` @
`CommonSharedConstants.h:32`，消费点 `App.cpp:188`）。进程模型是**单进程多线程**
（缩放跑在 `ScalingRuntime` 起的独立线程，`ScalingRuntime.cpp:13`），UI 是 C++/WinRT +
UWP XAML Islands + WinUI 2.8（**没有 C#，没有 WinUI 3**）。

| 方案 | 规模 | 要动的锚点 |
|---|---|---|
| **A. 命令行参数**（推荐） | **~80–150 行** | `main.cpp:58-70` 换成真 tokenizer；`App::Initialize` 签名（`App.h:24`/`App.cpp:111`）；`App.cpp:188` 的 `-t` 判断同步改；`ScalingService.h:66-68` 的 private 缩放入口需要暴露 public（实现照抄 `ScalingService.cpp:295-303`）；`--scale-exe <path>` 还需自己枚举窗口做 path→HWND |
| B. 新注册窗口消息（双向性价比最高） | **~20 行** | `App.cpp:53-61 InitMessages()` 加一条 `RegisterWindowMessage` + `ChangeWindowMessageFilter`，`App.cpp:211` 的消息循环加一个 `else if` |
| C. 命名管道 | 比 A 贵一个数量级 | 零基础设施；需新起监听线程（不能阻塞 `App.cpp:209-219` 的裸 `GetMessage` 循环）+ 自己处理提权边界的 `SECURITY_ATTRIBUTES` |

难点（会真卡住的）：

1. **单实例会静默吞掉参数**：`App.cpp:117` 的 `_CheckSingleInstance()` 在最前，第二个实例带参数
   启动时走 `App.cpp:342` 广播 SHOWME 后直接 `return false`，**参数丢失**。要支持「转发给已有
   实例」必须在这里加转发；HWND 是整数可塞 wParam/lParam，字符串路径就得引入 `WM_COPYDATA`。
2. **初始化时序硬约束**：任何触发缩放的动作必须晚于 `App.cpp:177` 的 `ScalingService::Initialize()`；
   且 `App.cpp:151-155` 的 `IsAlwaysRunAsAdmin()` 会导致进程重启（`Restart()` @ `:242-256` 原样
   透传参数），新指令必须能在重启路径上幸存。
3. `-t` 静默启动时没有主窗口，`PostMessage(HWND_BROADCAST, ...)` 只投递顶层窗口；用户关掉托盘
   图标后广播接收面就消失了 → 新协议建议自建常驻消息窗口。

**判断**：既然 §3.1 说明失焦不是问题，阶段二应**先按官方广播契约做集成**（监听
`MagpieScalingChanged`，`wParam==1` 时把浮窗置顶），零 fork 很可能就能跑通。CLI 是次选，
只有在「必须由 Hibiki 精确控制何时对哪个 HWND 开始/停止缩放」被实测证明必要时才做。

---

## 4. 本轮**没做**的事（如实列出，不是遗漏是范围）

1. **没有任何调用方**。`magpie_installer.dart` 目前无人调用，也没挂进 `main.dart` 的启动
   后台任务（helper 的对应挂载点是 `hibiki/lib/main.dart:424`）。原因：本轮范围被限定为
   「新增安装器模块」，且会话联动涉及的
   `gal_hook_session_controller.dart` / `galgame_audio_source.dart` / `window_capture.cpp`
   有另外两个并发代理在改，硬碰会冲突。→ 阶段二一并接上。
2. **没有 UI、没有 i18n key、没有设置项**。确认下载的对话框留给调用方实现（`confirm` 回调）。
   刻意避免动 `strings.g.dart`（17 语言生成文件，并发下最高冲突面）。
3. **没有真机验证**。安装器的下载/换入/便携标记全链路**未在真实 Windows 环境跑过**：
   本轮只跑了单测与源码守卫。真机验证（含「装完能不能真的把 galgame 窗口缩放起来」）属阶段二。
4. **没有本机自编 Magpie**。本机是 VS 2022 **Build Tools** 17.14.3，缺 `Microsoft.VisualStudio.Workload.VCTools`
   （`cl.exe` / `clang-cl.exe` 均不存在，实测 `Test-Path ...\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64\cl.exe`
   → False）、缺 UWP 工作负载、缺 Conan。另有一个即使装齐也会撞的坑：`scripts/publish.py:41`
   的 vswhere 调用**漏了 `-products *`**，Build Tools SKU 下返回空 → `:44` 的
   `.splitlines()[0]` 直接 `IndexError`。→ **构建真相源是 GitHub Actions runner，不是本机。**
5. **没有解决 Magpie 自带更新器指向上游的问题**。`src/Magpie/UpdateService.cpp:66-69` 硬编码
   `raw.githubusercontent.com/Blinue/Magpie/{dev,main}/version.json`；用户若在我们的产物里开启
   Magpie 自身的自动更新，会被拉回上游官方包（覆盖掉我们的 fork 产物）。已记入
   `HIBIKI-FORK.md` 的 caveats，阶段二应考虑：① 便携 config 里关掉 `autoCheckForUpdates`
   （key 在 `AppSettings.cpp:616`，默认 **true**），或 ② 直接在 fork 里改掉那两个 URL / 摘掉
   `Updater.exe`。**注意方案 ① 又会撞回 §3.2 的「不能手写 config」陷阱**，实际上只能在 Magpie
   首次生成 config 之后再改，或走方案 ②。

---

## 5. 阶段二建议顺序

1. 真机拉一次 `magpie-hibiki` release，验证 `ensureInstalled` 全链路（下载→sha256→换入→
   空 config.json→`Magpie.exe` 能起、便携模式生效、与用户自装的 Magpie 互不干扰）。
2. 按官方广播契约做集成（监听 `MagpieScalingChanged`；`wParam==1` 时把 Hibiki 浮窗置顶），
   **先不 fork 源码**，实测浮窗夺焦到底有没有问题（§3.1 预计没有）。
3. 处理 Magpie 自更新指回上游（§4.5）。
4. 决定缩放触发方式：热键模拟 / 预置 Profile（注意 §3.1 的 50ms 轮询硬规则）/ §3.4 的 CLI。
5. 再补 UI（确认下载对话框 + 设置开关 + i18n key）与 `main.dart` 的后台自更新挂载。

---

# 阶段二：真正让它跑起来（2026-07-26）

- 状态：**代码链路已闭合，尚未真机验证**。见 §6「还差什么」。
- 本轮范围：探测 → 按需下载 → 写自动缩放 profile → 拉起 Magpie → 会话收束 → 设置项 + i18n
  + native 缩放状态回传。

## 1. 落地的模块

| 文件 | 职责 |
|---|---|
| `hibiki/lib/src/mining/magpie_upscaling.dart` | **纯逻辑**：三态枚举与偏好编解码、后端裁决 `resolveMagpieBackend`、profile 增量改写 `magpieConfigWithAutoScaleProfile` / `magpieConfigWithAutoScaleDisabled`、硬禁令守卫 `magpieProfileTargetAllowed`。不碰 dart:io / FFI / UI，任意平台可单测。 |
| `hibiki/lib/src/mining/magpie_upscaling_service.dart` | **运行时编排**：`MagpieUpscalingService.onGameWindowReady()` / `.onSessionEnded()`；Win32 边界抽象 `MagpieWin32Bridge` + 裸 FFI 实现 `MagpieWindowsBridge`。 |
| `hibiki/lib/src/mining/magpie_download_confirm.dart` | 下载确认对话框（走 `AppModel.navigatorKey`），让服务层保持零 UI 依赖。 |
| `hibiki/lib/src/mining/magpie_installer.dart` | 阶段一已有，本轮**接上调用方**（首装 + `main.dart` 后台自更新）。 |

## 2. 挂钩点（刻意压到最小，为了与 PR#423 的并发改动错开）

`gal_hook_session_controller.dart` 只多了 6 处、共约 40 行：

| # | 位置 | 内容 |
|---|---|---|
| 1 | import 区 | `magpie_upscaling_service.dart` |
| 2 | 字段区（`_activityDatabaseResolver` 之后） | `MagpieUpscalingService? _magpieUpscaling;` |
| 3 | `attachActivityDatabase` 之后 | `attachMagpieUpscaling(...)` setter（同一注入范式） |
| 4 | `magpieUpscalingTargetHwnd(state)`（静态纯函数） | 开与关**唯一**的共同判据：`boundWindow != null && phase != idle` |
| 5 | `_setState` | 只调 `_syncMagpieUpscaling()`；由它按判据的差 fire-and-forget 派开 / 关边沿 |
| 6 | `close()` / `ExitFlushRegistry` | `shutdownMagpieUpscaling()`（`urgent`，等队列排空） |

**为什么开与关必须同源（PR#430 审查修复）**：初版把「开」挂在 `_setState` 的窗口
「无 → 有」跃迁上、把「关」挂在 `stopCapture` / `close` 的方法调用点上。两边判据不同源，
立刻长出三个特殊情况：

1. `stopCapture` 的 `phase == idle && _audioSource == null` **早退分支**在通知结束之前
   就 `return` —— 而 `bindWindow` 在 idle 时已经过 `_setState` 把 Magpie 拉起来了 → 孤儿。
2. `stopCapture` 默认 `keepBinding: true` **保留 `boundWindow`** → 「无 → 有」跃迁第二局
   永远不会再发生 → 第二局起超分静默失效。
3. `close()` 在 `hibiki/lib` 里**一次都没被调用过**（桌面点 X 走 `exit(0)`）→ 正常退出
   必留孤儿。

修法不是给三处各打一个补丁，而是把两边收回同一个纯函数判据：**会话真的在跑且绑了窗口**。
判据一样，就没有分支可漏——因为压根没有分支。「只在窗口列表里选中一个窗口」（phase 仍
idle）不再拉起超分，那本来也不该动用户的显示。

注入唯一发生在 `gal_hook_text_overlay_controller.dart` 的 `start()`（`attachActivityDatabase`
紧邻）。`attachMagpieUpscaling` **同时**把 `shutdownMagpieUpscaling` 登记进
`ExitFlushRegistry` —— 登记点必须就在注入点上，放到调用方就会有人漏掉。不注入 = 全链路
`?.` 空操作，会话行为与没有超分时逐字节一致。

## 3. 三个陷阱各自怎么处理的

### 陷阱 1：50ms 前台轮询 → 绝不给 Hibiki 自己建 autoScale profile

`magpieProfileTargetAllowed(targetExecutablePath, hibikiExecutablePath)` 是**硬门不是建议**：
`magpieConfigWithAutoScaleProfile` 在验证身份完整性之后立刻调它，命中就返回
`MagpieProfileSkipReason.forbiddenTarget`。比较忽略大小写（比 Magpie 自己的匹配更严 ——
这里宁可多拒不可漏放）。单测 `🔴 硬禁令` 组 4 条。

### 陷阱 2：便携 config 必须写 0 字节

**复核结论：阶段一实现是对的。** `magpie_installer.dart:153`
`String magpiePortableConfigContent() => '';` —— 真的是空字符串、真的写出 0 字节文件。
`ensurePortableConfig` 还额外保证「已存在 config.json 就一律不动」。
本轮加了源码守卫测试钉死这一行，防止后人「顺手」改成 `{}`。

### 陷阱 3：Magpie 自带更新器指向上游

**没有改 fork，因为它在我们的产物里是死代码 —— 有完整证据链：**

| 环 | 事实 | 位置 |
|---|---|---|
| 1 | 我们的 release workflow **不传** `--version-string` | `hajisensai/Magpie` `.github/workflows/hibiki-release.yml:86` |
| 2 | 不传 → msbuild 属性 `VersionString` 为空 | `scripts/publish.py:60` |
| 3 | `VersionString` 为空 → **`MP_VERSION_STRING` 宏根本不定义** | `src/Common.Post.props:13,35`（`Condition="'$(VersionString)' != ''"`） |
| 4 | 未定义 → `UpdateService::Initialize()` **整个函数体被 `#ifdef` 编译掉**（定时器、启动检查、设置回调全没了） | `src/Magpie/UpdateService.cpp:34` |
| 5 | 未定义 → 「检查更新」按钮 `IsCheckForUpdatesButtonEnabled()` 恒 `return false` | `src/Magpie/AboutViewModel.cpp:110-116` |

即：自动检查不会启动，手动检查按钮是灰的，`CheckForUpdatesAsync` 里那两个硬编码的
`raw.githubusercontent.com/Blinue/Magpie/...` URL 永远走不到。改 fork 的 C++ 反而要
承担「本机编不了 Magpie（缺 VC/UWP 工作负载 + Conan，见 §4.4）→ 改了没法验证」的风险。

⚠️ **这条保证依赖于 workflow 永远不传 `--version-string`**。哪天有人为了让 About 页显示
版本号而加上它，更新器就会复活并把我们的产物换成上游官方包。若要把它变成结构性保证，
应在 fork 的 workflow 里发布前删掉 `Updater.exe`（纯 workflow 改动、无 C++ 编译风险）——
本轮没做。

## 4. 新增的关键 schema 事实（阶段一文档**漏了一条要命的**）

🔴 **`classNameRule` 不是可选项。** `ProfileService::_GetProfileForWindow` 先比
`classNameRule` 再比 `pathRule`（`ProfileService.cpp:220-222`，类名比取 exe 路径快得多所以
放前面）。**只写 `pathRule` 不写 `classNameRule` 的 profile 永远匹配不上任何窗口**，是一条
静默的死规则。阶段一文档 §3.2 只提了 `pathRule` 大小写敏感，没提这个先决条件。

因此 `MagpieWindowIdentity` 是 `(executablePath, windowClassName)` 二元组，运行时由
`GetClassNameW` + `QueryFullProcessImageNameW` 取（后者必须与 Magpie 的
`Win32Helper::GetWindowPath` 同源，因为匹配是裸 `std::wstring ==`）。

其余已核实：`name` trim 后非空 / `packaged` / `pathRule` / `classNameRule` 四者缺一，
`_LoadProfile` 直接返回 false 丢弃整条（`AppSettings.cpp:926-960`）；`autoScale` 是 uint
枚举 `Disabled=0 / Fullscreen=1 / Windowed=2 / COUNT=3`（`Profile.h:29-34`）；
`scalingMode` 越界钳 -1（`AppSettings.cpp:990-993`），而 `scalingMode < 0` 直接报
`InvalidScalingMode`（`ScalingService.cpp:324`）。

## 5. 生命周期（时序是硬约束，不是风格）

```
onGameWindowReady(hwnd)
  ├─ 读三态偏好 → resolveMagpieBackend
  │    installedAvailable = 我们装好了 OR 机器上已有 Magpie 在跑（互斥体）
  ├─ needsDownload → ensureInstalled(confirm)   ← 确认框立即弹，体积探测后台补
  ├─ 已有别人的 Magpie 在跑 → hotkeyOnly，什么都不碰      ← 见下
  ├─ 【必须在拉起之前】写 autoScale profile（best-effort）
  └─ Process.start(Magpie.exe, ['-t'])          ← 静默、只驻托盘

onSessionEnded({urgent})
  ├─ 没起过进程也没写过 profile → 直接回 idle（零成本，且绝不广播 QUIT）
  ├─ broadcastQuit()（best-effort）
  ├─ 等 3s（`urgent` 时 600ms），超时 kill —— 只 kill 我们自己起的那个 PID
  ├─ 静置 400ms                                  ← 见下
  └─ 把 autoScale 关回 Disabled

reconcileOrphansOnStartup()                      ← app 启动时一次，见下
  ├─ 读配置；没有开着的 `Hibiki: ` profile → 零写入零广播早退
  ├─ 【两条正向证据齐了才动】互斥体在 AND 我们那份 exe 映像被占用
  │    └─ broadcastQuit() → 轮询等它消失 → 静置 400ms → 重读配置
  └─ 把所有 `Hibiki: ` profile 的 autoScale 批量关回 Disabled
```

`urgent` 的存在理由：退出链 `ExitFlushRegistry.perCallbackTimeout` 只给每个来源 2 秒。
用 3 秒宽限等下去，注册表会先超时放行、`exit(0)` 照样把 Magpie 留成孤儿 —— 等于没修。

**为什么还要启动期对账**：退出清理只在「最好情况」下跑得完；崩溃、断电、任务管理器结束
进程都不会跑。留下的 `autoScale=Fullscreen` 就是「用户下次**不经 Hibiki** 双击游戏也被
自动全屏超分」，那是我们没被授权做的事。「是不是我们的 Magpie」只认两条正向证据同时成立
（装了我们的产物 + 我们那份 exe 的映像文件正被占用）——只有单实例互斥体在**不算数**，
那可能是用户自己装的 Magpie，硬约束 3 说了绝不动。

三条时序理由（都有源码依据）：

1. **配置必须在拉起之前写**：Magpie 只在 `AppSettings::Initialize()` 读一次 config.json，
   全仓**没有任何文件监视**（0 处 `ReadDirectoryChanges` / `FindFirstChangeNotification`）。
2. **收尾必须在 Magpie 退出之后**：Magpie 在设置变更与主窗口销毁时 `SaveAsync()` 整份回写
   （`AppSettings.cpp:287`、`MainWindow.cpp:320`）。提前改一定被覆盖。
3. **QUIT 必须有 kill 兜底**：`App::InitMessages()` 只对 `WM_MAGPIE_SHOWME` 调了
   `ChangeWindowMessageFilter`，**QUIT 没放行**（`App.cpp:57-60`）。Magpie 若自我提权运行，
   我们的广播会被 UIPI 静默丢掉。且 `-t` 模式没有主窗口，`HWND_BROADCAST` 能不能投到
   托盘窗口未经验证。

**为什么「用户自己开着 Magpie 就什么都不做」**：① 它的配置在哪我们不知道（便携 vs
`%LOCALAPPDATA%\Magpie\config\v4\`）；② 它读配置只在启动时读一次、退出又整份回写，
此时改必被覆盖；③ 那是用户的进程，我们没有权限替他关掉重开。代价是这种情况下用户得
自己按 Magpie 热键。**如实记为已知限制。**

**为什么会话结束必须把 autoScale 关回去**：留着的话，用户下次**不经 Hibiki**直接双击游戏
也会被 Magpie 的 50ms 轮询自动拉起缩放 —— 那是我们没被授权做的事。

## 6. 还差什么才能真机验证（如实清单）

1. 🔴 **`magpie-hibiki` release 从没被真的下载安装过**。`ensureInstalled` 全链路
   （下载 → sha256 → 换入 → 0 字节 config → `Magpie.exe -t` 能起 → 便携模式生效）
   本轮仍只有单测，**没有一次真机执行**。
2. 🔴 **「启动游戏 → 自动超分」端到端从没跑通过**。链路上每一环都有单测或源码证据，
   但「Magpie 读到我们写的 profile → 50ms 轮询命中 → 真的全屏缩放起来」这一步是纯推理。
   尤其 `classNameRule` 取值是否与 Magpie 的 `ParseClassName` 结果一致（它对 WPF /
   RPGMakerMZ / TeknoParrot 三类窗口有特殊解析，`ProfileService.cpp:87-99`）**未验证**。
3. ~~**首次使用必然降级为热键模式**~~ → **已修**，见 §7 的预热（bootstrap）。
4. **查词浮窗与缩放窗口的实际共存**未验证（§3.1 推断失焦不结束缩放，但没在真机上看过）。
5. `-t` 静默模式下 `HWND_BROADCAST` 的 QUIT 能否投达未验证（有 kill 兜底，不阻塞）。
6. 设置项落在「查词 → 外部集成」分组里（`lookup.galgame_upscaling`），不是独立的「游戏」
   设置页 —— 本仓目前**没有** galgame 设置 destination，新建一个的改动面远大于收益。

---

# 阶段二追加：消灭「装完第一次没反应」（2026-07-26）

上一轮自报的两条缺口（§6.3 首次必然热键模式、§6 的「`scalingActive` 接上了 native 回传却
没有任何 UI 消费」）本轮一并修掉。**能绕掉的约束就绕掉，绕不掉的才做提示。**

## 7. 预热（bootstrap）——把「第一局只能按热键」从必然变成异常

### 为什么原来必然降级

我们装完写的是 0 字节 `config\config.json`（陷阱 2 要求）。它里面没有 `scalingModes`，
而没有 `scalingModes` 就不能写 profile —— `scalingMode` 会被钳到 -1
（`AppSettings.cpp:990-993`），缩放直接报 `InvalidScalingMode`（`ScalingService.cpp:324`）。
于是第一局必然 `hotkeyOnly`。

### 绕开的办法（可行性已从源码坐实）

`AppSettings::Initialize()` 读到空配置就**当场**灌默认值并回存：

```cpp
if (configText.empty()) {
    Logger::Get().Info("配置文件为空");
    _SetDefaultScalingModes();   // 7 套缩放模式
    _SetDefaultShortcuts();
    SaveAsync();                 // AppSettings.cpp:243-246
    return true;
}
```

而 `SaveAsync()` 只是 `resume_background()` 之后直接 `_Save(data)`
（`AppSettings.cpp:287-293`）—— **没有防抖、没有定时器**，正常几百毫秒内落盘。

所以 `MagpieUpscalingService._ensureConfigMaterialized()` 做的事是：配置没就绪时**先静默跑
一次** `Magpie.exe -t` 让它自己把完整配置写出来，轮询等到 `scalingModes` 非空（上限 8s），
再把这个预热实例收掉，然后才写 profile、才真正启动。第一局就能自动缩放。

风险与代价（如实）：

- 只在配置没就绪时发生，**第二局起零开销**（只多读一次文件）。
- 整条 `onGameWindowReady` 是从 `_syncMagpieUpscaling` 里 fire-and-forget 调的，
  **预热不阻塞会话**（但每条边沿都进串行队列，退出路径 `await` 它排空）。
- 预热实例必须收干净，否则单实例互斥体会把后面真正那次启动挡掉 —— 收尾放在 `finally`，
  且有源码守卫测试钉住。
- Magpie 若坏到永远写不出配置，每局白付 8s（有上限、自清理、不影响会话）。此时降级原因是
  新增的 `MagpieProfileSkipReason.bootstrapFailed`，UI 会说人话。
- **仍未真机验证**：`-t` 静默启动能否在无人值守下走完 `AppSettings::Initialize()` 并落盘，
  是按源码推断的，没在真机上看过。

## 8. 用户可见的超分状态

`magpie_upscaling_text.dart`：枚举 → 人话，范式与 `gal_hook_failure_text.dart` 逐条对齐
（纯模型不依赖 i18n；诊断保留机器可读 `name`；**返回 null 表示无话可说，绝不编造处置**）。
硬纪律：绝不把 `bootstrapFailed` / `schemaMismatch` 这类内部枚举名甩到界面上 —— 那正是
`engine_pcm_unavailable` 当初被原样显示给用户的老毛病。有一条穷举测试遍历所有
`status × skipReason` 组合，断言用户可见字符串**不含任何**内部标识符。

落点：捕获工作台的**健康卡**（`texthooker_page.dart` 的 `_CaptureHealthCard`），紧挨着
「窗口」那一行 —— 说的是同一个游戏窗口，而且浮窗的「打开工作台」按钮就导航到这里
（`gal_hook_text_overlay_controller.dart:441`），用户想知道「超分到底开没开」时第一眼看的
就是这张卡。

两行结构（`_UpscalingHealthRows`）：

| 行 | 内容 |
|---|---|
| 状态行 | 复用既有 `_HealthRow`（label + value + `ready` 二值），与其余五行同构 |
| 处置行 | 单独一行，因为 `_HealthRow.value` 是 `maxLines: 1` 的右对齐短值，装不下一句话 |

文案分三种降级，因为对用户是三件不同的事：

- **首次初始化**（`bootstrapFailed`）：「这次 Magpie 还在做首次初始化。现在按 Win+Shift+A
  就能放大；下次启动游戏会自动放大。」—— 会自己好。
- **已有别的 Magpie 在跑**（`externalInstance`）：「你的电脑上已经开着一个 Magpie，Hibiki
  没有去动它。」—— 永远不会自己好，得让用户知道是我们有意不碰。
- **其余**：只给通用处置，不瞎解释。

另外 `active` 分两种说法：native 的 `MagpieScalingChanged` 广播回填 `scalingActive` 之前，
我们只知道「已按自动缩放配置拉起了 Magpie」，**不知道它真的放大了没有**，此时说的是「已就绪
但没有自动开始」。收到广播才敢说「已开启」。**不拿意图冒充结果。**

`MagpieUpscalingService` 因此改成 `ChangeNotifier`：所有 `_report = ...` 走一个私有 setter，
写完立刻 `notifyListeners()`，UI 用 `ListenableBuilder` 订阅。这样以后新增赋值点的人不会忘
记通知（「状态变了界面不动」太容易犯）。

## 9. 本轮仍未解决

- 真机验证依然为零（§6.1 / §6.2 原样成立）。预热、状态卡、文案全部只有单测与源码证据。
- 预热失败时每局多花 8s 的上限没有做「连续失败就不再试」的记忆 —— 现在每局都会重试一次。
  真机验证前不加这个记忆是有意的：先看它到底会不会失败，再决定要不要退避。
