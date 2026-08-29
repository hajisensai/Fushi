## BUG-1935 · 内嵌查词对无传感器引擎静默失效且无任何提示

- **报告**：2026-08-29（用户：附加不行、要用 Fushi 启动才行；但 Siglus 用 Fushi 启动也不行，白色相簿2 也不行，换启动模式也不行）
- **真实性**：✅ 真 bug（但**不是**「Siglus 内嵌查词坏了」，而是「Siglus 从来就没有内嵌查词传感器，且产品对此零告知」）。

  **事实一：内嵌查词的字形传感器只有 3 个引擎实现，Siglus 不在其中。**
  全仓只有 3 处写 `LookupHitSlot`（`native/galgame_hook/include/voice_hook_ipc.h:519`）：
  - KiriKiri：`InstallKirikiriLookupSensor()` `native/galgame_hook/hook/adapters/kirikiri_adapter.inc:5434`
  - Ren'Py：`InstallRenpyLookupSensor()` `native/galgame_hook/hook/adapters/renpy_lookup.inc:648`
  - SGRE（= STEINS;GATE RE:BOOT / M2 wind3d11，按 exe SHA-256 精确匹配的**单游戏** profile，`native/galgame_hook/hook/adapters/sgre_profile.h:20`）：`InstallSgreLookupSensor()` `native/galgame_hook/hook/adapters/sgre_lookup.inc:878`

  `native/galgame_hook/hook/adapters/siglus_adapter.inc` 全文件 `lookup|glyph|geometry|hit_test` **零命中**；`SiglusAdapter::capabilities()` `native/galgame_hook/hook/adapter_registry.inc:73-77` 只声明 `kText | kResourceAudio | kPcmAudio`。`native/galgame_hook/engine-support.yaml` 里 `ingame_lookup_geometry` **全文件只出现 1 次**（`:456`，KiriKiri），Siglus 条目（`:18`）的 text capabilities 只有 `engine_exact_utf16_hook` 与 `luna_hook`。
  另：白色相簿2 用的就是 SiglusEngine，用户举的「Siglus」和「白2」是同一个引擎，不是两个独立样本。

  **事实二：连 KiriKiri 也不是引擎级支持。** 传感器还额外门控在第三方 `textrender.dll` + 运行期探测 `global.TextRender.getCharacters`（TJS 侧探测 `kirikiri_adapter.inc:799-802`、`:3949`；负样本记录 `engine-support.yaml:516`：无 textrender.dll 的 KAG3 上 `lookup_diag` 全程 `0x00000000`）。

  **事实三（这才是可落地的 bug）：Dart 侧这条链完全引擎无关，失败时零回显。**
  - 开关 `game.ingame_lookup` 只有平台门 `Platform.isWindows`，**没有任何引擎能力门控**：`fushi/lib/src/settings/settings_schema_game.dart:83-99`（`:88` 只判平台）。
  - pref `gal_hook_ingame_lookup_enabled` **默认 true**：`fushi/lib/src/models/preferences_repository.dart:2209`。
  - 全仓 grep `supportsLookup|lookupSupported|engineSupports|supportedEngine|unsupportedEngine` → **0 命中**。
  - Dart **拿得到引擎身份**（`GalHookedLine.sourceKind`，`4 => 'siglus'`，`fushi/lib/src/mining/galgame_audio_source.dart:2640-2671`），但该身份只喂给文本线程下拉的 label，**从未喂给 lookup 逻辑**。
  - `lookup_diag` / `lookup_hit_count` 在 `fushi/lib/**/*.dart` **零命中**——Dart 根本不读诊断，UI 无从显示。唯一可观测物是写死路径日志 `%TEMP%/hibiki_glookup.log`（`fushi/lib/src/lookup/global_lookup_log.dart:12-25`），既不进 `ErrorLogService` 也不进任何页面。
  - `kLookupDiagSensorInstalled`（`include/voice_hook_ipc.h:439`）只在上述 3 个传感器里置位，因此**「引擎压根没传感器」与「传感器安装失败」在位上完全同形（全 0）**，连开发者用 `tools/lookup_probe.cpp` 也只能看到 0，无法区分二者。

  **结论**：用户在 Siglus 上看到的「开关开着、Fushi 启动也没反应、换什么模式都没反应」是**设计上的必然结果**，不是回归。产品缺陷在于：默认打开的开关 + 引擎无关的 UI + 零诊断回显，使「不支持」被呈现成「坏了」。i18n hint 里虽写了「KiriKiri 引擎，仅 Windows」（`fushi/lib/i18n/strings_zh-CN.i18n.json:3246`），但它只是一句静态说明文字，选中 Siglus 游戏时既不变灰也不提示。

  **附带订正**：`docs/agent/galgame-hooking.md` 全文 `lookup|查词` **零命中**——内嵌查词的适用范围在 agent 文档里根本没有记载，这是同类误判会反复发生的结构性原因。

- **[ ] ① 未修复** — 建议方向（按成本从低到高，需用户定范围）：
  1. **能力回显（最小）**：把 hook 侧「本引擎有无 lookup 传感器」作为一位新的 diag/capability 经共享内存回传 Dart（现有位无法表达此语义，必须新增，否则与安装失败同形），会话激活后在设置项与工作台显示「当前游戏引擎不支持内嵌查词」，并把开关置灰。
  2. **文档**：在 `docs/agent/galgame-hooking.md` 增加内嵌查词适用范围章节（当前 = KiriKiri Z 且带 textrender.dll / Ren'Py / SGRE 单游戏）。
  3. **真·实现 Siglus 传感器（大工程）**：Siglus 带 Enigma 壳（`hook/lookup_overlay_window.inc:11` 已记录），现有 `TryHookSiglusExactText()`（`hook/adapters/text_render_adapter.inc:222`）只定位整行 UTF-16 文本对象，不产出逐字几何；呈现侧已有引擎无关的分层窗口通路（`hook/lookup_overlay_window.inc`），**缺的只是传感（逐字矩形 + 命中）**。
- **[ ] ② 未加自动化测试** — 修复方案定下后补：能力位的 IPC 契约测试（对齐 `native/galgame_hook/tests/lookup_ipc_contract_test.cpp`）+ Dart 侧「无传感器引擎时开关置灰/提示」的 widget 测试。
- **备注**：本轮只做验真伪与根因定位，未改任何代码。用户报的三个现象（Siglus 不行 / 白2 不行 / 换启动模式不行）在上述根因下全部得到解释：白2 即 Siglus；启动模式（`--launch` vs `--pid` 附着）只影响注入时机，对「传感器根本不存在」这件事没有任何影响。「必须 Fushi 启动、附加不行」对 KiriKiri 是真实约束（早注入，见 `docs/bugs/BUG-1724-kirikiri-lookup-install-off-main-thread.md`），但它不是 Siglus 失败的原因。
