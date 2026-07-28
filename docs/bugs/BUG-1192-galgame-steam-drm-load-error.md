## BUG-1192 · Steam 游戏直接启动撞 DRM 报 Application load error 3
- **报告**：2026-07-28（用户：「steam 游戏启动也有问题」，附 Steam 库截图：《千恋＊万花》显示「正在运行」，弹窗 `Steam Error / Application load error 3:0000065432`。）
- **真实性**：✅ 症状真。⚠️ **根因是静态推断，证据等级只到 `candidate`（未复现、未取证）** —— 见下方「阻塞前置」。`Application load error 3:0000065432` 是 SteamStub DRM 在**非 Steam 上下文直接启动 exe** 时的固定报错。在我们代码里**最可能**来自这条路径：AppID 发现失败 → `ChooseSteamLaunchStrategy("")` 返回 `kDirectExecutable`（`native/galgame_hook/include/steam_launch.h:61-69`）→ `RunLaunch` 走裸 `CreateProcessW`（`injector/injector_main.cpp:2024-2028`）→ 撞 DRM。**注意这条链本身尚未被证实是本次故障的实际路径**：用户截图只证明 Steam 弹了 DRM 错，没有证据表明该进程是由 Hibiki 拉起的。
- **根因（推断）**：AppID 发现**只有一条来源**，且强依赖路径字面量。`ParseSteamLibraryPath`（`steam_launch.h:25-45`）要求 exe 路径里出现 `\steamapps\common\`，再拿其后的 `installdir` 去比 `appmanifest_*.acf`（`injector_main.cpp:1798-1829`）。全仓核实过确无第二条来源（无 `steam_appid.txt` 读取、无 `libraryfolders.vdf` 遍历、无注册表、无 DB 列、无 CLI 手填）。游戏被移出标准库目录、走软链接、或库结构不同，这条就必然失败。
  ⚠️ **本机取证不能外推**：本机 Steam 装在 `D:\steam`，`steamapps\common\` 下 80 个目录里没有千恋万花、也没有 `appmanifest_1144400.acf`。但**本机库结构与用户那台机器无关**，这条只说明「本机复现不了」，不能据此断定用户机上「发现必失败」。
- **次生问题（同等重要，这条已核实）**：发现失败后是**静默回退**直接启动，且比原稿描述的更彻底 —— AppID 为空时整个 Steam 分支被跳过，零 stderr 输出；`LaunchFailureReason` 里没有任何 AppID 相关枚举，Dart 侧只有 `steamTimeout`。用户只看到游戏自己弹的 DRM 错误码，完全无从判断是 Hibiki 启动方式不对。（订正：`injector_main.cpp:2024` 那句 "Never-break fallback to CreateProcessW" 讲的是 **Locale Emulator 失败**后的回退，不是 Steam 策略回退；静默的结论不变，引证换成上面这条。）
- **🔴 阻塞前置（修复开工条件）**：动手前必须先向用户取得 ①《千恋＊万花》在**他那台机器**上的完整 exe 路径与 Steam 库布局，② 该进程确实由 Hibiki 拉起的证据（injector 日志 / 进程父子关系）。缺这两样，上面的根因停在 `candidate`，按 `docs/agent/galgame-hooking.md` 的证据门不得据此声称已定位，更不得声称已修复。
- **[ ] ① 未修复** — 方案：
  1. **AppID 多源发现**，按可靠性排序：① exe 同目录及父目录若干层的 `steam_appid.txt`（Steam 官方约定文件，与路径无关）；② 现有的 `steamapps\common` 路径解析；③ 读 `libraryfolders.vdf` 遍历**所有**库的 appmanifest 反查。
  2. **检测「这是不是 Steam 游戏」**：exe 同目录有 `steam_api.dll` / `steam_api64.dll`，或 exe 导入表含 steam_api。这个判据与路径无关，是可靠信号。
  3. **检测到是 Steam 游戏但 AppID 未知时不再静默直接启动**：回报专门的失败原因（新增 `LaunchFailureReason::kSteamAppIdUnknown`），UI 说人话 —— 「这是 Steam 游戏但认不出 AppID，请从 Steam 启动后用『绑定』，或手动填 AppID」。
  4. 允许在游戏库条目里**手工指定 Steam AppID**（可复用现有 `galgames.launch_args` 或新增列），指定后直接走 `steam://run/<appid>`。
- **[ ] ② 未加自动化测试** — 计划：`native/galgame_hook/tests/steam_launch_test.cpp` 扩充 —— `steam_appid.txt` 各层级发现、多库 `libraryfolders.vdf` 反查、Steam 依赖检测的正负例、以及「是 Steam 游戏 + AppID 未知 → 不得返回 kDirectExecutable」的守卫。
- **备注**：
  - 另有一条已知代价：走 `steam://` 协议时**转区会被丢弃**（`injector_main.cpp:1985-1991` 明确告警「Steam protocol launch cannot preserve the Locale Emulator create-suspended boundary」）。千恋万花这类 Steam 上的日文 galgame 因此拿不到 CP932，属于同一条链路上的下一个边界，待 ① 修完后单独评估。
  - 修复须改 native 并**重新构建双架构 helper + 重发 release**；开工前须按根 CLAUDE.md 读 `docs/agent/galgame-hooking.md` 并走证据门。
  - 复现需要用户那台机器上千恋万花的实际 exe 路径 —— 本机全盘搜索未找到（不在 Steam 库目录，也不在 D:\ / Downloads 的常见位置）。这正是上面「阻塞前置」的由来。
  - 本条只做定位、不改代码；`native/galgame_hook/engine-support.yaml` 未碰，无任何引擎支持状态变更。
