# 内置 Magpie 超分：阶段一落地 + 关键调研结论

- 日期：2026-07-26
- 状态：**阶段一已实现**（自建 fork + 自编 release + 客户端安装器）；**阶段二（会话联动 / UI / 真机验证）未开始**
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
