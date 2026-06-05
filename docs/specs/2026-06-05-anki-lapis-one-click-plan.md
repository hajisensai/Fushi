# 一键创建 Lapis 笔记类型 + 卡组 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 Anki 设置页加「一键创建 Lapis 卡组」按钮，自动在用户 Anki 里创建正版 Lapis 笔记类型（22 字段 + v1.7.0 模板）和同名默认卡组，并自动选中、预填字段映射，全平台（安卓 AnkiDroid + 桌面/iOS AnkiConnect）。

**Architecture:** 单一权威数据源 `LapisNoteType`（Dart const，vendored donkuri/lapis v1.7.0）→ `BaseAnkiRepository.createNoteType/createDeck` 抽象原语（两后端各实现，幂等）→ `AnkiViewModel.createLapisSetup()` 编排（建模→建deck→fetch→选中→应用预设）→ 设置页按钮。

**Tech Stack:** Dart/Flutter（hibiki_anki package + hibiki app）、AnkiConnect HTTP v6、AnkiDroid AddContentApi（Java）、Slang i18n、package:http/testing（MockClient）。

**关联设计：** `docs/specs/2026-06-05-anki-lapis-one-click-design.md`

---

## 关键事实（实现前必读）

- **Lapis 权威源**：donkuri/lapis，最新 tag 是 **`1.7.0`（无 `v` 前缀）**。三文件在 `src/`：
  - `https://raw.githubusercontent.com/donkuri/lapis/1.7.0/src/front.html`（2585B）
  - `https://raw.githubusercontent.com/donkuri/lapis/1.7.0/src/back.html`（24860B）
  - `https://raw.githubusercontent.com/donkuri/lapis/1.7.0/src/styling.css`（26070B）
  - 已验证经本机代理 `http://127.0.0.1:34151` 返回 HTTP 200。
- **License**：donkuri/lapis 与 Hibiki 均 GPL-3.0，vendor 合法；保留 provenance 注释即可。
- **22 字段顺序**（精确大小写）：`Expression, ExpressionFurigana, ExpressionReading, ExpressionAudio, SelectionText, MainDefinition, DefinitionPicture, Sentence, SentenceFurigana, SentenceAudio, Picture, Glossary, Hint, IsWordAndSentenceCard, IsClickCard, IsSentenceCard, IsAudioCard, PitchPosition, PitchCategories, Frequency, FreqSort, MiscInfo`。
- **只 1 个 card template**，名 `Card 1`。
- **现有类型签名**（已核对）：
  - `AnkiSettings.copyWith({selectedDeckId, selectedDeckName, selectedNoteTypeId, selectedNoteTypeName, availableDecks, availableNoteTypes, fieldMappings, tags, ...})`（`anki_models.dart:101`）。
  - `AnkiNoteType{int id, String name, List<String> fields}`、`AnkiDeck{int id, String name}`。
  - `AnkiFetchResult` sealed → `AnkiFetchSuccess` / `AnkiFetchError(message)`。
  - `BaseAnkiRepository`（`base_anki_repository.dart`）抽象方法：`fetchConfiguration()`/`mineEntry()`/`isDuplicate()`；具体：`loadSettings/saveSettings/updateSettings`。
  - `AnkiViewModel`（`hibiki/lib/src/anki/anki_view_model.dart`）持 `BaseAnkiRepository _repository`；`ankiRepositoryProvider` 按平台返回 `AnkiRepository`(安卓) / `AnkiConnectRepository`(其余)。
  - `AnkiConnectService._request(action, params)`（`ankiconnect_service.dart:24`）当前用顶层 `http.post`（**不可注入**，Task 3 改为可注入 client）。
  - `AnkiChannelHandler.java`：channel `app.hibiki.reader/anki`；`api.addNewCustomModel(name, fields[], cards[], qfmt[], afmt[], css, did, sortf)`、`api.addNewDeck(name)`、`ankiDroid.findModelIdByName(name, n)`、`ankiDroid.findDeckIdByName(name)`。
- **Dart 测试位置**：沿用 `hibiki/test/anki/`（hibiki 依赖 hibiki_anki，可测其内部）。
- **i18n**：源文件 `hibiki/lib/i18n/strings*.i18n.json`（17 文件），改 key 必须用 `hibiki/tool/i18n_sync.dart`，再 `dart run slang` + `dart format` 生成文件。

---

## File Structure

| 文件 | 操作 | 职责 |
|---|---|---|
| `packages/hibiki_anki/lib/src/lapis_note_type.dart` | 创建 | 权威 Lapis schema：22 字段 + vendored front/back/css + 默认字段映射 + `AnkiNoteTypeTemplate` |
| `packages/hibiki_anki/lib/src/anki_models.dart` | 修改 | 新增 `AnkiNoteTypeTemplate` 数据类（放此或 lapis_note_type.dart，二选一——本计划放 lapis_note_type.dart） |
| `packages/hibiki_anki/lib/src/base_anki_repository.dart` | 修改 | 新增抽象 `createNoteType`/`createDeck` |
| `packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_service.dart` | 修改 | 可注入 http.Client + `createModel`/`createDeck` |
| `packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_repository.dart` | 修改 | 实现 `createNoteType`/`createDeck`（幂等） |
| `packages/hibiki_anki/lib/src/ankidroid/anki_repository.dart` | 修改 | 实现 `createNoteType`/`createDeck`（channel） |
| `packages/hibiki_anki/lib/hibiki_anki.dart` | 修改 | 导出 `lapis_note_type.dart` |
| `hibiki/android/app/src/main/java/app/hibiki/reader/AnkiChannelHandler.java` | 修改 | 删 `addDefaultModel`，加 schema 驱动 `createNoteType`/`createDeck` |
| `hibiki/lib/src/anki/anki_view_model.dart` | 修改 | `createLapisSetup()` + `LapisSetupResult` |
| `packages/hibiki_anki/lib/src/lapis_preset.dart` | 修改 | `_defaults` 对齐 22 字段（引用 `LapisNoteType.defaultFieldMappings`） |
| `hibiki/lib/src/pages/implementations/anki_settings_page.dart` | 修改 | 「一键创建 Lapis 卡组」按钮 |
| `hibiki/lib/src/models/anki_integration.dart` | 修改 | 删死代码 `addDefaultModelIfMissing` + `AnkiDefaultModelDialog` |
| `hibiki/lib/src/models/app_model.dart` | 修改 | 删 `addDefaultModelIfMissing()` 包装（:1899-1900） |
| `hibiki/lib/i18n/*.i18n.json` | 修改 | 加 `anki_create_lapis*`，删 orphan `info_standard_model*` |
| `hibiki/test/anki/lapis_note_type_test.dart` | 创建 | schema 守卫 |
| `hibiki/test/anki/ankiconnect_create_test.dart` | 创建 | createModel/createDeck 请求形状 |
| `hibiki/test/anki/anki_view_model_lapis_test.dart` | 创建 | createLapisSetup 流程 |
| `hibiki/test/anki/lapis_preset_test.dart` | 创建 | 字段映射 |
| `hibiki/test/anki/anki_native_createmodel_guard_test.dart` | 创建 | 原生路径源码守卫 |

---

## Task 1: 权威 Lapis schema（LapisNoteType + vendored 模板）

**Files:**
- Create: `packages/hibiki_anki/lib/src/lapis_note_type.dart`
- Modify: `packages/hibiki_anki/lib/hibiki_anki.dart`
- Test: `hibiki/test/anki/lapis_note_type_test.dart`

- [ ] **Step 1: 抓取 vendored 三文件内容**

经本机代理抓取（已验证 200）。在仓库根运行：

```bash
mkdir -p "$CLAUDE_JOB_DIR/tmp/lapis"
for f in front.html back.html styling.css; do
  curl -s --proxy http://127.0.0.1:34151 --ssl-no-revoke \
    "https://raw.githubusercontent.com/donkuri/lapis/1.7.0/src/$f" \
    -o "$CLAUDE_JOB_DIR/tmp/lapis/$f"
done
wc -c "$CLAUDE_JOB_DIR/tmp/lapis/"*
```
Expected: front.html≈2585、back.html≈24860、styling.css≈26070 字节。

- [ ] **Step 2: 写 schema 守卫测试（先失败）**

`hibiki/test/anki/lapis_note_type_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

void main() {
  group('LapisNoteType authoritative schema', () {
    test('has the 22 official fields in order', () {
      expect(LapisNoteType.fields, <String>[
        'Expression', 'ExpressionFurigana', 'ExpressionReading',
        'ExpressionAudio', 'SelectionText', 'MainDefinition',
        'DefinitionPicture', 'Sentence', 'SentenceFurigana', 'SentenceAudio',
        'Picture', 'Glossary', 'Hint', 'IsWordAndSentenceCard', 'IsClickCard',
        'IsSentenceCard', 'IsAudioCard', 'PitchPosition', 'PitchCategories',
        'Frequency', 'FreqSort', 'MiscInfo',
      ]);
    });

    test('model and deck names', () {
      expect(LapisNoteType.modelName, 'Lapis');
      expect(LapisNoteType.deckName, 'Lapis');
      expect(LapisNoteType.cardName, 'Card 1');
    });

    test('templates are non-trivial vendored content', () {
      expect(LapisNoteType.front.length, greaterThan(500));
      expect(LapisNoteType.back.length, greaterThan(5000));
      expect(LapisNoteType.css.length, greaterThan(5000));
      // 正版标志：front 用顶层容器 #lapis；back 引用 Expression 词头
      expect(LapisNoteType.front, contains('id="lapis"'));
      expect(LapisNoteType.back, contains('Expression'));
    });

    test('template carries all schema fields', () {
      expect(LapisNoteType.template.name, 'Lapis');
      expect(LapisNoteType.template.fields, LapisNoteType.fields);
      expect(LapisNoteType.template.cardName, 'Card 1');
      expect(LapisNoteType.template.front, LapisNoteType.front);
      expect(LapisNoteType.template.back, LapisNoteType.back);
      expect(LapisNoteType.template.css, LapisNoteType.css);
    });

    test('default field mappings only reference real fields', () {
      for (final field in LapisNoteType.defaultFieldMappings.keys) {
        expect(LapisNoteType.fields, contains(field));
      }
      // Hibiki 特色默认
      expect(LapisNoteType.defaultFieldMappings['Picture'], '{book-cover}');
      expect(LapisNoteType.defaultFieldMappings['SentenceAudio'],
          '{sasayaki-audio}');
      expect(LapisNoteType.defaultFieldMappings['IsWordAndSentenceCard'], 'x');
    });
  });
}
```

- [ ] **Step 3: 运行测试确认失败**

Run: `cd hibiki && flutter test test/anki/lapis_note_type_test.dart`
Expected: FAIL（`LapisNoteType` undefined / `AnkiNoteTypeTemplate` undefined）。

- [ ] **Step 4: 创建 `lapis_note_type.dart`**

把 Step 1 抓取的三文件内容作为 Dart raw string 字面量嵌入（用 `r'''...'''`；若文件内含 `'''` 则改用 `r"""..."""` 或转义）。顶部加 provenance 注释。骨架如下（`<<<FRONT_HTML>>>` 等替换为真实文件内容）：

```dart
/// Authoritative Lapis note type definition.
///
/// `front` / `back` / `css` are vendored verbatim from donkuri/lapis v1.7.0
/// (tag `1.7.0`, src/front.html · src/back.html · src/styling.css).
/// Upstream: https://github.com/donkuri/lapis  — License: GPL-3.0
/// Authors: Ruri, itokatsu, kuri (donkuri). Hibiki is itself GPL-3.0.
/// Do not hand-edit; re-vendor from the pinned tag when bumping versions.
library;

/// A backend-agnostic note-type creation template (name + fields + one card).
class AnkiNoteTypeTemplate {
  const AnkiNoteTypeTemplate({
    required this.name,
    required this.fields,
    required this.cardName,
    required this.front,
    required this.back,
    required this.css,
  });

  final String name;
  final List<String> fields;
  final String cardName;
  final String front;
  final String back;
  final String css;
}

class LapisNoteType {
  static const String modelName = 'Lapis';
  static const String deckName = 'Lapis';
  static const String cardName = 'Card 1';

  static const List<String> fields = <String>[
    'Expression', 'ExpressionFurigana', 'ExpressionReading', 'ExpressionAudio',
    'SelectionText', 'MainDefinition', 'DefinitionPicture', 'Sentence',
    'SentenceFurigana', 'SentenceAudio', 'Picture', 'Glossary', 'Hint',
    'IsWordAndSentenceCard', 'IsClickCard', 'IsSentenceCard', 'IsAudioCard',
    'PitchPosition', 'PitchCategories', 'Frequency', 'FreqSort', 'MiscInfo',
  ];

  /// 字段 → Hibiki 占位符默认映射。未列出的字段（DefinitionPicture /
  /// SentenceFurigana / Hint / IsClickCard / IsSentenceCard / IsAudioCard）
  /// 故意留空：Lapis 官方建议 SentenceFurigana 留空，卡型选择器一次只填一个。
  static const Map<String, String> defaultFieldMappings = <String, String>{
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

  static const String front = r'''<<<FRONT_HTML>>>''';
  static const String back = r'''<<<BACK_HTML>>>''';
  static const String css = r'''<<<STYLING_CSS>>>''';

  static const AnkiNoteTypeTemplate template = AnkiNoteTypeTemplate(
    name: modelName,
    fields: fields,
    cardName: cardName,
    front: front,
    back: back,
    css: css,
  );
}
```

注意：嵌入前确认三文件内容不含 `'''`（若含，整体改用 `r"""..."""`）。可用
`grep -c "'''" "$CLAUDE_JOB_DIR/tmp/lapis/"*` 检查；styling.css 含 CSS 不会有三连单引号。

- [ ] **Step 5: 导出 `lapis_note_type.dart`**

`packages/hibiki_anki/lib/hibiki_anki.dart` 加（按字母位置）：

```dart
export 'src/lapis_note_type.dart';
```

- [ ] **Step 6: 运行测试确认通过**

Run: `cd hibiki && flutter test test/anki/lapis_note_type_test.dart`
Expected: PASS（5 test）。

- [ ] **Step 7: Commit**

```bash
git add packages/hibiki_anki/lib/src/lapis_note_type.dart \
        packages/hibiki_anki/lib/hibiki_anki.dart \
        hibiki/test/anki/lapis_note_type_test.dart
git commit -m "feat(anki): authoritative Lapis note type schema (vendored donkuri/lapis 1.7.0, GPL-3.0)"
```

---

## Task 2: BaseAnkiRepository 抽象原语

**Files:**
- Modify: `packages/hibiki_anki/lib/src/base_anki_repository.dart`

> 抽象方法无法单独测试；其行为由 Task 3/4 的实现测试覆盖。本任务只加签名 + import。

- [ ] **Step 1: 加抽象方法 + import**

`base_anki_repository.dart`：顶部 import 加 `import 'lapis_note_type.dart';`，在 `abstract class BaseAnkiRepository` 内（`isDuplicate` 抽象声明附近，:46 后）加：

```dart
  /// Create [template] as a note type in the backend. Idempotent: returns
  /// `false` if a note type with that name already exists (no-op), `true` if
  /// newly created. Throws on backend failure (not-reachable, permission).
  Future<bool> createNoteType(AnkiNoteTypeTemplate template);

  /// Create a deck by [name]. Idempotent: returns `false` if it already
  /// exists, `true` if newly created. Throws on backend failure.
  Future<bool> createDeck(String name);
```

- [ ] **Step 2: 验证编译失败（两实现未实现）**

Run: `cd hibiki && flutter analyze ../packages/hibiki_anki/lib`
Expected: ERROR — `AnkiRepository`/`AnkiConnectRepository` missing concrete implementations of `createNoteType`/`createDeck`。（Task 3/4 补齐后消失。）

- [ ] **Step 3: 不提交**

> 等 Task 3/4 实现后随其提交，避免中间态破坏构建。

---

## Task 3: AnkiConnect createModel/createDeck（桌面/iOS）

**Files:**
- Modify: `packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_service.dart`
- Modify: `packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_repository.dart`
- Test: `hibiki/test/anki/ankiconnect_create_test.dart`

- [ ] **Step 1: 写请求形状测试（先失败）**

`hibiki/test/anki/ankiconnect_create_test.dart`：

```dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki_anki/src/ankiconnect/ankiconnect_service.dart';

void main() {
  test('createModel sends correct AnkiConnect v6 payload', () async {
    late Map<String, dynamic> captured;
    final client = MockClient((req) async {
      captured = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({'result': 1, 'error': null}), 200);
    });
    final service = AnkiConnectService(client: client);

    await service.createModel(LapisNoteType.template);

    expect(captured['action'], 'createModel');
    expect(captured['version'], 6);
    final params = captured['params'] as Map<String, dynamic>;
    expect(params['modelName'], 'Lapis');
    expect(params['inOrderFields'], LapisNoteType.fields);
    expect(params['isCloze'], false);
    expect(params['css'], LapisNoteType.css);
    final templates = params['cardTemplates'] as List;
    expect(templates, hasLength(1));
    final card = templates.first as Map<String, dynamic>;
    expect(card['Name'], 'Card 1');
    expect(card['Front'], LapisNoteType.front);
    expect(card['Back'], LapisNoteType.back);
  });

  test('createDeck sends createDeck action', () async {
    late Map<String, dynamic> captured;
    final client = MockClient((req) async {
      captured = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({'result': 1, 'error': null}), 200);
    });
    final service = AnkiConnectService(client: client);

    await service.createDeck('Lapis');

    expect(captured['action'], 'createDeck');
    expect((captured['params'] as Map)['deck'], 'Lapis');
  });
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd hibiki && flutter test test/anki/ankiconnect_create_test.dart`
Expected: FAIL（`client` 命名参数不存在 / `createModel` undefined）。

- [ ] **Step 3: AnkiConnectService 改可注入 client + 加 createModel/createDeck**

`ankiconnect_service.dart`：

1. import 顶部已有 `import 'package:http/http.dart' as http;`，加 `import '../lapis_note_type.dart';`。
2. 构造与字段改为可注入 client：

```dart
  final http.Client _client;

  AnkiConnectService({
    this.host = 'localhost',
    this.port = 8765,
    this.apiKey = '',
    http.Client? client,
  }) : _client = client ?? http.Client();
```

3. `_request` 内把 `http.post(...)` 改成 `_client.post(...)`（仅这一处，:34）：

```dart
    final response = await _client.post(
      Uri.parse('http://$host:$port'),
      body: body,
      headers: {'Content-Type': 'application/json'},
    ).timeout(_timeout);
```

4. 在 `storeMediaFile` 后（:181 前的类内）加：

```dart
  Future<void> createModel(AnkiNoteTypeTemplate template) async {
    await _request('createModel', {
      'modelName': template.name,
      'inOrderFields': template.fields,
      'css': template.css,
      'isCloze': false,
      'cardTemplates': [
        {
          'Name': template.cardName,
          'Front': template.front,
          'Back': template.back,
        },
      ],
    });
  }

  Future<void> createDeck(String name) async {
    await _request('createDeck', {'deck': name});
  }
```

- [ ] **Step 4: AnkiConnectRepository 实现幂等原语**

`ankiconnect_repository.dart`：import 加 `import '../lapis_note_type.dart';`，类内（`isDuplicate` 后，:263 附近）加：

```dart
  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async {
    final service = await _getService();
    final existing = await service.getModelNames();
    if (existing.contains(template.name)) return false;
    await service.createModel(template);
    return true;
  }

  @override
  Future<bool> createDeck(String name) async {
    final service = await _getService();
    final existing = await service.getDeckNames();
    if (existing.contains(name)) return false;
    await service.createDeck(name);
    return true;
  }
```

- [ ] **Step 5: 运行确认通过**

Run: `cd hibiki && flutter test test/anki/ankiconnect_create_test.dart`
Expected: PASS（2 test）。

- [ ] **Step 6: Commit**

```bash
git add packages/hibiki_anki/lib/src/base_anki_repository.dart \
        packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_service.dart \
        packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_repository.dart \
        hibiki/test/anki/ankiconnect_create_test.dart
git commit -m "feat(anki): AnkiConnect createModel/createDeck primitives (injectable http client)"
```

---

## Task 4: AnkiDroid createNoteType/createDeck（安卓）

**Files:**
- Modify: `hibiki/android/app/src/main/java/app/hibiki/reader/AnkiChannelHandler.java`
- Modify: `packages/hibiki_anki/lib/src/ankidroid/anki_repository.dart`
- Test: `hibiki/test/anki/anki_native_createmodel_guard_test.dart`

> 安卓原生 AddContentApi 在 host(flutter test) 跑不到 → 用源码守卫 + Dart 端 channel 调用结构守卫。

- [ ] **Step 1: 写源码守卫测试（先失败）**

`hibiki/test/anki/anki_native_createmodel_guard_test.dart`：

```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 测试 cwd = hibiki/ 包根。
  final java = File(
    'android/app/src/main/java/app/hibiki/reader/AnkiChannelHandler.java',
  ).readAsStringSync();
  final repo = File(
    '../packages/hibiki_anki/lib/src/ankidroid/anki_repository.dart',
  ).readAsStringSync();

  group('AnkiDroid native create path is schema-driven', () {
    test('native handler has createNoteType + createDeck cases', () {
      expect(java, contains('case "createNoteType"'));
      expect(java, contains('case "createDeck"'));
      expect(java, contains('addNewCustomModel'));
      expect(java, contains('addNewDeck'));
    });

    test('legacy hardcoded Lapis model is gone', () {
      expect(java.contains('case "addDefaultModel"'), isFalse);
      expect(java.contains('"Cloze Before"'), isFalse,
          reason: 'old Term/Meaning hardcoded schema must be removed');
      expect(java.contains('"Expanded Meaning"'), isFalse);
    });

    test('Dart repo invokes the schema-driven channel methods', () {
      expect(repo, contains("invokeMethod('createNoteType'"));
      expect(repo, contains("invokeMethod('createDeck'"));
      expect(repo, contains('noteTypeFields'));
    });
  });
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd hibiki && flutter test test/anki/anki_native_createmodel_guard_test.dart`
Expected: FAIL（旧 `addDefaultModel` 还在 / 新 case 缺失）。

- [ ] **Step 3: 改 Java handler**

`AnkiChannelHandler.java`：

3a. 在 `register()` 顶部参数提取区（:49-54 附近）加新参数：

```java
                final ArrayList<String> noteTypeFields = call.argument("noteTypeFields");
                final String noteTypeName = call.argument("noteTypeName");
                final String cardName = call.argument("cardName");
                final String front = call.argument("front");
                final String back = call.argument("back");
                final String css = call.argument("css");
                final String deckName = call.argument("deckName");
```

3b. 把 `case "addDefaultModel":`（:138-141）整段替换为：

```java
                    case "createNoteType":
                        if (noteTypeName == null || noteTypeFields == null
                                || noteTypeFields.isEmpty()) {
                            result.error("MISSING_ARG",
                                "noteTypeName and noteTypeFields are required", null);
                        } else if (requirePermission(result)) {
                            try {
                                createNoteType(noteTypeName, noteTypeFields,
                                    cardName, front, back, css);
                                result.success(null);
                            } catch (Exception e) {
                                result.error("CREATE_MODEL_FAILED",
                                    e.getMessage(), null);
                            }
                        }
                        break;
                    case "createDeck":
                        if (deckName == null) {
                            result.error("MISSING_ARG",
                                "deckName is required", null);
                        } else if (requirePermission(result)) {
                            try {
                                if (ankiDroid.findDeckIdByName(deckName) == null) {
                                    api.addNewDeck(deckName);
                                }
                                result.success(null);
                            } catch (Exception e) {
                                result.error("CREATE_DECK_FAILED",
                                    e.getMessage(), null);
                            }
                        }
                        break;
```

3c. 把 `addDefaultModel()`（:243-272）和 `modelExists()`（:274-276）整段删除，替换为：

```java
    private void createNoteType(String name, ArrayList<String> fields,
                                String cardName, String front, String back,
                                String css) {
        final AddContentApi api = new AddContentApi(activity);
        // Idempotent: a model with this name + field count already exists.
        if (ankiDroid.findModelIdByName(name, fields.size()) != null) return;
        api.addNewCustomModel(
            name,
            fields.toArray(new String[0]),
            new String[] { cardName },
            new String[] { front },
            new String[] { back },
            css,
            null,
            null
        );
    }
```

- [ ] **Step 4: 改 AnkiDroid Dart repo**

`anki_repository.dart`：import 加 `import '../lapis_note_type.dart';`；类内（`isDuplicate` 后，:267 附近）加：

```dart
  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async {
    await _channel.invokeMethod('requestAnkidroidPermissions');
    final models = await _channel.invokeMethod('getModelList') as Map?;
    final exists =
        models?.values.any((v) => v?.toString() == template.name) ?? false;
    if (exists) return false;
    await _channel.invokeMethod('createNoteType', <String, dynamic>{
      'noteTypeName': template.name,
      'noteTypeFields': template.fields,
      'cardName': template.cardName,
      'front': template.front,
      'back': template.back,
      'css': template.css,
    });
    return true;
  }

  @override
  Future<bool> createDeck(String name) async {
    await _channel.invokeMethod('requestAnkidroidPermissions');
    final decks = await _channel.invokeMethod('getDecks') as Map?;
    final exists = decks?.values.any((v) => v?.toString() == name) ?? false;
    if (exists) return false;
    await _channel.invokeMethod('createDeck', <String, dynamic>{
      'deckName': name,
    });
    return true;
  }
```

- [ ] **Step 5: 运行守卫测试确认通过**

Run: `cd hibiki && flutter test test/anki/anki_native_createmodel_guard_test.dart`
Expected: PASS（3 test）。

- [ ] **Step 6: 确认整个 hibiki_anki 编译（Task 2 抽象方法已被两实现满足）**

Run: `cd hibiki && flutter analyze ../packages/hibiki_anki/lib`
Expected: No issues。

- [ ] **Step 7: Commit**

```bash
git add hibiki/android/app/src/main/java/app/hibiki/reader/AnkiChannelHandler.java \
        packages/hibiki_anki/lib/src/ankidroid/anki_repository.dart \
        hibiki/test/anki/anki_native_createmodel_guard_test.dart
git commit -m "feat(anki): schema-driven AnkiDroid createNoteType/createDeck (drop hardcoded Term/Meaning model)"
```

---

## Task 5: AnkiViewModel.createLapisSetup 编排

**Files:**
- Modify: `hibiki/lib/src/anki/anki_view_model.dart`
- Test: `hibiki/test/anki/anki_view_model_lapis_test.dart`

- [ ] **Step 1: 写流程测试（先失败）**

`hibiki/test/anki/anki_view_model_lapis_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';

/// In-memory fake；覆写 loadSettings/saveSettings 避开 SharedPreferences，
/// 复用 base 的 updateSettings。
class _FakeRepo extends BaseAnkiRepository {
  _FakeRepo({this.failFetch = false});
  AnkiSettings _settings = const AnkiSettings();
  final bool failFetch;
  int createNoteTypeCalls = 0;
  int createDeckCalls = 0;
  bool noteTypeExists = false;
  bool deckExists = false;

  @override
  Future<AnkiSettings> loadSettings() async => _settings;
  @override
  Future<void> saveSettings(AnkiSettings s) async => _settings = s;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async {
    createNoteTypeCalls++;
    if (noteTypeExists) return false;
    noteTypeExists = true;
    return true;
  }

  @override
  Future<bool> createDeck(String name) async {
    createDeckCalls++;
    if (deckExists) return false;
    deckExists = true;
    return true;
  }

  @override
  Future<AnkiFetchResult> fetchConfiguration() async {
    if (failFetch) return const AnkiFetchResult.error('boom');
    final decks = [const AnkiDeck(id: 1, name: 'Lapis')];
    final noteTypes = [
      AnkiNoteType(id: 7, name: 'Lapis', fields: LapisNoteType.fields),
    ];
    _settings = _settings.copyWith(
      availableDecks: decks,
      availableNoteTypes: noteTypes,
    );
    return AnkiFetchResult.success(decks: decks, noteTypes: noteTypes);
  }

  @override
  Future<MineResult> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async => MineResult.error;

  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('createLapisSetup creates, fetches, selects Lapis + applies preset',
      () async {
    final repo = _FakeRepo();
    final vm = AnkiViewModel(repo);
    await Future<void>.delayed(Duration.zero); // 让构造里的 _loadSettings 完成

    final result = await vm.createLapisSetup();

    expect(result.outcome, LapisSetupOutcome.created);
    expect(repo.createNoteTypeCalls, 1);
    expect(repo.createDeckCalls, 1);
    final s = vm.state.settings;
    expect(s.selectedNoteTypeName, 'Lapis');
    expect(s.selectedDeckName, 'Lapis');
    expect(s.fieldMappings['Expression'], '{expression}');
    expect(s.fieldMappings['Picture'], '{book-cover}');
    expect(vm.state.isFetching, isFalse);
  });

  test('createLapisSetup reports alreadyExisted when model present', () async {
    final repo = _FakeRepo()
      ..noteTypeExists = true
      ..deckExists = true;
    final vm = AnkiViewModel(repo);
    await Future<void>.delayed(Duration.zero);

    final result = await vm.createLapisSetup();
    expect(result.outcome, LapisSetupOutcome.alreadyExisted);
  });

  test('createLapisSetup surfaces fetch failure', () async {
    final repo = _FakeRepo(failFetch: true);
    final vm = AnkiViewModel(repo);
    await Future<void>.delayed(Duration.zero);

    final result = await vm.createLapisSetup();
    expect(result.outcome, LapisSetupOutcome.failed);
    expect(vm.state.errorMessage, isNotNull);
  });
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd hibiki && flutter test test/anki/anki_view_model_lapis_test.dart`
Expected: FAIL（`createLapisSetup` / `LapisSetupOutcome` undefined）。

- [ ] **Step 3: 实现 createLapisSetup + 结果类型**

`anki_view_model.dart`：import 已有 `package:hibiki_anki/hibiki_anki.dart`（含 LapisNoteType）。在文件末尾的 `final ankiRepositoryProvider` 之前、`AnkiViewModel` 类内（`updateAnkiConnectApiKey` 后，:137 附近）加方法；并在 class 外加结果类型。

类内方法：

```dart
  Future<LapisSetupResult> createLapisSetup() async {
    state = state.copyWith(isFetching: true, clearError: true);
    try {
      final created = await _repository.createNoteType(LapisNoteType.template);
      await _repository.createDeck(LapisNoteType.deckName);

      final fetch = await _repository.fetchConfiguration();
      if (fetch is AnkiFetchError) {
        state = state.copyWith(isFetching: false, errorMessage: fetch.message);
        return LapisSetupResult(LapisSetupOutcome.failed, fetch.message);
      }

      final settings = await _repository.loadSettings();
      final noteType = settings.availableNoteTypes
          .firstWhere((t) => t.name == LapisNoteType.modelName,
              orElse: () => settings.availableNoteTypes.first);
      final deck = settings.availableDecks.firstWhere(
          (d) => d.name == LapisNoteType.deckName,
          orElse: () => settings.availableDecks.first);

      final updated = await _repository.updateSettings((s) => s.copyWith(
            selectedDeckId: deck.id,
            selectedDeckName: deck.name,
            selectedNoteTypeId: noteType.id,
            selectedNoteTypeName: noteType.name,
            fieldMappings: LapisPreset.applyDefaults(noteType, {}),
          ));
      state = state.copyWith(settings: updated, isFetching: false);
      return LapisSetupResult(created
          ? LapisSetupOutcome.created
          : LapisSetupOutcome.alreadyExisted);
    } catch (e, stack) {
      debugPrint('AnkiViewModel.createLapisSetup: $e\n$stack');
      state = state.copyWith(isFetching: false, errorMessage: e.toString());
      return LapisSetupResult(LapisSetupOutcome.failed, e.toString());
    }
  }
```

文件顶部 import 加 `import 'package:flutter/foundation.dart';`（debugPrint）。在 `AnkiViewModel` 类外（文件末尾 providers 之前）加：

```dart
enum LapisSetupOutcome { created, alreadyExisted, failed }

class LapisSetupResult {
  const LapisSetupResult(this.outcome, [this.message]);
  final LapisSetupOutcome outcome;
  final String? message;
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd hibiki && flutter test test/anki/anki_view_model_lapis_test.dart`
Expected: PASS（3 test）。

- [ ] **Step 5: Commit**

```bash
git add hibiki/lib/src/anki/anki_view_model.dart \
        hibiki/test/anki/anki_view_model_lapis_test.dart
git commit -m "feat(anki): AnkiViewModel.createLapisSetup orchestration (create + select + preset)"
```

---

## Task 6: LapisPreset 对齐 22 字段

**Files:**
- Modify: `packages/hibiki_anki/lib/src/lapis_preset.dart`
- Test: `hibiki/test/anki/lapis_preset_test.dart`

- [ ] **Step 1: 写测试（先失败）**

`hibiki/test/anki/lapis_preset_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

void main() {
  test('LapisPreset defaults == LapisNoteType.defaultFieldMappings', () {
    final noteType =
        AnkiNoteType(id: 1, name: 'Lapis', fields: LapisNoteType.fields);
    final mappings = LapisPreset.applyDefaults(noteType, {});
    for (final entry in LapisNoteType.defaultFieldMappings.entries) {
      expect(mappings[entry.key], entry.value);
    }
    // 留空字段不应被映射
    expect(mappings.containsKey('SentenceFurigana'), isFalse);
    expect(mappings.containsKey('Hint'), isFalse);
  });

  test('matches() recognises the official Lapis note type', () {
    final noteType =
        AnkiNoteType(id: 1, name: 'Lapis', fields: LapisNoteType.fields);
    expect(LapisPreset.matches(noteType), isTrue);
  });

  test('existing user mappings are preserved over defaults', () {
    final noteType =
        AnkiNoteType(id: 1, name: 'Lapis', fields: LapisNoteType.fields);
    final result =
        LapisPreset.applyDefaults(noteType, {'Expression': '{reading}'});
    expect(result['Expression'], '{reading}');
  });
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd hibiki && flutter test test/anki/lapis_preset_test.dart`
Expected: 可能 PASS 部分、FAIL 在 `SentenceFurigana`/字段差异（当前 `_defaults` 与 `defaultFieldMappings` 不完全一致——尤其 `IsWordAndSentenceCard` 已在，但确保单一真相）。

- [ ] **Step 3: 让 LapisPreset 引用单一真相**

`lapis_preset.dart`：把内联 `_defaults` 改为引用 `LapisNoteType.defaultFieldMappings`，消除重复定义：

```dart
import 'anki_models.dart';
import 'lapis_note_type.dart';

class LapisPreset {
  static const _defaults = LapisNoteType.defaultFieldMappings;

  static bool matches(AnkiNoteType noteType) {
    final fields = noteType.fields.toSet();
    return noteType.name.toLowerCase().contains('lapis') ||
        ['Expression', 'MainDefinition', 'Sentence'].every(fields.contains);
  }

  static Map<String, String> defaultMappings(AnkiNoteType noteType) => {
        for (final f in noteType.fields)
          if (_defaults.containsKey(f)) f: _defaults[f]!,
      };

  static Map<String, String> applyDefaults(
    AnkiNoteType noteType,
    Map<String, String> currentMappings,
  ) {
    if (!matches(noteType)) return currentMappings;
    return {...defaultMappings(noteType), ...currentMappings};
  }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd hibiki && flutter test test/anki/lapis_preset_test.dart`
Expected: PASS（3 test）。

- [ ] **Step 5: Commit**

```bash
git add packages/hibiki_anki/lib/src/lapis_preset.dart \
        hibiki/test/anki/lapis_preset_test.dart
git commit -m "refactor(anki): LapisPreset defaults sourced from LapisNoteType (single source of truth)"
```

---

## Task 7: i18n keys

**Files:**
- Modify: `hibiki/lib/i18n/*.i18n.json`（经脚本）
- Generated: `hibiki/lib/i18n/strings.g.dart`

> 必须用 i18n_sync.dart，禁手改 17 文件。zh 用简体中文，en 用英文。其余语言脚本会补成英文占位（可接受，后续翻译）。

- [ ] **Step 1: 用脚本加 5 个 key**

在 `hibiki/` 下运行（用项目 Flutter 工具链）：

```bash
cd hibiki
dart run tool/i18n_sync.dart --add anki_create_lapis "Create Lapis deck" "创建 Lapis 卡组"
dart run tool/i18n_sync.dart --add anki_create_lapis_hint "Adds the Lapis note type and a Lapis deck to Anki, then selects them." "向 Anki 添加 Lapis 笔记类型和 Lapis 卡组并自动选中。"
dart run tool/i18n_sync.dart --add anki_create_lapis_success "Lapis note type and deck created." "已创建 Lapis 笔记类型和卡组。"
dart run tool/i18n_sync.dart --add anki_create_lapis_exists "Lapis note type and deck already exist — selected them." "Lapis 笔记类型和卡组已存在，已选中。"
dart run tool/i18n_sync.dart --add anki_create_lapis_failed "Could not create Lapis deck: {error}" "无法创建 Lapis 卡组：{error}"
```

注意 `anki_create_lapis_failed` 含占位符 `{error}`（Slang 会生成带参方法 `t.anki_create_lapis_failed(error: ...)`）。

- [ ] **Step 2: 重新生成 + 格式化**

```bash
cd hibiki
dart run slang
dart format lib/i18n/strings.g.dart
```

- [ ] **Step 3: 验证生成**

Run: `cd hibiki && flutter test test/i18n/` （若存在 i18n 完整性测试）
或：`grep -c "anki_create_lapis\b" lib/i18n/strings.g.dart`（应 >0）。
Expected: i18n 完整性测试 PASS；getter 已生成。

- [ ] **Step 4: Commit**

```bash
git add hibiki/lib/i18n/
git commit -m "i18n(anki): add anki_create_lapis* keys (17 languages)"
```

---

## Task 8: 设置页按钮

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/anki_settings_page.dart`
- Test: `hibiki/test/anki/anki_native_createmodel_guard_test.dart`（追加 UI 接线守卫）

> AnkiSettingsPage 继承 BasePage（依赖 appModel/scaffold），host 下完整 pump 成本高；UI 接线用源码守卫 + 已覆盖的 ViewModel 行为测试保证逻辑。真实按钮交给设备验证。

- [ ] **Step 1: 追加 UI 接线守卫测试（先失败）**

在 `hibiki/test/anki/anki_native_createmodel_guard_test.dart` 末尾 `main()` 内追加一个 group：

```dart
  group('settings page wires the Create Lapis action', () {
    final page = File(
      'lib/src/pages/implementations/anki_settings_page.dart',
    ).readAsStringSync();

    test('calls createLapisSetup and uses the i18n label', () {
      expect(page, contains('createLapisSetup()'));
      expect(page, contains('t.anki_create_lapis'));
    });
  });
```

- [ ] **Step 2: 运行确认失败**

Run: `cd hibiki && flutter test test/anki/anki_native_createmodel_guard_test.dart`
Expected: FAIL（新 group：page 未引用 createLapisSetup）。

- [ ] **Step 3: 加按钮 + 处理结果**

`anki_settings_page.dart`：

3a. 在第一个 `AdaptiveSettingsSection`（:29-38）的 children 里、`_buildFetchTile(uiState, vm)` 之后加一行：

```dart
            _buildCreateLapisTile(uiState, vm),
```

3b. 在 `_buildFetchTile` 方法之后（:145 附近）加新方法（用与 fetch tile 同款 focus-registered 的 `AdaptiveSettingsRow`）：

```dart
  Widget _buildCreateLapisTile(AnkiUiState uiState, AnkiViewModel vm) {
    return AdaptiveSettingsRow(
      icon: Icons.note_add_outlined,
      showIcon: true,
      title: t.anki_create_lapis,
      subtitle: t.anki_create_lapis_hint,
      trailing: uiState.isFetching
          ? SizedBox(
              width: 20,
              height: 20,
              child: adaptiveIndicator(context: context, strokeWidth: 2),
            )
          : null,
      onTap: uiState.isFetching ? null : () => _runCreateLapis(vm),
    );
  }

  Future<void> _runCreateLapis(AnkiViewModel vm) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await vm.createLapisSetup();
    if (!mounted) return;
    final String message;
    switch (result.outcome) {
      case LapisSetupOutcome.created:
        message = t.anki_create_lapis_success;
      case LapisSetupOutcome.alreadyExisted:
        message = t.anki_create_lapis_exists;
      case LapisSetupOutcome.failed:
        message = t.anki_create_lapis_failed(error: result.message ?? '');
    }
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }
```

3c. 文件顶部 import 加 `import 'package:hibiki/src/anki/anki_view_model.dart';`（已有，见 :8——确认 `LapisSetupOutcome` 随该 import 可见，因定义在同文件）。

> `subtitle` 形参：确认 `AdaptiveSettingsRow` 支持 `subtitle`（`AdaptiveSettingsSwitchRow` 用 subtitle，:109）。若 `AdaptiveSettingsRow` 无 subtitle 形参，去掉该行即可（保留 title + hint 仅在 title）。实现时 grep 确认：`grep -n "subtitle" lib/src/utils/**/adaptive*.dart`。

- [ ] **Step 4: 运行守卫 + 全 anki 测试确认通过**

Run: `cd hibiki && flutter test test/anki/`
Expected: PASS（含新 UI 守卫 group）。

- [ ] **Step 5: analyze**

Run: `cd hibiki && flutter analyze lib/src/pages/implementations/anki_settings_page.dart`
Expected: No issues。

- [ ] **Step 6: Commit**

```bash
git add hibiki/lib/src/pages/implementations/anki_settings_page.dart \
        hibiki/test/anki/anki_native_createmodel_guard_test.dart
git commit -m "feat(anki): one-click Create Lapis deck button in Anki settings"
```

---

## Task 9: 删除死代码（Term/Meaning 旧路径）

**Files:**
- Modify: `hibiki/lib/src/models/anki_integration.dart`
- Modify: `hibiki/lib/src/models/app_model.dart`
- Modify: `hibiki/lib/i18n/*.i18n.json`（经脚本删 orphan key）

- [ ] **Step 1: 删 app_model 包装**

`app_model.dart`：删除 :1899-1900：

```dart
  Future<void> addDefaultModelIfMissing() =>
      ankiIntegration.addDefaultModelIfMissing(_ctx);
```

（确认上下文该方法块整体删除，不留悬挂注释。）

- [ ] **Step 2: 删 anki_integration 死方法 + 死对话框**

`anki_integration.dart`：
- 删除 `addDefaultModelIfMissing(BuildContext? ctx)` 方法（:38-51）。
- 删除 `AnkiDefaultModelDialog` 类整段（:151-197）。
- 保留 `requestPermissions`/`showApiMessage`/`getDecks`/`getModelList`/`getFieldList`/`AnkiApiMessageDialog`（仍在用）。

- [ ] **Step 3: 删 orphan i18n key**

`info_standard_model` / `info_standard_model_content` 删除后无引用，用脚本删：

```bash
cd hibiki
dart run tool/i18n_sync.dart --remove info_standard_model
dart run tool/i18n_sync.dart --remove info_standard_model_content
dart run slang
dart format lib/i18n/strings.g.dart
```

- [ ] **Step 4: 验证无残留引用 + 编译**

```bash
cd hibiki
grep -rn "addDefaultModelIfMissing\|AnkiDefaultModelDialog\|info_standard_model" lib | grep -v strings.g.dart
flutter analyze lib/src/models/anki_integration.dart lib/src/models/app_model.dart
```
Expected: grep 无命中（strings.g.dart 已重生不含）；analyze No issues。

- [ ] **Step 5: Commit**

```bash
git add hibiki/lib/src/models/anki_integration.dart \
        hibiki/lib/src/models/app_model.dart \
        hibiki/lib/i18n/
git commit -m "chore(anki): remove dead Term/Meaning addDefaultModel path + orphan i18n"
```

---

## Task 10: 全量验证

**Files:** 无（仅验证）

- [ ] **Step 1: 格式化**

```bash
cd hibiki && dart format .
cd ../packages/hibiki_anki && dart format .
```
Expected: 仅本轮文件被格式化（无意外大改）。

- [ ] **Step 2: analyze**

```bash
cd hibiki && flutter analyze
```
Expected: No issues found.

- [ ] **Step 3: 全量测试**

```bash
cd hibiki && flutter test
```
Expected: 全绿（含本轮新增 5 个 anki 测试文件）。若有**预存**失败（与本改动无关，如并发 agent 的 sync/settings 预红），逐一确认 stash 本轮改动后基线同红，记录之，不算本任务回归。

- [ ] **Step 4: 提交残留（如格式化产生）**

```bash
git status --short
# 只 stage 本轮相关文件
git diff --cached --check
```

- [ ] **Step 5: 设备验证（交给用户，不在本计划自动完成）**

记录到 `docs/BUGS.md` / 复测清单：
- 桌面（AnkiConnect，Anki 桌面开 + AnkiConnect 插件）：点按钮 → Anki 出现 `Lapis` note type（22 字段）+ `Lapis` deck；再点一次 → 「已存在」提示；制一张卡 → 字段命中（Expression/Sentence/Picture=封面/SentenceAudio=sasayaki）。
- 安卓（AnkiDroid 已装 + 授权）：同上路径。
- 失败路径：AnkiConnect 关闭 / AnkiDroid 未装 → 明确失败 SnackBar，不崩。

---

## Self-Review（plan 自检）

**Spec 覆盖：**
- 一键创建 note type + deck（全平台）→ Task 3（AnkiConnect）+ Task 4（AnkiDroid）+ Task 5（编排）。✅
- vendor 正版 v1.7.0 模板 → Task 1。✅
- deck 默认名 `Lapis` → Task 1（`deckName='Lapis'`）+ Task 5（选中）。✅
- 字段映射对齐（含 book-cover/sasayaki）→ Task 1（defaultFieldMappings）+ Task 6（LapisPreset 单一真相）。✅
- UI 按钮 + 三态反馈 → Task 8。✅
- i18n `anki_create_lapis*` → Task 7。✅
- 删死代码 + orphan i18n → Task 9。✅
- 幂等/错误处理 → Task 3/4（exists 检查）+ Task 5（failed 分支）。✅
- 测试矩阵（schema/请求形状/流程/preset/原生守卫）→ Task 1/3/5/6/4+8。✅

**Placeholder 扫描：** 唯一“占位”是 Task 1 的 `<<<FRONT_HTML>>>` 等，已配 Step 1 确定性抓取命令（验证过的 pinned URL + 字节数校验），非 TODO。✅

**类型一致性：** `AnkiNoteTypeTemplate`（name/fields/cardName/front/back/css）跨 Task 1/2/3/4/5 一致；`createNoteType`/`createDeck` 返回 `Future<bool>` 跨 base/两实现/fake 一致；`LapisSetupOutcome{created,alreadyExisted,failed}` + `LapisSetupResult(outcome,[message])` 跨 Task 5/8 一致。✅

**风险点：**
- Task 8 的 `AdaptiveSettingsRow` 是否支持 `subtitle` —— Step 3c 已给 grep 兜底（不支持就去掉 subtitle）。
- Task 1 的 raw string 若文件含 `'''` —— Step 4 已给检查命令与改用 `"""` 的兜底。
- `api.addNewCustomModel` 8 参签名以本机 AnkiDroid api 版本为准（旧 fork 已在 :250 用过，签名稳定）。
