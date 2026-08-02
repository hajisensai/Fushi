## BUG-1446 · galgame 降级状态卡丢弃 injectorDetail，版本对照证据永远看不到

- **报告**：2026-08-02（用户在 debug 通道 seq 10043 = `1.3.1+1171` 上截图：「正在监听 /
  降级运行 · 系统 Loopback（混音）· 48000 Hz · 2 ch · 32 bit / 捕获组件与本体版本不一致。
  组件已内置在 Hibiki 里，不需要单独安装：先彻底关掉游戏再重开一次…」并追问「这个问题
  修复是哪个版本」）
- **真实性**：✅ 真 bug（根因 `hibiki/lib/src/pages/implementations/texthooker_page.dart:1902`，
  修复前）

### 先澄清一件事：这**不是** BUG-1345 没修好

seq 10043 = commit `0658322aa` = `1.3.1+1171`，`6727bb6bd`(BUG-1345 IPC 契约收单一真相源)、
`bfccd3129` + `50bb5248e`(IPC v13) 三个都已在内。包也确实带了匹配的组件：debug 通道走
`release-desktop.yml:331` 的 `flutter build windows --release`，`:350-357` 用**同一 commit
的 native 源码**现场构建两架构 helper zip 复制进 `galgame_helper/`；`hibiki.iss:45` 是
`ignoreversion recursesubdirs`，覆盖安装会一并换新。host 侧自 BUG-1345 起直接 include
真相源，与随包 helper 编的是同一份头文件——**包内不可能对不上**。

所以用户看到的 `protocol_mismatch` 只可能来自「共享内存段不是这个包建的」。而要判断到底
是哪一侧、差了几个版本，唯一的依据就是下面这条被丢掉的证据。

### 根因

**证据在最后一米被抹掉。**

链路本来是齐的：native `ProtocolMismatchDetail`（`hibiki/windows/runner/voice_hook_reader.cpp:67`）
逐字段生成 `shm=12/want 13` / `ipc=…` / `luna_abi=…` 的**双方版本对照**，`Open` 失败时
写进 `out.detail`（`:307`）→ `flutter_window.cpp:1826` 以 `detail` 回传 Dart →
`_activateLoopback(detail: galHookDiagnosticsDetail(diagnostics))`
（`gal_hook_session_controller.dart:1086`）存进 `GalHookSessionState.injectorDetail`。

而常驻会话卡 `_SessionOverviewCard`（`texthooker_page.dart:1898-1910`，修复前）只渲染

```dart
galHookFailureLabel(state.injectorFailure) ??
    galHookFallbackLabel(state.fallbackReason!) ??
    state.fallbackReason!
```

——`state.injectorDetail` 一个字都没用上。

漏检原因：BUG-1216 立的规矩是「有原因时也要给证据」，但只落在**一次性 toast**
（`gal_hook_failure_text.dart` 的 `_annotate`，`galHookLaunchOutcomeMessage` 用）。常驻状态卡
是**另一条渲染路径**，各写各的，从没被那条规矩覆盖过。于是归类越准，用户在最常盯着的
位置拿到的事实越少——正好是 BUG-1216 自己批判过的形态，换了个地方复发。

后果：用户读到「先彻底关掉游戏再重开一次」，照做也不会好，因为**真正漂开的是谁**根本
没显示；排障者也无法在「一台跑得通、一台跑不通」之间做任何对比。

### 修复与测试

- **[x] ① 已修复**（`texthooker_page.dart` / `gal_hook_failure_text.dart`）——
  三级取值抽成顶层 `galHookFallbackHeadline`（行为逐字不变，只是脱开 widget 可测），
  `state.injectorDetail` 作为**独立一行**渲染在处置文案下方。
  **为什么必须独立一行**：处置那行有 `maxLines`（compact 只有 2 行）+ `TextOverflow.ellipsis`，
  而 `game_hook_reason_protocol_mismatch` 文案本身就有八十多字；证据缀在尾部会被省略号
  整段吃掉，改了跟没改一样。toast 没有行数限制，才继续用「结论（原因 · 证据）」单串拼法
  ——介质不同规则不同，硬统一反而丢事实。
- **[x] ② 已加自动化测试** —— `hibiki/test/mining/gal_fallback_detail_surfacing_test.dart`：
  ①`galHookFallbackHeadline` 三级取值（处置 → 降级原因人话 → 内部代码兜底，绝不编造）；
  ②会话卡必须渲染 `state.injectorDetail`；③证据必须独立成行（`maxLines: 1`）且不得回塞进
  `galHookFallbackHeadline` 的实参。私有 widget 够不着 widget 测试，源码扫描是这条回归
  最强的可落地层，锚点走 `source_guard` 的词法掩码（注释里的同名文本不算数）。
  三条守卫各做了变异实测：把证据换成 `state.lastError`、把 `maxLines` 改成 2、把
  `injectorDetail` 拼回 `fallbackReason` 实参，逐条如期判红；反向替换还原后 47 项
  定向测试（本文件 + `gal_shm_open_error` + `gal_hook_launch_outcome_and_encoding` +
  `gal_ipc_contract_single_source`）全绿。

- **备注**：本条只解决「证据到不了用户」。用户那台机器上 `protocol_mismatch` 的**具体
  成因**仍未定性——修好后重跑一次原始路径，卡片上会直接显示 `shm=X/want Y` 之类的对照，
  届时才能判断是残留旧会话进程、还是别的局面。这也正是本条修复的目的：让下一次报告
  自带确诊依据，而不是再来一轮「照着提示做了但没好」。
