## BUG-1138 · gal 启动失败只报无信息兜底文案，失败原因在 launchGame 的 bool 返回值处被丢弃

- **报告**：2026-07-27（用户）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/mining/gal_hook_session_controller.dart:891`（`Future<bool> launchGame`）与 `hibiki/lib/src/mining/gal_hook_failure_text.dart:62`（`reason ?? lastError ?? t.game_capture_launch_failed`）。

### 现象

用户启动 galgame 失败，toast 只有一句「游戏启动或捕获失败」，没有任何可执行处置。用户无法自愈，排障时也判断不出会话停在哪一步。

### 根因

`launchGame` 返回 `bool`，把五种语义完全不同的结局压成一个比特：

| 出口 | 真实语义 | 旧实现携带的原因 |
|---|---|---|
| `!_isWindows` | 平台不支持 | 无 |
| `injector == null` | 缺 helper | `state.injectorFailure`（有） |
| `generation != _operationGeneration`（4 处） | **被更新的操作取代，本次已作废** | 无，且**完全不碰 state** |
| `_fail(engine.launch_or_inject_failed)` | 注入失败 | `state.injectorFailure`，归类不出时为 `unknown` |

抢占那四条出口既不设 `injectorFailure` 也不设 `lastError`，而 `launchGame` 开头刚 `clearLastError: true`。于是 UI 侧 `galHookLaunchOutcomeMessage` 拿到 `failure == none` + `lastError == null`，三级兜底 `reason ?? lastError ?? 兜底文案` 必然落到最后一级——**那句话不含任何信息**。

原因是在 `return false` 那一刻丢掉的，下游只拿得到一个比特，任何文案层补丁都救不回来。

次生问题两条：

1. 被抢占的那次操作会**抢先弹一句「启动失败」**，把真正生效的那次操作的结果盖掉——用户看到的失败其实来自一次已作废的操作。
2. `diagnostics.stderrTail`（injector 的 native 一手证据）明明有内容，却停在 controller 内部，从不进入 UI。

### 修复

修在返回类型上，让编译期强制每条出口说明原因：

- 新增 `GalHookLaunchFailureReason`（`unsupportedPlatform` / `helperMissing` / `injectionFailed` / `superseded`）与 `GalHookLaunchResult`；`failed()` 构造断言原因不得为 `none`——「没有原因的失败」在构造处就被挡掉。
- `launchGame` 返回 `GalHookLaunchResult`，八条 return 全部携带原因与 native 诊断。
- 新增 `GalHookLaunchOutcome.superseded`，`galHookLaunchOutcomeMessage` 对它返回 `null` = **不播报**（取代它的那次操作会播报自己的结果）。
- 归类不出来时把 native 诊断（`exit=<码>` + stderr 最后一行结论）附进文案，信息不再被丢弃。
- 零新增 i18n key。

- **[x] ① 已修复** — `hibiki/lib/src/mining/gal_hook_session_controller.dart`（新增 `GalHookLaunchFailureReason` / `GalHookLaunchResult`、`launchGame` 改返回结构化结果、`classifyGalHookLaunchOutcome` 改吃结果）、`hibiki/lib/src/mining/gal_hook_failure_text.dart`（`galHookLaunchOutcomeMessage` 返回可空 + `galHookDiagnosticsDetail`）、三个调用点 `galgame_home_page.dart` / `games_library_page.dart` / `texthooker_page.dart`。
- **[x] ② 已加自动化测试** — `hibiki/test/mining/gal_hook_launch_outcome_and_encoding_test.dart` 新增 group「启动失败必须带原因 (BUG-1138)」7 例：失败不允许留空原因（构造断言）、被取代 → `superseded` 且不播报、每个原因都有确定分级、**归类不出来时 native 诊断必须进入文案**、诊断摘要取 stderr 结论行而非中途进度、无诊断时不编造原因、源码守卫禁止 `launchGame` 退回 `bool`。另在 `gal_hook_session_controller_test.dart` 的提权失败用例上补断言 `reason == injectionFailed` 且诊断保留 `elevationRequired`。

### 备注

本 bug 由「用户报启动失败但现场无法定位」引出：当时 injector 侧全链路实测健康（`OK hooked`、共享内存五个版本字段与 app 常量逐字节一致、`sample_rate=44100 hooked=1` 音频在写、关上一局立刻开下一局也通），失败只可能在 app 编排层，而 app 恰好只给出这句无信息兜底文案，导致无从追查。修复后同一现场会直接给出结构化原因或 native 诊断。

未随本 bug 修复的相邻问题（另行立项）：`voice_hook_reader.cpp:204` 的 `ProtocolMatches` 把 magic/version/ipc/luna_bridge/luna_vendored 五个字段全等作为唯一判据，任一不符即整块拒绝，而 UI 提示是「捕获通道无法打开，请重启 Hibiki」——版本不匹配时重启无效，且不区分「映射不存在」与「版本不符」、不打印双方版本号。
