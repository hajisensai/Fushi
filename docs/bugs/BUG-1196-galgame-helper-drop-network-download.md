## BUG-1196 · 删除 helper 网络下载与后台自更新，只保留随主包归档
- **报告**：2026-07-28（用户：「转区都内置了，网络下载可以删掉了」。）
- **真实性**：✅ 真（可移除的攻击面 + 死代码）。核实：`galgame_helper_installer.dart` 的随包路径 `_installBundledHelper` → `_installVerifiedZip` 已完全自洽（SHA-256 侧车校验 → staging 解压 → 清单复检 → 原子换入），网络路径只是它的兜底；两架构 zip 与侧车确实随 Windows 主包发布（用户机 `D:\APP\Hibiki\galgame_helper\voice_hook_x86.zip`，x86 归档内含 `LoaderDll.dll` / `LocaleEmulator.dll`，转区组件齐全）。
- **为什么该删（不只是「用不上了」）**：BUG-1103 记过这条链路的攻击面 —— 包内是 injector exe + **会被注入用户游戏进程**的 hook DLL，换掉一次即任意代码执行；而 `updateInstalledHelpersInBackground` 每次 app 启动都会**无 UI 静默**走一遍下载安装。既然产物已随主包交付，再留一条「后台静默从网上取原生代码并注入」的通道，换来的便利远抵不上它的风险。附带收益：helper 版本与 app 版本强绑定，不再有 helper 与 app 各自漂移的版本组合。
- **[x] ① 已修复** —
  - `galgame_helper_installer.dart` 1214 → 约 570 行：删掉 `updateInstalledHelpersInBackground` / `_updateArchSilently`（后台自更新）、`_confirmDownload` / `_HelperDownloadDialog`（确认与进度框）、`_downloadAndExtract` / `_installCore` / `downloadZip` / `_downloadZip` / `fetchSha256Sidecar` / `_fetchSha256` / `_probeSize` / `_open`，以及 release tag / repo slug / 镜像前缀 / 可信侧车主机 / 两个侧车超时等常量。
  - `ensureInjector` 收敛成三条路：已完整 → true；缺失或残缺 → 随包归档安装/修复 → 复检通过 true；随包缺失或校验失败 → toast + false。**残缺不再逐文件补齐**（归档是整包按 SHA-256 钉死的，逐文件补等于放弃整包校验），与首装共用同一条路。
  - 新增 i18n `game_helper_bundle_missing`：随包归档缺失（开发构建 / 早于随包发布的旧包）时提示「更新 Hibiki 获取」，与「装到一半坏了」的 `game_helper_install_incomplete` 分开。
  - `main.dart` 删掉后台自更新调用，原位留反悔注释。
  - 当时 `magpie_installer.dart` 仍保留独立下载路径；该临时边界已被后续
    [BUG-1246](BUG-1246-magpie-bundled-only.md) 取代，当前 helper 与 Magpie 都只认主包随附归档。
- **[x] ② 已加自动化测试** — `hibiki/test/mining/galgame_helper_no_network_guard_test.dart`（原 `galgame_helper_background_update_guard_test.dart` 反转重写）：守卫安装器源码里不得出现 `HttpClient` / `applyUpdateProxy` / `ResumableDownload` / `https://`，不得再有 `updateInstalledHelpersInBackground` 且 `main.dart` 不再调用，随包归档仍是唯一来源且校验/清单复检两道门都在。BUG-1246 后该守卫也覆盖 Magpie。`galgame_helper_installer_test.dart` 719 → 286 行（删掉 URL 构造 / 镜像候选 / 自更新判据 / 真实 HTTP 侧车抓取 / zip 下载等已无对象的组）；`galgame_helper_launch_guard_test.dart` 的「确认对话框时序」整组随之移除并留注释指向新守卫。
  - **开发构建也随包**（用户拍板：「开发模式也跟着打包不就行了」）：`hibiki/windows/CMakeLists.txt` 新增 `install(FILES ... OPTIONAL)`，从 `native/galgame_hook/dist/` 把 `voice_hook_{x64,x86}.zip[.sha256]` 拷进 bundle 的 `galgame_helper/`。此前这个目录**只**由 CI 在 `flutter build windows` 之后的一个独立 YAML 步骤创建（`release-desktop.yml` / `build-multiplatform.yml`），CMake 构建图里根本没有它 —— 于是 `flutter run` 出来的 exe 旁边永远没有 `galgame_helper/`，`_installBundledHelper` 在 `if (!hasZip && !hasSidecar) return false;` 当场返回 false，开发模式下 galgame hook 完全用不了。现在与 release **同源、同文件名、同目标目录**，发布产物结构一个字节没变（CI 那步照旧保留，`tool/check_release_policy.ps1` 也禁止删它；它跑在 install 之后，是幂等覆盖）。`OPTIONAL` 让判定发生在 install 时而非 configure 时，没构建过 helper 的机器照常 `flutter build windows` 成功。开发者本地要拿到它：`native/galgame_hook` 下跑一次 `tools/build_distribution.ps1`。
- **备注**：
  - 剩余代价：**没跑过 `build_distribution.ps1` 的开发机仍然没有 helper**（zip 是 gitignore 的构建产物，不入库）。这与 release 走同一条依赖，不是特例。
  - 旧包（早于随包发布的版本）用户不再有 helper 自更新，需更新 app —— 这本来就是更正确的交付方式。
  - 用户机上 `voice_hook/x86` 与 `galgame_helper/*.zip` 已齐全，本次改动不影响其现有安装。
