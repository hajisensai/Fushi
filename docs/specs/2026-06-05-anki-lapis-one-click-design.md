# 一键创建 Lapis 笔记类型 + 卡组（全平台）— 设计

- 日期：2026-06-05
- 分支：develop
- 状态：设计已批准，待写实现计划
- 关联记忆：Anki 集成（`packages/hibiki_anki/`）、`feedback_bug_tracking_workflow`

## 1. 目标与范围

在 Hibiki 的 Anki 设置页提供「一键创建 Lapis 卡组」按钮：自动在用户的 Anki 里
创建权威的 **Lapis 笔记类型（note type / model）** 和一个默认 **卡组（deck）**，
并自动选中、填好字段映射，使用户**零手动配置**即可开始制卡。

覆盖**全部三类平台**：

- 安卓：AnkiDroid Content Provider（MethodChannel `app.hibiki.reader/anki`）。
- 桌面（Windows/macOS/Linux）/ iOS：AnkiConnect HTTP v6。

### 决策（已与用户确认）

| 决策点 | 结论 |
|---|---|
| 功能核心 | 一键创建 Lapis note type **+ 默认 deck** |
| 平台范围 | 全平台（安卓 + 桌面 + iOS） |
| 模板保真度 | **vendor donkuri/lapis v1.7.0 原版** front/back/styling 三文件 |
| deck 默认名 | `Lapis`（与 note type 同名；可后续配置） |
| 旧死代码 | 删除 `anki_integration.dart` 里 `Term/Meaning` 错误 schema 路径 |

## 2. 关键事实与约束

### 2.1 Lapis 权威定义（donkuri/lapis v1.7.0）

- 来源：<https://github.com/donkuri/lapis>（v1.7.0，2026-01-20）。
- **22 个字段**，按序：
  `Expression, ExpressionFurigana, ExpressionReading, ExpressionAudio,
  SelectionText, MainDefinition, DefinitionPicture, Sentence, SentenceFurigana,
  SentenceAudio, Picture, Glossary, Hint, IsWordAndSentenceCard, IsClickCard,
  IsSentenceCard, IsAudioCard, PitchPosition, PitchCategories, Frequency,
  FreqSort, MiscInfo`。
- **只有 1 个 card template**（默认 `Card 1`）。卡型切换不靠多模板，而是往
  `IsWordAndSentenceCard / IsClickCard / IsSentenceCard / IsAudioCard` 之一填 `x`，
  由模板内 `{{#Is...Card}}` 条件块 + 内联 JS 切换。
- front/back 用 Anki 模板语法（`{{Expression}}`、`{{furigana:ExpressionFurigana}}`、
  `{{#IsClickCard}}` 等），**非 Cloze 类型**（挖空靠 `Sentence` 里的 `<b>` + JS）。
- styling.css 含一大段**内联 JS，无任何外部依赖/CDN**（音高图自绘、释义翻页、
  图片放大、频率格式化）。不打包自定义字体，仅引用系统字体。

### 2.2 License（已查证，无阻塞）

- donkuri/lapis 为 **GPL-3.0**。
- **Hibiki 仓库根 `LICENSE` 本身就是 GPL-3.0**（`publish_to: none`）。
- 二者同证兼容：vendor 三文件合法。义务 = 保留 donkuri/lapis 版权/来源声明 +
  标注版本，Hibiki 既为 GPL 开源工程，copyleft 义务天然满足。
- 落地：vendored 内容顶部加 provenance 注释（来源 URL、v1.7.0、GPL-3.0、
  作者 Ruri/itokatsu/kuri 署名）。

### 2.3 现有代码现状（两套并行 + 一段休眠死码）

- **活跃制卡系统**：`packages/hibiki_anki/`（独立 package）+
  `hibiki/lib/src/anki/anki_view_model.dart`。当前**不创建 model/deck**，
  完全依赖用户已有配置，只做字段映射。
- **休眠死码**：`hibiki/lib/src/models/anki_integration.dart` 的
  `addDefaultModelIfMissing` + 原生 `AnkiChannelHandler.addDefaultModel`
  已能创建名为 `Lapis` 的 note type，但用的是**错误的 `Term/Meaning` 字段名**，
  且无任何 UI 调用点（grep 仅命中定义自身 + 一个静态测试）。
- **字段名冲突**：`lapis_preset.dart` 用 `Expression/MainDefinition/Sentence...`
  （与正版部分一致）；休眠原生用 `Term/Meaning...`（错误）。本功能统一到正版 22 字段。

## 3. 架构

```
                    LapisNoteTypeSpec (单一权威, Dart const)
                    22 fields + vendored front/back/css + 默认映射
                                  │
              ┌───────────────────┼───────────────────┐
              ▼                                         ▼
   AnkiService.createNoteType / createDeck     LapisPreset (字段映射对齐)
              │ (抽象接口, 幂等)
       ┌──────┴───────┐
       ▼              ▼
  AnkiRepository   AnkiConnectRepository
  (AnkiDroid)      (桌面/iOS)
   channel:         HTTP action:
   addDefaultModel  createModel
   (改 schema 驱动) createDeck
   createDeck
       │              │
       ▼              ▼
  AnkiChannelHandler.java   AnkiConnect server
  (api.addNewCustomModel /
   api.addNewDeck)

      AnkiViewModel.createLapisSetup()  ── 编排：建模→建deck→选中→应用预设→持久化
                    │
                    ▼
      AnkiSettingsPage 按钮「一键创建 Lapis 卡组」
```

## 4. 组件设计

### 4.1 `packages/hibiki_anki/lib/src/lapis_note_type.dart`（新增，单一真相）

```dart
/// 权威 Lapis 笔记类型定义。front/back/css vendored from donkuri/lapis v1.7.0
/// (GPL-3.0, https://github.com/donkuri/lapis). 安卓与桌面共用此源。
class LapisNoteTypeSpec {
  static const String modelName = 'Lapis';
  static const String defaultDeckName = 'Lapis';
  static const String cardTemplateName = 'Card 1';
  static const List<String> fields = <String>[ /* 22 字段按序 */ ];
  static const String front = r'''...''';   // vendored v1.7.0
  static const String back = r'''...''';
  static const String css = r'''...''';
  /// 22 字段 → Hibiki 占位符默认映射（feeds LapisPreset）。
  /// 含 Hibiki 特色：Picture→{book-cover}, SentenceAudio→{sasayaki-audio},
  /// MiscInfo→{document-title}。
  static const Map<String, String> defaultFieldMappings = <String, String>{ ... };
}
```

通用模板载体（避免接口耦合 Lapis）：

```dart
class AnkiNoteTypeTemplate {
  final String name;
  final List<String> fields;
  final String cardName;
  final String front;
  final String back;
  final String css;
}
```

### 4.2 `AnkiService` 接口扩展（`anki_service.dart`）

```dart
Future<void> createNoteType(AnkiNoteTypeTemplate template);
Future<void> createDeck(String name);
```

- 两者**幂等**：实现前先查 `getModelNames()` / `getDeckNames()`，存在即 no-op。

### 4.3 AnkiConnect 实现

- `ankiconnect_service.dart` 新增：
  - `createModel`：action `createModel`，params
    `{modelName, inOrderFields, css, isCloze:false, cardTemplates:[{Name, Front, Back}]}`。
  - `createDeck`：action `createDeck`，params `{deck: name}`。
- `ankiconnect_repository.dart`：实现 `createNoteType`/`createDeck`，幂等检查。

### 4.4 AnkiDroid 原生实现

- `AnkiChannelHandler.java`：把休眠 `addDefaultModel` **改为 schema 驱动**——
  modelName / fields[] / cardName / qfmt / afmt / css 全部从 Dart 经 channel 参数传入，
  删除硬编码 `Term/Meaning`。新增 `createDeck` case（`api.addNewDeck(name)`）。
- `anki_repository.dart`：`createNoteType` 用 spec 参数 invoke channel；`createDeck` 同理；
  幂等检查复用现有 `getModelList`/`getDecks`。

### 4.5 编排 `AnkiViewModel.createLapisSetup()`（`anki_view_model.dart`）

```dart
enum LapisSetupOutcome { created, alreadyExisted, failed }
Future<LapisSetupResult> createLapisSetup();
```

流程：
1. `repo.createNoteType(LapisNoteTypeSpec → AnkiNoteTypeTemplate)`（幂等）。
2. `repo.createDeck(LapisNoteTypeSpec.defaultDeckName)`（幂等）。
3. `repo.fetchConfiguration()` 重新拉取 decks/models/fields。
4. `selectNoteType('Lapis')` + `selectDeck('Lapis')`。
5. `LapisPreset.applyDefaults` 写字段映射（默认含 book-cover / sasayaki-audio）。
6. 持久化 settings。
7. 返回 `created`（本次新建）/ `alreadyExisted`（已存在仍选中应用）/ `failed(reason)`。

### 4.6 UI（`anki_settings_page.dart`）

- note type 下拉框上方新增按钮「一键创建 Lapis 卡组」。
- 状态：loading spinner / 成功 toast / 已存在提示 / 失败提示
  （AnkiConnect 不可达、AnkiDroid 未安装）。
- 走项目焦点注册组件规范（HibikiOverflowMenu 同生态的焦点可达按钮，禁裸 tap）。

### 4.7 收尾

- `lapis_preset.dart`：`_defaults` 替换为 `LapisNoteTypeSpec.defaultFieldMappings`，
  `matches()` 确认能识别正版 22 字段。
- 删除 `anki_integration.dart` 里死掉的 `addDefaultModelIfMissing` + `Term/Meaning`
  schema + `AnkiDefaultModelDialog`；`app_model.dart` 对应入口一并清理。
- i18n（经 `hibiki/tool/i18n_sync.dart`，17 语言，slang 重生）新增：
  - `anki_create_lapis`（按钮）
  - `anki_create_lapis_success`
  - `anki_create_lapis_exists`
  - `anki_create_lapis_failed`
  - `anki_create_lapis_hint`（可选说明）

## 5. 数据流

制卡时（不变）：占位符 → `AnkiHandlebarRenderer.render` → 按 `fieldMappings` 填字段
→ `addNote`。本功能只补「字段映射的来源」：一键创建后 `fieldMappings` 由
`LapisNoteTypeSpec.defaultFieldMappings` 预填，用户可继续在字段映射 UI 调整。

## 6. 错误处理

- AnkiConnect 不可达 / AnkiDroid 未装 / 权限缺失 → `failed(reason)` + 明确 toast，
  不吞异常、不静默。
- model/deck 已存在 → 视为成功路径 `alreadyExisted`（仍执行选中 + 应用映射），不报错。
- 创建部分成功（model 成功 deck 失败或反之）→ 返回 failed 并说明哪一步失败，
  不留半截状态（已成功创建的不回滚，但提示用户）。

## 7. 测试策略（TDD：红 → 绿）

| 层 | 测试 |
|---|---|
| schema 守卫 | `LapisNoteTypeSpec.fields` == 正版 22 字段（名 + 顺序）；modelName=`Lapis`；front/back/css 非空；`defaultFieldMappings` 的 key ⊆ fields |
| AnkiConnect 请求形状 | mock http client，断言 createModel/createDeck 的 action + params JSON 结构正确（inOrderFields 顺序、cardTemplates、isCloze:false、deck 名） |
| ViewModel 流程 | fake AnkiService：createLapisSetup 建模 + 建 deck + 选中 + 应用预设 + 持久化；二次运行返回 alreadyExisted；任一步失败传播为 failed |
| LapisPreset | 22 字段 applyDefaults 结果符合默认映射；matches() 对 Lapis 为真 |
| 原生路径 | host 跑不到 AnkiDroid → 源码守卫：扫 `AnkiChannelHandler.java` + `anki_repository.dart` 含 createNoteType/createDeck 且 schema 驱动、无硬编码 `Term/Meaning` + 平台闸门 |

- **设备验证**（真 AnkiDroid 建模 + 真桌面 AnkiConnect 建模 + 真制卡命中字段）
  → 因涉及外部系统副作用，留给用户复测并留证据。

## 8. 验证命令

- `dart format .`（在 `hibiki/` 及 `packages/hibiki_anki/`）
- `flutter test`（项目 Flutter 3.44.0 工具链）
- `flutter analyze`
- 安卓资源/manifest 未改，无需 assembleRelease（仅 Java handler 逻辑改动，
  随常规构建覆盖）。

## 9. 非目标（YAGNI）

- 不做 Lapis 模板版本升级/检测（vendor 固定 v1.7.0 快照；上游更新由后续手动 bump）。
- 不做 deck 名自定义 UI（默认 `Lapis`，后续需要再加）。
- 不做 Yomitan card format 自动写入（Hibiki 自身制卡管线已直接填字段，
  无需配置外部 Yomitan）。
- 不动制卡运行时渲染逻辑（`AnkiHandlebarRenderer` 不变）。
