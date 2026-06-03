# 合并音频来源 + 删除本地音频总开关 + 新增插到首位 — 设计

- 日期：2026-06-04
- 分支：develop
- 相关：`reference_audio_sources_model`、`docs/specs/2026-06-02-unified-audio-sources-{design,plan}.md`、`docs/specs/2026-06-02-audio-sources-dialog-redesign.md`、`docs/specs/2026-06-02-local-audio-source-order.md`

## 1. 背景与现状

「管理音频来源」对话框（`AudioSourcesDialog`，`hibiki/lib/src/pages/implementations/dictionary_settings_dialog_page.dart`）当前把音频来源分成**两个分组**：

- **远端来源**：`hibikiRemote`（Hibiki 互联）+ `remoteAudio`（自定义 URL），单独一个可拖拽 `ReorderableListView`。
- **本地音频**：`localAudio`（本地 Yomitan SQLite 库），收在一个**带 master 总开关**的可折叠分组里。

`localAudioEnabled` 这个 master 总开关是叠在每个本地库自身 `enabled` 之上的**双重 gate**：

1. **列表层**：`AppModel.enabledAudioSourceConfigs`（`app_model.dart:2540`）对 `localAudio` 加 `&& !localAudioEnabled` 过滤；legacy `enabledAudioSources`（`app_model.dart:2566`）按 master 决定是否 prepend `localAudioUrl`。
2. **末端 query 层**：每个 `queryLocalAudio` 回调都再查一次 master 才放行——`dictionary_page_mixin.dart:101/111`、`dictionary_popup_webview.dart:200/210`、`app_model.dart:2807`（`_AppModelRemoteLookupService.lookupAudio`）、`local_audio_enhancement.dart:60`（Anki 创建器）；外加 `LocalAudioManager.bindForNativeHandler`（`local_audio_manager.dart:232`）的早返回、`setAudioSourceConfigs`（`app_model.dart:2603`）按 master 重 gate native。

关键事实：native 侧 `TtsChannel.setLocalAudioDbs` 本来就只接收 `entries.where((e) => e.enabled)`（per-DB enabled）。所以 master 在 native 层是**冗余**的——真正决定某个本地库是否参与的是该库自己的 `enabled`。

## 2. 目标（用户三点要求）

1. **删掉「本地音频」的总开关**（master toggle）。
2. **把本地音频与远端来源合并成一个列表**。
3. **新增音频数据时默认插入到第一个（index 0）**。

## 3. 设计

### 3.1 删 master 总开关 → per-source `enabled` 成为唯一 gate（根因修，非补丁）

master 是「特殊情况」。消除它，让本地库与远端来源走同一套「每个来源一个 `enabled`」语义：

- 对话框删掉 master toggle，以及 `localAudioEnabled` / `onToggleLocalAudio` 两个 widget 参数。
- `enabledAudioSourceConfigs`：删 `&& !localAudioEnabled` 分支 → `localAudio` 只按 `source.enabled` gate（与 remote 一致）。
- legacy `enabledAudioSources` fallback：把 `if (!localAudioEnabled) return sources;` 改为「有任意 enabled 的本地库时才 prepend `localAudioUrl`」（`localAudioDbs.any((e) => e.enabled)`），保持「有启用本地库才查本地」的语义。此分支仅在无 typed config 的旧数据下触发，影响极小。
- 末端 query 回调（mixin / popup / 2807 / enhancement）+ `bindForNativeHandler`：去掉 `if (!localAudioEnabled)` 守卫。native 只持有 enabled 的库，per-DB enabled 自然成为实效 gate；`local_audio_enhancement` 改成无条件先查本地（native 无启用库则返回空，行为一致）。
- `setAudioSourceConfigs`：删 `await _localAudioManager.setLocalAudioEnabled(localAudioEnabled);`（第 2603 行）。`setEntries(nextDbs)` 已按 per-DB enabled 推送 native，足够。
- 彻底删除 master plumbing（不留 always-true 假壳掩盖症状）：
  - `AppModel`：`localAudioEnabled` getter（2664）、`setLocalAudioEnabled`（2639）、`toggleLocalAudio`（2666）。
  - `LocalAudioManager`：`localAudioEnabled` getter（70）、`setLocalAudioEnabled`（220）、`toggleLocalAudio`（207）。
  - `local_audio_enabled` pref：停止读写，历史值无害放置（不做迁移）。

### 3.2 合并成单列表

- 对话框 state 从 `_remoteSources` / `_localSources` 两份合并为单份 `List<AudioSourceConfig> _sources`，按保存顺序原样存放（三种 kind 混排）。
- UI 改为**单个 `ReorderableListView`**，跨 kind 可拖拽/上下移。各行按 kind 渲染：
  - `hibikiRemote`：专用标签 `t.audio_source_hibiki_interconnect` + 副标题 `t.remote_audio_source`，删除按钮 disabled。
  - `remoteAudio`：`displayLabel` + URL 副标题，可删。
  - `localAudio`：`displayLabel` + path 副标题 + `tune`（子来源编辑，`onEditLocalSources`），可删。
- 列表下方：URL 输入框（加远端，含可选「Hibiki 互联」快捷添加按钮）+「添加本地音频数据库」按钮（`onPickLocalDb`）。
- 去掉「远端来源」分组标题和「本地音频」组头；对话框自身标题「管理音频来源」已足够。
- 保存：`widget.onSave(_sources)`（单列表直传，不再拼接）。**播放优先级 = 列表顺序**，废除「远端永远在本地前」的固定约束。
- 「重置」：远端部分恢复默认 + 保留现有本地源，即 `_sources = [hibikiRemote?, ...fromLegacy(defaultAudioSources), ...existingLocal]`（不破坏/删除本地库文件）。

### 3.3 新增插到首位

- `_addRemoteUrl`：`_sources.insert(0, AudioSourceConfig.remoteAudio(url: ...))`。
- `_addLocalDb`：`_sources.insert(0, added)`。
- 「Hibiki 互联」快捷添加：保持 `insert(0, hibikiRemote())`（本已是首位）。

## 4. 数据结构 / 契约变化

- `AudioSourcesDialog` 构造签名：移除 `localAudioEnabled`、`onToggleLocalAudio`；保留 `sources`、`onSave`、`onPickLocalDb`、`onEditLocalSources`、`isValidRemoteUrl`。
- `AppModel` / `LocalAudioManager`：移除 master getter/setter/toggle（见 3.1）。
- 持久化：`audio_source_configs`（顺序即优先级）+ `local_audio_dbs`（per-DB enabled / sources）不变；`local_audio_enabled` 弃用。
- native 通道 `setLocalAudioDbs` 入参不变。

## 5. 向后兼容 / 行为变化

- **明确的行为变化（已与用户确认接受）**：master 原默认 OFF。删除后由 per-DB `enabled`（默认 true）决定，故「过去加了本地库但没开 master」的用户，那些库会自动变为启用。本项目「无老用户」前提下可接受。
- 不破坏：远端来源、子来源排序、pruneOrphans GC、投影 `audioSourceConfigs`（localAudio.enabled = 真实 db 值）均不变。

## 6. 测试

- `test/models/app_model_audio_sources_test.dart`：
  - 保留「删除本地库连带删文件」用例。
  - 删/改写两个依赖 master 的用例（`does NOT auto-toggle localAudioEnabled`、`local db enabled survives ... while master is OFF`）→ 改为验证「无 master 概念下 per-DB enabled 是唯一 gate」「round-trip 不丢 per-DB enabled」。
  - 新增：`enabledAudioSourceConfigs` 对 disabled 本地库不放行、对 enabled 本地库放行（不依赖任何 master）。
- `test/pages/audio_sources_dialog_page_test.dart`：
  - 删/改写「local audio group + master switch」用例 → 改为验证单列表渲染本地库行、无 master switch、`onPickLocalDb` 入口存在。
  - 新增：「新增 URL 插到首位」「新增本地库插到首位」守卫。
- `test/pages/local_audio_reorder_test.dart`：去掉 `localAudioEnabled` / `onToggleLocalAudio` 入参；验证单列表内本地库行可上下移、且能与远端行混排重排。
- i18n：不新增、不删除 key（避免 17 文件 churn）；`audio_sources_remote_group`、`local_audio` 即使 UI 不再引用也保留。

## 7. 验证

- `dart format .` + `flutter analyze` + `flutter test`（项目 Flutter 3.44.0 工具链）。
- 受影响为查词/播放路径，按规则需真机/模拟器复测原始失败路径（合并列表交互 + 本地音频播放 + 新增插首位生效），证据留存；设备复测在代码与单测通过后进行，标注「待设备复测」。

## 8. 受影响文件清单

- `hibiki/lib/src/pages/implementations/dictionary_settings_dialog_page.dart`（对话框重构）
- `hibiki/lib/src/settings/settings_schema.dart`（去掉 master 两参数）
- `hibiki/lib/src/models/app_model.dart`（gate / getter / setter / 2807 守卫）
- `hibiki/lib/src/models/local_audio_manager.dart`（getter / setter / toggle / bind 守卫）
- `hibiki/lib/src/pages/implementations/dictionary_page_mixin.dart`（query 守卫）
- `hibiki/lib/src/pages/implementations/dictionary_popup_webview.dart`（query 守卫）
- `hibiki/lib/src/creator/enhancements/local_audio_enhancement.dart`（query 守卫）
- 测试：上述 3 个测试文件
