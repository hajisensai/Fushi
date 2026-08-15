## BUG-1675 · galgame 捕获组件 protocol_mismatch：更新时游戏开着导致 helper 被静默跳过
- **报告**：2026-08-15（用户：Discord/QQ 截图 —— `正在监听 / 降级运行 · 系统 Loopback`，诊断行 `voice_hook open protocol_mismatch shm=13/want 15 helper=x86`）
- **真实性**：✅ 真 bug。根因是**更新链路**而非捕获链路：`fushi/lib/src/utils/misc/platform_updater.dart:906`（更新前只查 `libmpv-2.dll` 占用者，不查 helper 组件）+ `fushi/windows/installer/fushi.iss:77`（`[Files]` 换不掉被占用文件）+ `fushi/lib/src/mining/galgame_helper_installer.dart:430`（随包 zip 不存在时直接 `return true`，不校验任何版本）。

### 根因链条

1. `fushi_voice_hook.dll` 被注入游戏进程后由**游戏持有到退出**；`fushi_voice_injector.exe` 以 `--hold` 跑 host 模式维持共享内存，同样活到游戏退出（`native/galgame_hook/injector/injector_main.cpp` 用法段）。
2. 用户在**游戏还开着**时更新 Fushi。Inno 的 `[Files]` 无法覆盖这些被锁的文件，而应用内更新用 `/VERYSILENT /SUPPRESSMSGBOXES`（`platform_updater.dart:437`），**这次失败是静默的**。
3. 磁盘落地成「新 `fushi.exe`（读取端编译进当前 `kSharedVersion=15`）+ 旧 `voice_hook/<arch>/`（v13 那次构建的 injector）」。写 header 版本号的是 injector（`injector_main.cpp:1405`），所以诊断行报的是 `shm=13`。
4. 下次启动游戏，`GalgameHelperInstaller._ensureBundledVersion` 发现文件齐全 + 包里没 zip（BUG-1449 之后这是**正常情况**）→ 直接 `return true`。那里的注释写着「版本绑定由构建与安装链路保证，比运行期对账更强」——这句话在**安装链路自己被文件锁挡住时不成立**，而这恰恰是唯一没被检测的失败模式。
5. 旧 injector 建 v13 段 → v15 读取端 `ProtocolMatches` 拒绝（`fushi/windows/runner/voice_hook_reader.cpp:69`）→ `protocol_mismatch`，捕获降级成系统 Loopback。
6. 文案叫用户「彻底关掉游戏再重开一次」——对这个场景**永远无效**，因为坏的是磁盘上的文件。用户遂反复撞同一个提示（原话「怎么还有这个 bug」）。

「删掉这个检测」不可行：读取端按 `SharedHeader` 的字段偏移解释共享内存，拿 v15 的偏移读 v13 的字节是垃圾数据/越界。

### 为什么 CI 产物本身没问题

CI 每次 Windows 构建都从源码重建 helper（`build-multiplatform.yml:615`、`release-desktop.yml:396`），发布包里的 helper 不可能是旧的。漂移只在**用户机器的更新落地环节**产生。

- **[x] ① 已修复** — 三层，均针对「坏状态的产生」而非症状：
  - **应用内更新路径**：`queryWindowsGalHookModuleHolders()` 用 Restart Manager 查 `voice_hook/<arch>/` 下 exe/dll 的占用者（复用既有 `windowsProcessesHoldingFile`），并入 `_blockingWindowsInstallProcesses` → `_throwIfWindowsInstallBlocked` 在**交接给安装器之前**硬中止并指名占用进程。`platform_updater.dart` / `update_handoff.dart`（新增 `galHookModuleHolders` 字段 + wire 键 + 计入 `hasLockEvidence`，含 `voice_hook\` 路径的 Inno 删除失败也算锁证据）/ `update_checker_ui.dart`（诊断面板单列，与 libmpv 分开说，处置不同）。中止文案不再点名 libmpv。
  - **手动运行安装器路径**：`fushi.iss` 的 `PrepareToInstall` 新增 `FileLockedForWrite`（`CreateFileW` + `GENERIC_WRITE` + `dwShareMode=0`，实测「安装器能不能覆盖」，不用 `RenameFile` —— 被映射的 DLL 可改名不可覆盖会给出假阴性）/ `FirstLockedFileInDir` / `LockedGalHookComponent`，查出占用即在**复制任何文件之前**中止并说明。**故意不强杀游戏**：既有 `KillProcessesUnderDir` 只按主模块路径杀，杀得掉 injector 但杀不掉「exe 在别处、只是把我们 DLL 映射进去」的游戏；而玩家可能有未存档进度，为装更新杀掉是不可接受的破坏。
  - **文案**：`game_hook_reason_protocol_mismatch` 现在覆盖**两种**真实场景并按代价排序 —— ①先关游戏重开（清掉游戏进程里挂着的上次注入的旧组件，本体已最新时也会撞上）；②仍不一致则说明磁盘组件比本体旧（上次更新时游戏正开着），需关闭所有游戏后**重新运行一次 Fushi 安装程序**。
  - 顺手把四处硬编码的 `voice_hook` 目录名收成 `kGalgameHelperInstallDirectoryName`（查错目录的占用检测会静默返回「无人占用」，正是它要拦的那次静默失败）。
- **[x] ② 已加自动化测试** —
  - `fushi/test/utils/misc/update_handoff_test.dart`：新增两条。「更新前拦下正占用 helper 的游戏进程」断言**安装器根本没被启动**（`startCalled` 为 false）+ 报错不得含 `libmpv`；另一条覆盖 `hasLockEvidence`（进程占用 / `voice_hook\` 路径的 Inno 失败都算，无关路径不算）与 wire 键往返 + 旧标记缺键读成空列表。**变异实测**：去掉 `_blockingWindowsInstallProcesses` 里的 helper 占用者循环 → 立刻红在 `Expected: throws UpdateInstallerException`；还原后 sha256 与变异前逐字节一致。
  - `fushi/test/mining/gal_ipc_contract_single_source_test.dart`：新增「还必须给出『磁盘上的组件本身就是旧的』这条处置」，钉死文案同时含 `安装程序` / `installer again` 与成因 `游戏正开着` / `while a game was running`。**变异实测**：把 zh 文案的「重新运行一次 Fushi 安装程序」换成「再试一次」→ 守卫红；还原后哈希一致。
  - 既有守卫 `gal_ipc_contract_single_source_test.dart` 在本次修复中**真的拦住了我一次**：初版文案把「重开游戏」整个删掉，被断言打回 —— 那是另一种真实场景（游戏进程里挂着旧组件），不能用一个真场景换掉另一个。两种场景现在都在守卫里。
- **备注**：
  - `fushi.iss` 的三个新函数**在真 Inno 引擎里实测过**（ISCC 编译 + 抽出同一份函数体编成独立探针跑）：无锁 → `NONE`；持写拒绝共享的句柄锁住 `voice_hook/x86/fushi_voice_hook.dll` → `LOCKED=<完整路径>`；释放后 → `NONE`。未在本机跑真安装器，因为其 `InitializeSetup` 会 taskkill 正在运行的 Fushi。
  - 编写时踩到两个 Inno 坑，已在注释里固化：`#13#10` 出现在**行首**会被 ISPP 当预处理指令；`{ }` 注释里写 `{app}` 会让注释在 `}` 处提前结束。
  - **未做（有意，另开）**：删除随包 helper zip 通道（`galgame_helper/` + CMake install 规则 + Dart 侧 archive 解压机制）。理由：① 实测真实安装里 `{app}\galgame_helper` 已是空目录，该通道在已发布包中本就不生效，删它不修任何用户可见问题；② `magpie_installer.dart` **复用**了 `parseSha256Sidecar` / `galgameHelperSwapInstall` / `galgameHelperSweepStaleFiles`，Magpie 仍走 zip，直接删会牵动窗口超分子系统；③ 还要改 `build_distribution.ps1` / `install_into_bundle.ps1` / `fushi/windows/CMakeLists.txt` 这条发布流水线，本机无法端到端验证。与本 bug 解耦，宜单独一轮做。
