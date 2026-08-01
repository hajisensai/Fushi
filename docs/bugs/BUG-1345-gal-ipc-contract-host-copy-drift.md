## BUG-1345 · galgame 捕获报「捕获组件版本与 Hibiki 不一致」：IPC 契约在 host 侧有手抄副本，且处置指向已不存在的动作
- **报告**：2026-08-01（用户：截图「正在监听 · 降级运行 · 系统 Loopback（混音）· 48000 Hz · 2 ch · 32 bit / 捕获组件版本与 Hibiki 不一致，请更新或重新安装 galgame 捕获组件。」并指出「咱们已经内置了，没有捕获组件版本这一说」）
- **真实性**：✅ 真 bug（两条独立缺陷，均沿真实代码路径查实）

### 根因

**① 契约有两份真相源 —— 结构性漂移源，且已经真的漂开。**

`hibiki/windows/runner/voice_hook_ipc.h` 是 `native/galgame_hook/include/voice_hook_ipc.h` 的
**手抄副本**，头注释还写着「真相源在独立仓库 hibiki-hook 的 include/voice_hook_ipc.h，须同步」——
那个仓库早已合进本仓（`bc094b89b` Add 'native/galgame_hook/'），人工同步这一步随即退化成纯粹的
漂移源：本体 `hibiki.exe` 编副本，随包内置的 helper 编真相源，常量与**结构布局**各活各的。

版本号今天恰好都是 12，但**行为已经漂开**：副本的 `HasReadyGameResourceAudio`
（`hibiki/windows/runner/voice_hook_ipc.h:79-89`，删除前）只认 KiriKiri / Siglus / ffmpeg /
VisualArts / Unity 五条，漏掉真相源里的 `kDiagTyranoAsarHooksReady` /
`kDiagBgiArcHooksReady` / `kDiagArtemisPfsHooksReady` / `kDiagCatSystem2PcmHooksReady` /
`kDiagMalieLibpHooksReady`（`native/galgame_hook/include/voice_hook_ipc.h:142-157`）。
后果：这五个引擎的资源音频 hook 装好了，host 仍判 `raw_voice_ready == false`，逐句原始语音被当成
不可用 → 整段退回系统 loopback 整机混音，即用户截图里的「降级运行 · 系统 Loopback（混音）」。

漏检原因也查清了：`hibiki/test/tools/voice_hook_ipc_contract_test.dart` 当时正是对着**副本**断言，
且断言名单是手点的两条（ffmpeg / VisualArts），漏的那五条不在名单里，所以守卫一直绿着。

只要有人只 bump 真相源的 `kSharedVersion`，副本立刻落后 → 读侧 `ProtocolMatches` 判不符 →
`protocol_mismatch`。这条路正是接下来 IPC v13（文本环按线程分道，解 256 槽挤压）必然要走的路。

**② `protocol_mismatch` 的处置是空头支票。**

文案 `game_hook_reason_protocol_mismatch`（旧值：「捕获组件版本与 Hibiki 不一致，请更新或重新安装
galgame 捕获组件。」）要求用户执行一个**已经不存在的动作**：捕获组件自 BUG-1196 起随主包内置
（`galgame_helper/` 内已校验归档，`GalgameHelperInstaller` 每次启动前按 sha256 自动换入），网络
自更新通道被整条删除，用户手上没有任何「单独更新/重装捕获组件」的入口。

真能走到这条出口只剩两种局面：本包没随附归档（开发构建 / 早于随包发布的旧包，此时
`_ensureBundledVersion` 无从对账、沿用历史遗留组件目录且**一行日志都不留**）；或随附了仍不匹配
（本体与组件不同源构建 = 发布包缺陷）。两者用户能做的都只有「换一个新版本的 Hibiki」。

### 修复与测试

- **[x] ① 已修复** — 删除 host 侧手抄副本，`voice_hook_reader.cpp` 直接 include 真相源
  （`hibiki/windows/runner/voice_hook_reader.cpp:11`），两侧从此编同一组常量与同一份结构布局，
  版本/布局漂移在结构上不再可能；顺带修好上面那条已漂开的五引擎就绪判据。
  文案改为**真正可执行**的处置：先彻底关掉游戏再重开一次（游戏进程里可能还挂着上一次注入的
  旧组件——本体已是最新时撞上这条就是这个局面，「更新本体」在那里是句废话），重开后仍不一致
  才说明这份构建没带上匹配的组件；并说明组件是内置的、没有单独安装这一步；
  `GalgameHelperInstaller._ensureBundledVersion` 在「本包无归档、沿用旧组件」这唯一的放行口留日志
  （放行是有意的，否则开发构建不能用，但必须能事后说清本体压根没带组件来对账）。
- **[x] ② 已加自动化测试** — `hibiki/test/mining/gal_ipc_contract_single_source_test.dart`：
  ①真相源确实定义契约（锚点非空）②host 读侧 include **解析后**必须落在真相源文件（不是路径串像）
  ③`hibiki/windows` 下不得有第二处契约定义 ④处置文案不得再提「重新安装/reinstall」且必须指向本体。
  三条守卫各做了变异实测（伪造副本 / 改回本地 include / 把 include 塞进块注释），逐条如期判红，
  反向替换还原后逐字节干净。`test/tools/voice_hook_ipc_contract_test.dart` 的断言搬到真相源，
  并把漂丢过的五个引擎补进名单。

- **备注**：本条只解决「契约漂移 + 假处置」。用户报告里同一批的
  「256 槽文本环挤压 → 放开非胜出线程」（看板 TODO-2184）是另一件事，需 IPC v13 按线程分道，
  单独立项。本条是它的前置：v13 必然 bump `kSharedVersion`，副本还在的话会以 `protocol_mismatch`
  的形式砸在用户脸上。
