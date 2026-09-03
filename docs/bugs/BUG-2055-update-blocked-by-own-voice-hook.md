## BUG-2055 · 应用内更新被 Fushi 自己注入游戏的 voice hook 挡住，报错却称占用者为「非 Fushi 程序」
- **报告**：2026-09-02（用户贴 error_log：`UpdateChecker.downloadAndInstallUpdate` / `WindowsInstaller.launchFailed`，目标 `D:\APP\Hibiki`，Holders `PID 80572: D:\APP\GalGame\屋上の百合霊さん\屋上の百合霊さんフルコーラス.exe`，安装包 `fushi-2.2.4-debug.13092-windows-setup`）
- **真实性**：✅ 真 bug（两条，均在更新链路的**占用者分类与报错**这一层，不在注入链路）。根因 `fushi/lib/src/utils/misc/platform_updater.dart:1004`（`_installerCanClose` 用写死的 image 名清单当「安装器处置得掉吗」的判据）+ 同文件 `:993`（把所有外部锁统称 `non-Fushi process`，抹掉了「占用者是被 Fushi 自己注入的程序」这个成因）。

### 现场取证（本机实测，2026-09-02 23:0x）

| 事实 | 取法 | 结果 |
|---|---|---|
| 谁占着安装目录 | Restart Manager（与 `windowsProcessesHoldingFile` 同机制）扫 `D:\APP\Hibiki\**\*.{dll,exe}` | PID 80572（游戏）持有 `voice_hook\x86\fushi_voice_hook.dll` 与 `LunaHook32.dll`；其余全部由 PID 66636（Fushi 本体）持有 |
| 游戏到底映射了哪几份 | `CreateToolhelp32Snapshot(SNAPMODULE\|SNAPMODULE32)` 枚举 PID 80572 全部 51 个模块 | 只有上面那两个安装目录模块，**暂存副本一个都没有** |
| 暂存副本被谁占着 | 同一 RM 探针扫 `%APPDATA%\Fushi\Fushi\voice_hook_runtime` | 无人占用 |
| 暂存副本是否跟得上安装 | 目录/文件属性 | 只有一个内容版本目录 `de323cc291c6453c/x86`，文件 mtime `08-28 16:51`、`fushi_voice_hook.dll` 1969152 字节；安装目录那份是 `09-02 04:27`、2199040 字节 —— **09-02 那次更新之后从未重新暂存** |
| 时序 | 进程 StartTime / 文件 mtime | 安装 `09-02 04:20`，app 启动 `12:50`，游戏启动 `16:11` —— 注入发生在当前安装之后，不是历史残留 |
| 运行中构建 | `fushi.exe` 版本资源 + `data/app.so` 字符串 | `2.2.4-debug.13075+13075`；`voice_hook_runtime` / `--unity-runtime` 均在，说明 BUG-1708 的暂存代码已编进去 |

### 根因链条

1. BUG-1708 已经把**注入运行时搬出安装目录**（`GalgameHookRuntimeStage`，`gal_hook_session_controller.dart:1164` 的 `defaultInjectorResolver` 只返回暂存副本、刻意不回退安装目录）。develop 上这条路径复核干净：`ensureStaged` 全仓只有一个生产调用点，injector 的 `DefaultDllPath()`（`injector_main.cpp:127`）取的是**自身 exe 同目录**，参数里也没有 `--dll`，`injectorPath` 为 null 时 `EngineHookGalAudioSource.start` 直接判 `helperMissing` 降级、无任何回退分支。
2. 但**只要**安装目录里的 hook 组件被某个进程持有（本次是 13075 那个构建的注入结果；扫 1107 个本地/远端 ref 没找到「合了 stage 却丢了 resolver」的分支，13075 的构建树来源未能定位），更新链路就走到 `_throwIfWindowsInstallBlocked`。
3. **缺陷 ①（判据错）**：`_installerCanClose` 只认 `fushi.exe` / `hibiki.exe` / `msedgewebview2.exe` 三个 image 名。而 `fushi.iss` 的 `PrepareToInstall` 第一步是 `KillProcessesUnderDir({app})`，按**镜像路径**清掉安装目录树内的**任何**进程（`fushi.iss:266`、`:441`）。于是安装目录里的其它自有子进程 —— 以 `--hold` 常驻的 `voice_hook/<arch>/fushi_voice_injector.exe`、`unity_audio_runtime/` 下的提取器 —— 被判成「安装器杀不掉的外部锁」，在**交接给安装器之前**硬中止更新，而安装器本来一步就能清掉它们、根本不需要用户插手。判据按名字写死，每新增一个自有子进程就要补一条特例。
4. **缺陷 ②（报错答非所问）**：抛出的文案把所有外部锁统称 `a non-Fushi process is using files in the target directory`。用户看到的是自己正在玩的游戏被称作「非 Fushi 程序」，而真相恰恰相反 —— 是 Fushi 把语音捕获组件注进了那个游戏，游戏退出前那几个文件替换不掉。手动运行安装器那条路径早就把成因讲清楚了（`fushi.iss` 的 `LockedGalHookComponent` 提示：「Fushi 的语音捕获组件会注入到你选定的程序里…并由该程序持有到它退出为止」），**应用内更新是同一件事，却给了更差的解释**。

- **[x] ① 已修复** — `fushi/lib/src/utils/misc/platform_updater.dart`：
  - `_installerCanClose` 增参 `targetInstallDir`，先问新的结构化判据 `_processImageIsUnderDirectory`（镜像是否在安装目录**树内**，与 `KillProcessesUnderDir` 同一条），名字清单退化成 WebView2 这类镜像不在安装目录里的补充项。这类「自有子进程被误判成外部锁」的特例整类消失。
  - `_processImageIsUnderDirectory` 必须比到路径分隔符：裸 `startsWith` 会让 `D:\APP\Fushi2\x.exe` 落进 `D:\APP\Fushi`，把真外部锁误判成安装器处理得掉 —— 更新照常交接、随后在复制阶段静默失败（BUG-1675 的失败形状）。
  - 报错按 `galHookModuleHolders` 拆成两段：被 Fushi 语音捕获组件注入的程序单独说明成因与处置（`Fushi's voice capture component is injected into these programs and stays loaded until they exit` + `Save your progress and close them`），其余外部锁才继续叫 `non-Fushi processes`。
- **[x] ② 已加自动化测试** — `fushi/test/utils/misc/update_handoff_test.dart`，两条新用例 + 一条既有用例的断言收紧，**三条变异全部实测**（还原后 sha256 与基线逐字节一致 `7397E26D…F5CD`）：
  - 新增「镜像在安装目录树内的自有子进程交给安装器，不再硬中止」：fixture 用 `<install>\voice_hook\x86\fushi_voice_injector.exe`，断言 `startCalled == true` 且 `launchError == null`。**变异**：删掉 `_installerCanClose` 里的 `_processImageIsUnderDirectory` 那行 → 该用例立刻红。
  - 新增「同前缀的兄弟目录不算安装目录树内，仍按外部锁硬中止」：fixture 用 `<install>-sibling\someplayer.exe`。**变异**：把 `startsWith('$dir\\')` 改成 `startsWith(dir)` → 该用例立刻红（且只红这一条）。
  - BUG-1675 那条 gal hook 用例的断言从 `contains('non-Fushi process')` 改成钉死新成因文案，并反向断言 `isNot(contains('non-Fushi process'))`。**变异**：把 hook 专属文案分支关掉 → 该用例立刻红。
  - 顺带修正了 libmpv 外部锁那条用例**自相矛盾的 fixture**：用例名写着「external process… installer cannot close it by image name」，却把 `someplayer.exe` 摆在安装目录里 —— 那正是 `KillProcessesUnderDir` 扫得到的地方。改成 `D:\Media\Player\someplayer.exe`，用例才名副其实。
- **备注**：
  - **本 bug 不改注入侧**。BUG-1708 的暂存机制在 develop 上复核为结构正确（见上「根因链条 1」的三处证据），本轮没有发现可让生产路径从安装目录注入的分支。用户机器上 13075 的行为与 develop 源码对不上，其构建树来源未能定位 —— 若后续再出现「暂存目录停在旧内容 + 游戏持有安装目录 DLL」，应先取 `%APPDATA%\Fushi\Fushi\voice_hook_runtime` 的内容版本目录与安装目录 mtime/size 对账，那是最快的判据。
  - **对用户的直接处置**：关掉游戏后重装一次即可；装上带暂存的构建后，被 hook 的游戏持有的是 `%APPDATA%` 下的副本，安装目录始终自由，这类阻塞不再产生。
  - 本轮修复**不会**让游戏被强杀：游戏镜像在 `D:\APP\GalGame\` 下、不在安装目录树内，仍然是硬中止 + 指名占用者（玩家可能有未存档进度，为装更新杀掉是不可接受的破坏，与 BUG-1675 的判断一致）。
