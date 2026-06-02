# 统一音频来源 + 远端开关拆分 — 设计

- 日期: 2026-06-02
- 范围: `hibiki/` 主应用，「查词」(lookup) 设置页与音频解析路径
- 类型: UI 整合 + 根因解耦，**不改 Drift schema、不改持久化 key**

## 1. 背景与问题

「查词」设置页当前把三件概念相关的事拆成三个分散入口：

1. **管理音频来源** (`lookup.audio_sources` → `AudioSourcesDialog`)：统一列表，含
   `hibikiRemote` / `localAudio` / `remoteAudio` 三种 kind，每行已有独立启用开关、
   拖拽排序、删除。
2. **本地音频** (独立 `SettingsSection`)：全局总开关 `localAudioEnabled` + 本地库列表
   (`_LocalAudioDatabasesRow`) + 「添加本地音频库」文件选择按钮。
3. **远端 hibiki 查询** (`lookup.remote_lookup` 开关 → `remoteLookupEnabled`)：一个
   flag **同时** gate 了远端词典查询和远端音频。

数据层其实早已统一：`AppModel.audioSourceConfigs` getter 是把 `localAudioDbs` 投影成
`localAudio` 条目的合并视图，`setAudioSourceConfigs` 反向把 `localAudio` 条目派生回
`localAudioDbs`。UI 没跟上，导致同一份本地音频在两处管理、远端开关身兼两职。

### 根因点（代码位置，基于 develop f77a562be）

- `app_model.dart:2641` — `lookupRemoteAudio` 里 `if (!ignoreRemoteLookupEnabled && !remoteLookupEnabled) return null;`
  把远端音频耦合到词典远端开关上。
- `app_model.dart:2631` — `setAudioSourceConfigs` 末尾
  `setLocalAudioEnabled(nextDbs.any((db) => db.enabled))`，把全局总开关**自动派生**成
  「任一库启用」，会架空显式总开关。
- `settings_schema.dart:961-982` — 独立「本地音频」section。
- `settings_schema.dart:1357+` — `_LocalAudioDatabasesRow` widget。
- `dictionary_settings_dialog_page.dart` — 对话框缺「本地音频总开关」和「添加本地库」按钮；
  「重置默认」只 reset 远端 URL，会清空本地库+hibikiRemote 视图行。

## 2. 决策（已与用户确认）

- **本地音频总开关**：保留全局 `localAudioEnabled`，挪进对话框顶部（决策 B）。
  行为不变：总开关关闭时全部本地库失效；总开关开启时按每库 `enabled` 生效。
- **远端拆分**：拆成两个**互不影响**的独立开关——
  - 远端**词典**查询：保留 `lookup.remote_lookup` 开关，从此**只** gate 词典远端
    (`searchDictionary` 的 `tryRemoteFirst`，`app_model.dart:1749`)。
  - 远端**音频**：由「管理音频来源」对话框里的 `hibikiRemote` 条目 `enabled` 开关单独控制，
    不再受词典开关影响。

## 3. 数据模型

不改 Drift schema，不改持久化 key（`local_audio_dbs` / `local_audio_enabled` /
`audio_source_configs` / `remote_lookup_enabled` 全部沿用）。统一视图与派生逻辑
(`audioSourceConfigs` / `setAudioSourceConfigs`) 已存在，只调整总开关派生方式。

## 4. 变更清单

### 4.1 远端开关拆分 (`app_model.dart`)

- 删除 `lookupRemoteAudio` 里的 `remoteLookupEnabled` guard（连带评估
  `ignoreRemoteLookupEnabled` 参数是否还有调用者；若无则一并移除）。远端音频此后仅由
  `resolveConfigured` 中 `hibikiRemote` 源的 `enabled` gate（三处构造点
  base_source_page / dictionary_page_mixin / dictionary_popup_webview 已通过 source.enabled
  决定是否调用 `queryRemoteAudio`）。
- `remoteLookupEnabled` / `setRemoteLookupEnabled` 语义收窄为「仅词典远端」，不再被音频路径引用。

### 4.2 总开关派生修正 (`app_model.dart:2610-2634`)

- `setAudioSourceConfigs` 不再自动 `setLocalAudioEnabled(any enabled)`。改为显式：
  对话框保存时把当前总开关值一并传入（`setAudioSourceConfigs(sources, localAudioEnabled: bool)`），
  或对话框单独调用 `setLocalAudioEnabled(value)`。二选一，实现时取改动面更小者。
- 仍保留从 `localAudio` 条目派生 `localAudioDbs`（增删/重排/重命名经此 round-trip）。

### 4.3 对话框整合 (`dictionary_settings_dialog_page.dart`)

- 顶部增加「本地音频」全局总开关行（`localAudioEnabled`）。
- 底部增加「添加本地音频库」按钮：文件选择 → `appModel.addLocalAudioDb(path, displayName)`，
  复用 `_LocalAudioDatabasesRow._pickAndAddAudioDb` 的选择/命名逻辑。
- `localAudio` 行删除按钮：删除时同步删除拷贝进 app 目录的 `.db`(`-wal`/`-shm`) 文件，
  修当前「投影 round-trip 删除只清 prefs、留孤儿文件」的泄漏。实现走
  `LocalAudioManager.remove(index)` 而非裸 `setEntries`。
- 「重置默认」改为只重置远端 URL 条目，保留本地库与 `hibikiRemote`。

### 4.4 删除冗余 UI (`settings_schema.dart`)

- 删除 `settings_schema.dart:961-982` 的独立「本地音频」section。
- 删除 `_LocalAudioDatabasesRow` widget（确认无其它引用后）。

### 4.5 i18n

- 远端词典开关文案改为明确的「远端词典查询」（区别于音频远端）。
- 对话框新增「本地音频总开关」「添加本地音频库」相关文案（部分 key 如
  `local_audio` / `local_audio_add_db` 已存在，尽量复用）。
- **所有 i18n 增删改必须走 `hibiki/tool/i18n_sync.dart`**，改后 `dart run slang` +
  `dart format strings.g.dart`，禁止手改 17 份 json。

## 5. 边界与兼容性

- 老用户既有 `local_audio_dbs` / `local_audio_enabled` 原样读出，进对话框即合并视图；
  无迁移。
- 远端拆分后行为变化（**用户已确认接受**）：只开词典远端、不在对话框启用 hibikiRemote 音频源 →
  不再有远端音频；反之亦然。
- `enabledAudioSources`（legacy string 路径，给 popup webview 用）与
  `enabledAudioSourceConfigs` 都已按 source.enabled gate，拆分后保持一致。

## 6. 测试

- 单元测试：
  - `setAudioSourceConfigs` 不再自动改写 `localAudioEnabled`。
  - `lookupRemoteAudio` 不再受 `remoteLookupEnabled` 影响（远端音频只看 hibikiRemote enabled）。
  - `searchDictionary` 远端路径仍受 `remoteLookupEnabled` gate。
  - `resolveConfigured`：hibikiRemote 仅在 source.enabled 时查询远端音频。
- Widget 测试：`AudioSourcesDialog` 含总开关行 + 添加本地库按钮 + 删除本地库行（含文件清理）。
- 验证：`flutter analyze` + `flutter test`（CLAUDE.md 验证规则）。

## 7. 非目标 (YAGNI)

- 不改 Drift schema、不做数据迁移。
- 不重写 `WordAudioResolver` 解析顺序逻辑。
- 不动 native `TtsChannel` 协议。
- 不做远端词典/音频的端点配置 UI（沿用现有 SyncRepository 配置）。
