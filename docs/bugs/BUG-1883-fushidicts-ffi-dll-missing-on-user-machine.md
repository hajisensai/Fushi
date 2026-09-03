## BUG-1883 · 用户机报 Failed to load dynamic library 'fushidicts_ffi.dll' (126)，app 卡在初始化
- **报告**：2026-08-26（用户：Wight 转述终端用户）
- **真实性**：⚠️ **真故障，根因未定**。用户机上 `DynamicLibrary.open('fushidicts_ffi.dll')`（`packages/fushi_dictionary/lib/src/ffi/fushidicts_ffi_bindings.dart:8`）失败，`AppModel.initialise()` 抛出后落到 `fushi/lib/main.dart:1489` 的 initError 屏，app 完全不可用。**缺用户侧事实（版本号、安装方式、该目录下 DLL 在不在），无法定位到具体成因**，故本条只记已排除项与已补的门禁。

### 已确定的事实（本机取证，不是推测）
- **Win32 错误 126 在这里只可能是「不在正在运行的 exe 旁边」**。裸名 `DynamicLibrary.open` 走 Windows 默认搜索序（exe 目录 → 系统目录 → PATH），不含 CWD。对照实验：对 `fushi/build/windows/x64/runner/Release/fushidicts_ffi.dll` 裸名加载 → 126；**换绝对路径 → 加载成功（handle 非 0）**。所以 DLL 本身没坏。
- **依赖也不缺**。解析该 DLL 的 PE 导入表：`KERNEL32` / `MSVCP140` / `VCRUNTIME140` / `VCRUNTIME140_1` + 8 个 `api-ms-win-crt-*`。后者是 UCRT 的 apiset 虚拟名，由加载器映射到 `ucrtbase.dll`，**本来就不以文件形式存在**，不算缺失。zstd / libdeflate / utf8proc 全部静态链入（`native/fushidicts/CMakeLists.txt:56/59/64`）。
- **VC++ CRT 自 2026-07-06 起随包**（`71c515e1c9`，TODO-1242 P0），`release-desktop.yml:544-562` 有硬门禁。7/6 之后的版本不会因缺 VC 运行库触发 126。
- **安装脚本没有删错文件**：`fushi/windows/installer/fushi.iss:77` 的 `[Files]` 是 `{#SourceDir}\*` 整目录递归；`[InstallDelete]`（:55-62）只删 `{app}\galgame_helper`；旧名 `hoshidicts_ffi.dll` 的清理在 `[Code]` 的 `ssPostInstall`（:570 附近）——**新文件全部落地之后**才执行，注释里明确记录了为什么不能放 `[InstallDelete]`。

### 已排除
- 与 2026-08-26 合入 develop 的那批改动无关：`native/fushidicts/` 本轮零改动；`fushi/windows/CMakeLists.txt` 的改动全是注释 + 一个 `$<$<CONFIG:Debug>:...>` 参数，位置在 `install(TARGETS fushidicts_ffi ...)`（:102）**之后**；`install_into_bundle.ps1` 的四个改名/删除点都只拼固定子目录（`galgame_helper` / `voice_hook` / `voice_hook\<arch>`），`Remove-FushiHelperLeftovers` 只删 `<叶名>.stale*` 兄弟项，碰不到 bundle 根。

### 待用户补齐（决定根因分支）
1. 版本号与安装方式（全新安装 / app 内自更新 / 便携包）。
2. 报错那个 `fushi.exe` 同级目录下 `fushidicts_ffi.dll` 在不在。
3. 若是自更新后出现：`%APPDATA%\Fushi\Fushi\updates\*.install.log`。

对应的三条候选：安装包漏发（已由 ② 的门禁堵住）/ 自更新占用与回滚（`reference_fushi_update_self_held_file_locks`、Inno 回滚删「新建」保留「被覆盖」）/ 杀软隔离（无法从我方修复，只能改善报错可读性）。

- **[x] ② 已加自动化测试** — `.github/workflows/release-desktop.yml` 在 ISCC 打包**之前**新增 `Verify Windows installer payload has the core runtime`，缺 `fushi.exe` / `fushidicts_ffi.dll` / `flutter_windows.dll` 任一即硬失败。守卫 `fushi/test/build/windows_installer_payload_guard_test.dart` 钉两件事：门禁存在且在 ISCC 之前、且**缺文件那一条**确实是 `throw`；门禁里的 DLL 名与 `fushidicts_ffi_bindings.dart` 的 `DynamicLibrary.open` 实参用正则从生产代码抠出来逐字比对（不在测试里硬编码，否则改名时两边一起漂）。变异实测 3 条：去掉 DLL 校验 → 红；`throw` 降级成 `Write-Warning` → 红；生产侧改名门禁不跟 → 红；还原后两文件 sha256 逐字节一致。
- **[ ] ① 未修复** — 根因未定，不能宣称已修。已补的是**打包输入门禁**：此前 magpie 资源、ffmpeg、ffprobe、VC++ CRT 四样各有硬门禁，唯独词典引擎（缺了 app 直接起不来的那一个）零校验，而 Inno 的整目录递归打包少什么都不会报错。本仓已经改过一次名（`hoshidicts_ffi.dll` → `fushidicts_ffi.dll`），正是最容易漏的那类改动。
- **备注**：`fushi/lib/main.dart:1489` 的 initError 屏直接把 `Invalid argument(s): Failed to load dynamic library ...` 原样显示给终端用户——技术上准确，但对用户完全不可行动（既不知道缺哪个文件、也不知道该重装还是加杀软白名单）。是否把「核心组件缺失」识别成一类并给出具体指引，待根因定了再决定，避免为一个还没确认的成因写文案。
