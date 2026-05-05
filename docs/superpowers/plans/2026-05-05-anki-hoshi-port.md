# Anki Hoshi 模型移植 Implementation Plan (v3 — 完全替换)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用 Hoshi 的 AnkiSettings/mineEntry 模型完全替换 Hibiki 旧的 AnkiMapping/CreatorModel 导出系统。一套代码、一个设置源、一条导出路径。

**Architecture:** 新建 `lib/src/anki/` 作为唯一 Anki 模块。AnkiRepository 是唯一状态源。Popup mine 直接调 mineEntry。Creator 页面删除（或降级为未来可选功能——本次不保留）。旧代码全删。

**Tech Stack:** Flutter/Dart, Riverpod, SharedPreferences, 复用已有 MethodChannel

---

## 删除清单

以下文件/代码在本次移植中删除：

**文件删除：**
- `lib/src/creator/anki_mapping.dart`
- `lib/src/creator/anki_handlebar.dart`
- `lib/src/creator/anki_utilities.dart`
- `lib/src/creator/actions/instant_export_action.dart`
- `lib/src/creator/actions/card_creator_action.dart`
- `lib/src/pages/implementations/creator_page.dart`（整个 Creator UI）

**AppModel 中删除的方法/属性：**
- `addNote()`
- `addFileToMedia()`
- `openCreator()`
- `shouldOpenCreatorRoute()`
- `silentExport` / `toggleSilentExport()`
- `lastSelectedDeckName` / `setLastSelectedDeck()`
- `lastSelectedMapping` / `setLastSelectedMapping()`
- `duplicateCheckModels`
- `checkForDuplicates()`
- `_readingFieldIndex()`
- `isCreatorOpen` / `killOnPop`
- `getDecks()` / `getModelList()` / `getFieldList()`

**数据库表（保留但停用）：**
- `AnkiMappings` 表 — 不迁移，不删表（避免 Drift schema 问题），只是不再读写

**设置页：**
- 旧 `anki_settings_page.dart` 完全重写

---

## 新建文件

- `lib/src/anki/anki_models.dart`
- `lib/src/anki/anki_repository.dart`
- `lib/src/anki/anki_view_model.dart`
- `lib/src/anki/lapis_preset.dart`

---

## MethodChannel 接口（不改 native，只列出已有接口供参考）

| 方法 | 参数 | 返回 |
|------|------|------|
| `getDecks` | 无 | `Map<int, String>` (deckId → name) |
| `getModelList` | 无 | `Map<int, String>` (modelId → name) |
| `getFieldList` | `{'model': String}` (model **name**) | `List<String>` |
| `addNote` | `{'model': String, 'deck': String, 'fields': List<String>, 'tags': List<String>}` | `String` |
| `checkForDuplicates` | `{'models': List<String>, 'key': String, 'reading': String, 'readingFieldIndices': List<int>}` | `bool` |
| `addFileToMedia` | `{'filename': String, 'preferredName': String, 'mimeType': String}` | `String` (Anki media filename) |
| `requestAnkidroidPermissions` | 无 | `bool` |

---

### Task 1: 创建 `lib/src/anki/anki_models.dart`

**Files:**
- Create: `lib/src/anki/anki_models.dart`

- [ ] **Step 1: 编写全部数据模型**

包含：
- `AnkiDeck` (id: int, name: String, fromJson/toJson)
- `AnkiNoteType` (id: int, name: String, fields: List\<String\>, fromJson/toJson)
- `AnkiSettings` (所有字段 + copyWith + fromJson/toJson + computed `selectedNoteType`/`isConfigured`)
- `AnkiMiningPayload` (fromJson，处理 singleGlossaries 可能是嵌套 JSON string 或 Map)
- `DictionaryMedia` (dictionary, path, filename)
- `AnkiMiningContext` (sentence, documentTitle, coverPath, sasayakiAudioPath, sentenceOffset)
- `AnkiHandlebarRenderer` (static render，17 个 handlebar switch + `{single-glossary-*}` 前缀匹配 + `_sentenceValue` 高亮)
- `AnkiHandlebarOptions` (coreOptions 常量 + forTermDictionaries)
- 工具函数：`mimeTypeForPath`, `ankiInlineMediaReference`, `normalizeAnkiDictionaryHtml`

注意：需要 `import 'package:collection/collection.dart'` 提供 `firstOrNull`。

- [ ] **Step 2: 运行 analyze**

Run: `flutter analyze lib/src/anki/anki_models.dart`

---

### Task 2: 创建 `lib/src/anki/lapis_preset.dart`

**Files:**
- Create: `lib/src/anki/lapis_preset.dart`

- [ ] **Step 1: 编写 LapisPreset**

```dart
import 'anki_models.dart';

class LapisPreset {
  static const _defaults = {
    'Expression': '{expression}',
    'ExpressionFurigana': '{furigana-plain}',
    'ExpressionReading': '{reading}',
    'ExpressionAudio': '{audio}',
    'SelectionText': '{popup-selection-text}',
    'MainDefinition': '{glossary-first}',
    'Sentence': '{sentence}',
    'SentenceAudio': '{sasayaki-audio}',
    'Picture': '{book-cover}',
    'Glossary': '{glossary}',
    'PitchPosition': '{pitch-accent-positions}',
    'PitchCategories': '{pitch-accent-categories}',
    'Frequency': '{frequencies}',
    'FreqSort': '{frequency-harmonic-rank}',
    'MiscInfo': '{document-title}',
    'IsWordAndSentenceCard': 'x',
  };

  static bool matches(AnkiNoteType noteType) {
    final fields = noteType.fields.toSet();
    return noteType.name.toLowerCase().contains('lapis') ||
        ['Expression', 'MainDefinition', 'Sentence'].every(fields.contains);
  }

  static Map<String, String> defaultMappings(AnkiNoteType noteType) =>
      {for (final f in noteType.fields) if (_defaults.containsKey(f)) f: _defaults[f]!};

  static Map<String, String> applyDefaults(
    AnkiNoteType noteType,
    Map<String, String> currentMappings,
  ) {
    if (!matches(noteType)) return currentMappings;
    return {...defaultMappings(noteType), ...currentMappings};
  }
}
```

- [ ] **Step 2: 运行 analyze**

---

### Task 3: 创建 `lib/src/anki/anki_repository.dart`

**Files:**
- Create: `lib/src/anki/anki_repository.dart`

- [ ] **Step 1: 编写 AnkiRepository**

```dart
import 'dart:convert';
import 'dart:io';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'anki_models.dart';
import 'lapis_preset.dart';
```

**方法列表：**

```
class AnkiRepository {
  static const _channel = MethodChannel('app.hibiki.reader/anki');
  static const _settingsKey = 'hoshi_anki_settings';
  static const _legacyDeckKey = 'last_selected_deck';

  // ─── Settings ───
  Future<AnkiSettings> loadSettings()
  Future<AnkiSettings> saveSettings(AnkiSettings)
  Future<AnkiSettings> updateSettings(AnkiSettings Function(AnkiSettings))

  // ─── Fetch ───
  Future<AnkiFetchResult> fetchConfiguration()
    // getDecks → Map<int,String> → List<AnkiDeck>
    // getModelList → Map<int,String>
    // 对每个 model: getFieldList({'model': modelName}) → List<String>
    // → List<AnkiNoteType>
    // selectDeckAfterFetch / selectNoteTypeAfterFetch / fieldMappingsAfterFetch

  // ─── Export ───
  Future<bool> mineEntry({required String rawPayloadJson, required AnkiMiningContext context})
    // 1. loadSettings → deck/noteType/fieldMappings
    // 2. parse payload
    // 3. 媒体：cover → addFileToMedia, sasayaki → addFileToMedia, audio → download+addFileToMedia
    // 4. render fields: AnkiHandlebarRenderer.render() per mapping entry
    // 5. normalizeAnkiDictionaryHtml
    // 6. duplicate check (if !allowDupes):
    //    checkForDuplicates({'models': [noteType.name], 'key': expression,
    //                        'reading': reading, 'readingFieldIndices': [readingIdx]})
    // 7. addNote({'model': noteType.name, 'deck': deck.name,
    //           'fields': orderedFieldArray, 'tags': tagsList})

  // ─── Duplicate Check (for popup JS) ───
  Future<bool> isDuplicate(String expression, String reading)
    // loadSettings → noteType name
    // _findReadingFieldIndex
    // checkForDuplicates with single model

  // ─── Media ───
  Future<String?> _addMediaFile(String filePath, String preferredName, String mimeType)
    // invokeMethod('addFileToMedia', {filename, preferredName, mimeType})
  Future<String?> _addRemoteAudio(String url)
    // download or read local → temp file → _addMediaFile

  // ─── Helpers ───
  int _findReadingFieldIndex(AnkiNoteType noteType, Map<String,String> fieldMappings)
    // 找 fieldMappings 中值为 '{reading}' 的 key，返回其在 noteType.fields 中的 index
  AnkiDeck _selectDeckAfterFetch(List<AnkiDeck>, AnkiSettings)
  AnkiNoteType _selectNoteTypeAfterFetch(List<AnkiNoteType>, AnkiSettings)
  Map<String,String> _fieldMappingsAfterFetch(AnkiNoteType, AnkiSettings)
  Future<void> _migrateFromLegacy()
    // 读 SharedPreferences key 'last_selected_deck'，写入新 settings.selectedDeckName
}

sealed class AnkiFetchResult {
  const factory AnkiFetchResult.success({required List<AnkiDeck>, required List<AnkiNoteType>}) = AnkiFetchSuccess;
  const factory AnkiFetchResult.error(String message) = AnkiFetchError;
}
```

- [ ] **Step 2: 运行 analyze**

---

### Task 4: 创建 `lib/src/anki/anki_view_model.dart`

**Files:**
- Create: `lib/src/anki/anki_view_model.dart`

- [ ] **Step 1: 编写 StateNotifier + Providers**

```dart
class AnkiUiState {
  final AnkiSettings settings;
  final bool isFetching;
  final String? errorMessage;
  // computed: availableDecks, availableNoteTypes, selectedNoteType, isConfigured
}

class AnkiViewModel extends StateNotifier<AnkiUiState> {
  AnkiViewModel(AnkiRepository repo)
  Future<void> fetchConfiguration()
  Future<void> selectDeck(AnkiDeck)
  Future<void> selectNoteType(AnkiNoteType)  // + LapisPreset.applyDefaults
  Future<void> updateFieldMapping(String field, String value)
  Future<void> updateTags(String)
  Future<void> updateAllowDupes(bool)
  Future<void> updateCompactGlossaries(bool)
}

final ankiRepositoryProvider = Provider((_) => AnkiRepository());
final ankiViewModelProvider = StateNotifierProvider<AnkiViewModel, AnkiUiState>(...);
```

- [ ] **Step 2: 运行 analyze**

---

### Task 5: 重写 `anki_settings_page.dart`

**Files:**
- Rewrite: `lib/src/pages/implementations/anki_settings_page.dart`

- [ ] **Step 1: Hoshi 风格设置页（ConsumerStatefulWidget）**

UI：
1. Fetch 按钮（"AnkiDroid" + "Fetch" / "Fetching"）
2. Deck 下拉
3. Model 下拉
4. Allow Duplicates 开关
5. Compact Glossaries 开关
6. Fields 映射列表（每行：字段名 + 当前值 + `{}` handlebar 快捷按钮 + 点击编辑 dialog）
7. Tags 输入

用 `ref.watch(ankiViewModelProvider)` 驱动。

- [ ] **Step 2: 运行 analyze**

---

### Task 6: 修改 Popup mine + duplicateCheck 路径

**Files:**
- Modify: `lib/src/pages/base_source_page.dart`
- Modify: `lib/src/pages/implementations/reader_ttu_source_page.dart`
- Modify: `lib/src/pages/implementations/dictionary_popup_webview.dart`

- [ ] **Step 1: DictionaryPopupWebView**

- `onMineEntry` 类型改为 `Future<bool> Function(Map<String, String>)?`
- 新增 `onDuplicateCheck: Future<bool> Function(String)?`
- `mineEntry` handler: `return await widget.onMineEntry!(fields);`
- `duplicateCheck` handler: `return await widget.onDuplicateCheck!(expression);`

- [ ] **Step 2: base_source_page.dart**

```dart
Future<bool> onMineFromPopup(Map<String, String> fields) async => false;
```

构建 DictionaryPopupWebView 时传入回调：
```dart
onMineEntry: onMineFromPopup,
onDuplicateCheck: (expression) async {
  final repo = ref.read(ankiRepositoryProvider);
  return repo.isDuplicate(expression, '');
},
```

- [ ] **Step 3: reader_ttu_source_page.dart**

```dart
@override
Future<bool> onMineFromPopup(Map<String, String> fields) async {
  final currentSentence = appModel.getCurrentSentence();
  final repo = ref.read(ankiRepositoryProvider);
  final settings = await repo.loadSettings();

  final context = AnkiMiningContext(
    sentence: currentSentence.text.trim(),
    documentTitle: appModel.currentMediaSource?.title,
    coverPath: null,
    sasayakiAudioPath: null,
    sentenceOffset: null,
  );

  final success = await repo.mineEntry(
    rawPayloadJson: jsonEncode(fields),
    context: context,
  );

  if (success) {
    Fluttertoast.showToast(
      msg: t.card_exported(deck: settings.selectedDeckName ?? ''),
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.BOTTOM,
    );
  }
  return success;
}
```

- [ ] **Step 4: 运行 analyze**

---

### Task 7: 删除旧代码

**Files:**
- Delete: `lib/src/creator/anki_mapping.dart`
- Delete: `lib/src/creator/anki_handlebar.dart`
- Delete: `lib/src/creator/anki_utilities.dart`
- Delete: `lib/src/creator/actions/instant_export_action.dart`
- Delete: `lib/src/creator/actions/card_creator_action.dart`
- Delete: `lib/src/pages/implementations/creator_page.dart`
- Modify: `lib/src/models/app_model.dart` — 删除所有 Anki 相关方法
- Modify: 所有 import 上述文件的地方 — 移除引用

- [ ] **Step 1: 删除文件**

- [ ] **Step 2: 从 AppModel 中移除 Anki 方法**

删除：
- `addNote()` (line ~2571-2675)
- `addFileToMedia()` (line ~2682-2740)
- `openCreator()` (line ~2826-2870)
- `shouldOpenCreatorRoute()` (line ~2815-2819)
- `silentExport` / `toggleSilentExport()` (line ~3789-3795)
- `lastSelectedDeckName` / `setLastSelectedDeck()` (line ~1641-1749)
- `lastSelectedMapping` / `setLastSelectedMapping()`
- `duplicateCheckModels`
- `checkForDuplicates()` / `_readingFieldIndex()`
- `isCreatorOpen` / `killOnPop`
- `getDecks()` / `getModelList()` / `getFieldList()`
- `methodChannel`（如果仅供 Anki 使用；如果 TTS 或其他功能也用则保留）

- [ ] **Step 3: 修复所有断裂的 import 和引用**

全项目搜索删除文件的 import，逐个修复或移除。涉及：
- `creator.dart` barrel export
- `quick_action.dart` 中对 CardCreatorAction/InstantExportAction 的引用
- 导航路由中对 CreatorPage 的引用
- `reader_ttu_source_page.dart` 中旧 `onMineFromPopup` 的 CreatorFieldValues 引用

- [ ] **Step 4: 运行 analyze（预计有大量报错，逐个修复）**

Run: `flutter analyze`

---

### Task 8: 编译验证 + Commit

- [ ] **Step 1: flutter analyze 全量通过**

- [ ] **Step 2: 编译 release APK**

Run: `flutter build apk --release --split-per-abi --target-platform android-arm64`

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat(anki): replace old AnkiMapping/Creator system with Hoshi mineEntry model

BREAKING: Creator page removed. Popup mine button exports directly.
- New lib/src/anki/ (AnkiRepository, AnkiSettings, LapisPreset, AnkiHandlebarRenderer)
- Single settings source (SharedPreferences JSON)
- Hoshi-style settings page (deck/model dropdown + field mappings)
- Duplicate check: current note type + reading field
- Deleted: AnkiMapping profiles, anki_handlebar.dart, CreatorPage, InstantExportAction, CardCreatorAction
- Deleted: AppModel Anki methods (addNote, openCreator, addFileToMedia, etc.)"
```

---

## MethodChannel 参数速查

| 方法 | 参数类型 | 注意 |
|------|----------|------|
| `getFieldList` | `{'model': String}` | **传 model name**，native 用 `findModelIdByName(model, 1)` 按名查 ID |
| `checkForDuplicates` | `{'models': List<String>, 'key': String, 'reading': String, 'readingFieldIndices': List<int>}` | models 是名称列表，新路径只传 `[当前noteType.name]` |
| `addFileToMedia` | `{'filename': String, 'preferredName': String, 'mimeType': String}` | filename 是本地绝对路径，FileProvider authority = `BuildConfig.APPLICATION_ID + ".provider"` |
| `addNote` | `{'model': String, 'deck': String, 'fields': List<String>, 'tags': List<String>}` | fields 按 noteType.fields 顺序排列 |
