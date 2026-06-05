# Yomitan-API 兼容服务端 实现计划（线2）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Hibiki 暴露一个 yomitan-api（Kuuuube/yomitan-api）协议兼容的 HTTP server，使现有 yomitan-api 客户端可指向 Hibiki 查其已导入词典。

**Architecture:** 独立 shelf server 实例（默认端口 19633，区别于 SyncServer），复用已存在的 `HibikiRemoteLookupService` 查词。一个纯函数适配器把 Hibiki 扁平的 `DictionaryEntry` 包装成 Yomitan `termEntries` 内部结构形状（宽松兼容：展示字段真实，内部字段填合理默认）。设置开关默认关，仿 `remote_lookup_enabled` 范式。

**Tech Stack:** Dart, shelf（已有依赖）, Hibiki `HoshiDicts` FFI 查词, Riverpod/AppModel。

设计依据：`docs/specs/2026-06-05-yomitan-interop-design.md`（§2.3 宽松兼容决策、§6）。

---

## 文件结构

- Create: `hibiki/lib/src/sync/yomitan_term_entries_adapter.dart` — 纯函数：Hibiki 查词结果 → Yomitan termEntries 形状。
- Create: `hibiki/lib/src/sync/yomitan_tokenize_adapter.dart` — 纯函数：分词 → Yomitan tokenize 形状。
- Create: `hibiki/lib/src/sync/yomitan_api_server.dart` — 独立 shelf server（4 端点 + 鉴权 + 端口处理）。
- Create: `hibiki/test/sync/yomitan_term_entries_adapter_test.dart`
- Create: `hibiki/test/sync/yomitan_tokenize_adapter_test.dart`
- Create: `hibiki/test/sync/yomitan_api_server_test.dart`
- Modify: `hibiki/lib/src/models/preferences_repository.dart` — 加 3 个偏好（enabled/port/apiKey）。
- Modify: `hibiki/lib/src/models/app_model.dart` — 转发 getter/setter。
- Modify: `hibiki/lib/src/settings/settings_schema.dart` — 设置 UI（开关 + 端口 + key）。
- Modify: `hibiki/lib/i18n/*.i18n.json`（经 `tool/i18n_sync.dart`）。

---

## Task 1: termEntries 适配器（纯函数）

把一个 Hibiki `DictionaryEntry`（字段 `word/reading/meaning/extra`，`extra` 是 JSON 字符串含 `definitionTags/termTags/matched/deinflected/frequencies/pitches`，见 `language.dart:432`）映射成一个 Yomitan `dictionaryEntry`，再包成顶层响应。宽松兼容：展示字段真实，`score/sequences/tags/...` 等内部字段填合理默认。

**Files:**
- Create: `hibiki/lib/src/sync/yomitan_term_entries_adapter.dart`
- Test: `hibiki/test/sync/yomitan_term_entries_adapter_test.dart`

- [ ] **Step 1: 写失败测试**

```dart
// hibiki/test/sync/yomitan_term_entries_adapter_test.dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/src/sync/yomitan_term_entries_adapter.dart';

DictionaryEntry _entry({
  String word = '分かる',
  String reading = 'わかる',
  String meaning = '[{"type":"structured-content","content":"to understand"}]',
  String dict = 'Jitendex',
}) {
  final extra = jsonEncode({
    'definitionTags': 'v5 vi',
    'termTags': 'P',
    'matched': 'わかる',
    'deinflected': 'わかる',
    'frequencies': [
      {'dictName': 'Freq', 'values': [{'value': 1234, 'display': '1234'}]}
    ],
    'pitches': [
      {'dictName': 'Pitch', 'positions': [2]}
    ],
  });
  return DictionaryEntry(
    dictionaryName: dict,
    word: word,
    reading: reading,
    meaning: meaning,
    extra: extra,
    popularity: 0,
  );
}

void main() {
  group('buildYomitanTermEntriesResponse', () {
    test('wraps a result into termEntries top-level shape', () {
      final result = DictionarySearchResult(
        searchTerm: 'わかる',
        entries: [_entry()],
        bestLength: 3,
      );
      final out = buildYomitanTermEntriesResponse(result, 0);

      expect(out['index'], 0);
      expect(out['originalTextLength'], 3);
      final entries = out['dictionaryEntries'] as List;
      expect(entries.length, 1);
    });

    test('maps display fields truthfully', () {
      final result = DictionarySearchResult(
        searchTerm: 'わかる', entries: [_entry()], bestLength: 3);
      final de = (buildYomitanTermEntriesResponse(result, 0)['dictionaryEntries']
          as List).first as Map<String, dynamic>;

      expect(de['type'], 'term');
      final hw = (de['headwords'] as List).first as Map<String, dynamic>;
      expect(hw['term'], '分かる');
      expect(hw['reading'], 'わかる');
      expect(hw['wordClasses'], ['v5', 'vi']); // 拆 definitionTags
      final src = (hw['sources'] as List).first as Map<String, dynamic>;
      expect(src['deinflectedText'], 'わかる');
      expect(src['matchType'], 'exact');

      final def = (de['definitions'] as List).first as Map<String, dynamic>;
      expect(def['dictionary'], 'Jitendex');
      // structured-content 原样透传（解析成对象/数组）
      expect(def['entries'], isA<List>());

      final freq = (de['frequencies'] as List).first as Map<String, dynamic>;
      expect(freq['frequency'], 1234);
      expect(freq['displayValue'], '1234');
    });

    test('fills internal fields with sane defaults', () {
      final result = DictionarySearchResult(
        searchTerm: 'わかる', entries: [_entry()], bestLength: 3);
      final de = (buildYomitanTermEntriesResponse(result, 0)['dictionaryEntries']
          as List).first as Map<String, dynamic>;

      expect(de['isPrimary'], true);
      expect(de['score'], 0);
      final def = (de['definitions'] as List).first as Map<String, dynamic>;
      expect(def['sequences'], <int>[]);
      expect(def['tags'], <dynamic>[]); // tag 元数据已丢，空数组
    });

    test('plain-text meaning becomes a string entry, not parsed', () {
      final result = DictionarySearchResult(
        searchTerm: 'x',
        entries: [_entry(meaning: 'to understand')],
        bestLength: 1);
      final def = ((buildYomitanTermEntriesResponse(result, 0)['dictionaryEntries']
          as List).first as Map<String, dynamic>)['definitions'] as List;
      expect((def.first as Map)['entries'], ['to understand']);
    });

    test('null result yields empty dictionaryEntries', () {
      final out = buildYomitanTermEntriesResponse(null, 3);
      expect(out['index'], 3);
      expect(out['dictionaryEntries'], <dynamic>[]);
    });
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run（在 `hibiki/` 下）: `flutter test test/sync/yomitan_term_entries_adapter_test.dart`
Expected: FAIL —— `Target of URI doesn't exist: '.../yomitan_term_entries_adapter.dart'`。

- [ ] **Step 3: 写实现**

```dart
// hibiki/lib/src/sync/yomitan_term_entries_adapter.dart
import 'dart:convert';

import 'package:hibiki_dictionary/hibiki_dictionary.dart';

/// 把 Hibiki 查词结果包装成 Yomitan `termEntries` 顶层响应形状（宽松兼容）。
///
/// 形状对照 `Kuuuube/yomitan-api` 的 termEntries.md：
/// `{ index, dictionaryEntries: [...], originalTextLength }`。
/// 展示字段（term/reading/glossary/frequency/pitch/wordClasses）真实，
/// 内部字段（score/sequences/tags 元数据/...）填合理默认——Hibiki 在导入时
/// 已丢弃这些数据，运行期无法还原（见设计 §2.3）。
Map<String, dynamic> buildYomitanTermEntriesResponse(
  DictionarySearchResult? result,
  int index,
) {
  final List<Map<String, dynamic>> entries = <Map<String, dynamic>>[];
  if (result != null) {
    for (int i = 0; i < result.entries.length; i++) {
      entries.add(_buildDictionaryEntry(result.entries[i], i));
    }
  }
  return <String, dynamic>{
    'index': index,
    'dictionaryEntries': entries,
    'originalTextLength': result?.bestLength ?? 0,
  };
}

Map<String, dynamic> _buildDictionaryEntry(DictionaryEntry entry, int dictIndex) {
  final Map<String, dynamic> extra = _decodeExtra(entry.extra);
  final String matched = (extra['matched'] as String?) ?? entry.word;
  final String deinflected = (extra['deinflected'] as String?) ?? entry.word;
  final List<String> wordClasses = _splitTags(extra['definitionTags']);

  return <String, dynamic>{
    'type': 'term',
    'isPrimary': true,
    'textProcessorRuleChainCandidates': <List<String>>[<String>[]],
    'inflectionRuleChainCandidates': <Map<String, dynamic>>[
      <String, dynamic>{'source': 'algorithm', 'inflectionRules': <String>[]},
    ],
    'score': 0,
    'frequencyOrder': 0,
    'dictionaryIndex': dictIndex,
    'dictionaryAlias': entry.dictionaryName,
    'sourceTermExactMatchCount': 0,
    'matchPrimaryReading': false,
    'maxOriginalTextLength': matched.length,
    'headwords': <Map<String, dynamic>>[
      <String, dynamic>{
        'index': 0,
        'headwordIndex': 0,
        'term': entry.word,
        'reading': entry.reading,
        'sources': <Map<String, dynamic>>[
          <String, dynamic>{
            'originalText': matched,
            'transformedText': matched,
            'deinflectedText': deinflected,
            'matchType': 'exact',
            'matchSource': 'term',
            'isPrimary': true,
          },
        ],
        'tags': <dynamic>[],
        'wordClasses': wordClasses,
      },
    ],
    'definitions': <Map<String, dynamic>>[
      <String, dynamic>{
        'index': 0,
        'headwordIndices': <int>[0],
        'dictionary': entry.dictionaryName,
        'dictionaryIndex': dictIndex,
        'dictionaryAlias': entry.dictionaryName,
        'id': 0,
        'score': 0,
        'frequencyOrder': 0,
        'sequences': <int>[],
        'isPrimary': true,
        'tags': <dynamic>[],
        'entries': _glossaryEntries(entry.meaning),
      },
    ],
    'pronunciations': _pronunciations(extra['pitches']),
    'frequencies': _frequencies(extra['frequencies']),
  };
}

Map<String, dynamic> _decodeExtra(String extra) {
  try {
    final dynamic decoded = jsonDecode(extra);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } catch (_) {}
  return <String, dynamic>{};
}

List<String> _splitTags(dynamic tags) {
  if (tags is! String) return <String>[];
  return tags
      .split(RegExp(r'\s+'))
      .where((String s) => s.isNotEmpty)
      .toList(growable: false);
}

/// glossary：以 `[` 或 `{` 开头当 structured-content JSON 原样解析透传，否则当纯字符串。
List<dynamic> _glossaryEntries(String meaning) {
  final String trimmed = meaning.trimLeft();
  if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
    try {
      final dynamic decoded = jsonDecode(meaning);
      if (decoded is List) return decoded;
      return <dynamic>[decoded];
    } catch (_) {}
  }
  return <dynamic>[meaning];
}

List<Map<String, dynamic>> _frequencies(dynamic raw) {
  if (raw is! List) return <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
  int idx = 0;
  for (final dynamic dictEntry in raw) {
    if (dictEntry is! Map) continue;
    final String dict = dictEntry['dictName']?.toString() ?? '';
    final dynamic values = dictEntry['values'];
    if (values is! List) continue;
    for (final dynamic v in values) {
      if (v is! Map) continue;
      final dynamic display = v['display'];
      out.add(<String, dynamic>{
        'index': idx++,
        'headwordIndex': 0,
        'dictionary': dict,
        'dictionaryIndex': 0,
        'dictionaryAlias': dict,
        'hasReading': false,
        'frequencyMode': 'rank-based',
        'frequency': (v['value'] as num?)?.toInt() ?? 0,
        'displayValue': (display is String && display.isNotEmpty) ? display : null,
        'displayValueParsed': false,
      });
    }
  }
  return out;
}

List<Map<String, dynamic>> _pronunciations(dynamic raw) {
  if (raw is! List) return <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
  int idx = 0;
  for (final dynamic dictEntry in raw) {
    if (dictEntry is! Map) continue;
    final String dict = dictEntry['dictName']?.toString() ?? '';
    final dynamic positions = dictEntry['positions'];
    final List<int> pos = (positions is List)
        ? positions.whereType<num>().map((num n) => n.toInt()).toList()
        : <int>[];
    out.add(<String, dynamic>{
      'index': idx++,
      'headwordIndex': 0,
      'dictionary': dict,
      'dictionaryIndex': 0,
      'dictionaryAlias': dict,
      'pitches': pos
          .map((int p) => <String, dynamic>{'position': p, 'tags': <dynamic>[]})
          .toList(),
    });
  }
  return out;
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `flutter test test/sync/yomitan_term_entries_adapter_test.dart`
Expected: PASS（5 tests）。

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/sync/yomitan_term_entries_adapter.dart hibiki/test/sync/yomitan_term_entries_adapter_test.dart
git commit -m "feat(yomitan): add termEntries adapter (Hibiki result -> Yomitan shape)"
```

---

## Task 2: tokenize 适配器（纯函数）

把 `JapaneseLanguage.textToWords`（返回 `List<String>`，见 `japanese_language.dart:97`）的分词结果包装成 yomitan-api `tokenize` 形状。

**真实形状（核对 `yomitan-api/docs/api_paths/tokenize.md`）**：`content` 是**二维数组**——每个分词段包在自己的 list 里 `content: [[{text,reading}], [{text,reading}], ...]`；顶层 `id:"scan"`、`source:<parser>`、`dictionary:null`、`index`。每段首元素可带精简 `headwords`，但文档明确「无匹配时省略 headwords」，故本版**合法省略 headwords**（宽松取舍，后续可增强）。读音用对该段的 `lookup` 取首条 reading（命中才带，否则空串）。

**Files:**
- Create: `hibiki/lib/src/sync/yomitan_tokenize_adapter.dart`
- Test: `hibiki/test/sync/yomitan_tokenize_adapter_test.dart`

- [ ] **Step 1: 写失败测试**

```dart
// hibiki/test/sync/yomitan_tokenize_adapter_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/yomitan_tokenize_adapter.dart';

void main() {
  group('buildYomitanTokenizeResponse', () {
    test('wraps each segment in its own array (yomitan 2D content)', () {
      // tokenizer 注入为纯函数依赖，避免依赖 FFI 引擎
      List<String> fakeTokenizer(String t) => ['日本語', 'は', '難しい'];
      String fakeReading(String w) => w == '日本語' ? 'にほんご' : '';

      final out = buildYomitanTokenizeResponse(
        text: '日本語は難しい',
        index: 0,
        tokenize: fakeTokenizer,
        readingOf: fakeReading,
      );

      expect(out['id'], 'scan');
      expect(out['source'], 'scanning-parser');
      expect(out['dictionary'], isNull);
      expect(out['index'], 0);

      final content = out['content'] as List;
      expect(content.length, 3);
      final firstSeg = content[0] as List; // 每段是自己的数组
      expect(firstSeg.length, 1);
      expect((firstSeg[0] as Map)['text'], '日本語');
      expect((firstSeg[0] as Map)['reading'], 'にほんご');
      expect(((content[1] as List)[0] as Map)['reading'], ''); // 未命中空读音
    });

    test('empty text yields empty content', () {
      final out = buildYomitanTokenizeResponse(
        text: '',
        index: 2,
        tokenize: (String t) => <String>[],
        readingOf: (String w) => '',
      );
      expect(out['index'], 2);
      expect(out['content'], <dynamic>[]);
    });
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test test/sync/yomitan_tokenize_adapter_test.dart`
Expected: FAIL —— URI 不存在。

- [ ] **Step 3: 写实现**

```dart
// hibiki/lib/src/sync/yomitan_tokenize_adapter.dart

/// 分词函数类型：文本 -> 词片段列表（对接 JapaneseLanguage.textToWords）。
typedef Tokenizer = List<String> Function(String text);

/// 读音解析函数类型：词 -> 读音（命中返回假名，未命中返回空串）。
typedef ReadingResolver = String Function(String word);

/// 把分词结果包装成 yomitan-api `tokenize` 单条响应形状。
/// 形状：`{ id:"scan", source:<parser>, dictionary:null, index,
/// content: [[{text, reading}], ...] }`（content 二维：每段一个数组）。
/// headwords（首段精简词条）按文档可省略，本版省略（宽松取舍）。
Map<String, dynamic> buildYomitanTokenizeResponse({
  required String text,
  required int index,
  required Tokenizer tokenize,
  required ReadingResolver readingOf,
  String parser = 'scanning-parser',
}) {
  final List<List<Map<String, dynamic>>> content =
      <List<Map<String, dynamic>>>[];
  if (text.isNotEmpty) {
    for (final String seg in tokenize(text)) {
      content.add(<Map<String, dynamic>>[
        <String, dynamic>{'text': seg, 'reading': readingOf(seg)},
      ]);
    }
  }
  return <String, dynamic>{
    'id': 'scan',
    'source': parser,
    'dictionary': null,
    'index': index,
    'content': content,
  };
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `flutter test test/sync/yomitan_tokenize_adapter_test.dart`
Expected: PASS（2 tests）。

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/sync/yomitan_tokenize_adapter.dart hibiki/test/sync/yomitan_tokenize_adapter_test.dart
git commit -m "feat(yomitan): add tokenize adapter"
```

---

## Task 3: YomitanApiServer（shelf，4 端点 + 鉴权 + 端口）

独立 shelf server，仿 `HibikiSyncServer` 的 start/stop/端口占用范式（`hibiki_sync_server.dart:104-126`、`isAddressInUseError`），但端点是 yomitan-api 协议。复用已存在的 `HibikiRemoteLookupService`（`hibiki_remote_lookup_service.dart:5`）查词。

**Files:**
- Create: `hibiki/lib/src/sync/yomitan_api_server.dart`
- Test: `hibiki/test/sync/yomitan_api_server_test.dart`

- [ ] **Step 1: 写失败测试**

```dart
// hibiki/test/sync/yomitan_api_server_test.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/src/sync/yomitan_api_server.dart';

class _FakeLookup implements HibikiRemoteLookupService {
  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async {
    if (term == 'わかる') {
      return DictionarySearchResult(
        searchTerm: term,
        entries: [
          DictionaryEntry(
            dictionaryName: 'Jitendex',
            word: '分かる',
            reading: 'わかる',
            meaning: 'to understand',
            extra: jsonEncode({'matched': 'わかる', 'deinflected': 'わかる'}),
            popularity: 0,
          ),
        ],
        bestLength: 3,
      );
    }
    return null;
  }

  @override
  Future<RemoteAudioLookup?> lookupAudio(
          {required String expression, required String reading}) async =>
      null;
}

Future<HttpClientResponse> _post(int port, String path, Object? body,
    {String? apiKey}) async {
  final client = HttpClient();
  final req = await client.post('127.0.0.1', port, path);
  req.headers.contentType = ContentType.json;
  if (apiKey != null) req.headers.set('X-API-Key', apiKey);
  if (body != null) req.write(jsonEncode(body));
  return req.close();
}

void main() {
  late YomitanApiServer server;
  const int port = 19733; // 测试端口，避开默认 19633

  tearDown(() async => server.stop());

  test('termEntries returns Yomitan shape', () async {
    server = YomitanApiServer(
        port: port, lookupService: _FakeLookup(), tokenizer: (t) => [t],
        readingResolver: (w) => '');
    await server.start();

    final resp = await _post(port, '/termEntries', {'term': 'わかる'});
    expect(resp.statusCode, 200);
    final body = jsonDecode(await resp.transform(utf8.decoder).join());
    expect(body['index'], 0);
    final de = (body['dictionaryEntries'] as List).first;
    expect((de['headwords'] as List).first['term'], '分かる');
  });

  test('termEntries with array term returns array', () async {
    server = YomitanApiServer(
        port: port, lookupService: _FakeLookup(), tokenizer: (t) => [t],
        readingResolver: (w) => '');
    await server.start();

    final resp = await _post(port, '/termEntries', {'term': ['わかる', 'xxx']});
    final body = jsonDecode(await resp.transform(utf8.decoder).join());
    expect(body, isA<List>());
    expect((body as List).length, 2);
    expect(body[1]['dictionaryEntries'], <dynamic>[]); // 未命中空
  });

  test('serverVersion is constant', () async {
    server = YomitanApiServer(
        port: port, lookupService: _FakeLookup(), tokenizer: (t) => [t],
        readingResolver: (w) => '');
    await server.start();
    final resp = await _post(port, '/serverVersion', null);
    final body = jsonDecode(await resp.transform(utf8.decoder).join());
    expect(body['version'], 1);
  });

  test('GET method rejected with 405', () async {
    server = YomitanApiServer(
        port: port, lookupService: _FakeLookup(), tokenizer: (t) => [t],
        readingResolver: (w) => '');
    await server.start();
    final client = HttpClient();
    final req = await client.get('127.0.0.1', port, '/termEntries');
    final resp = await req.close();
    expect(resp.statusCode, 405);
  });

  test('api key enforced when set', () async {
    server = YomitanApiServer(
        port: port, lookupService: _FakeLookup(), apiKey: 'secret',
        tokenizer: (t) => [t], readingResolver: (w) => '');
    await server.start();

    final noKey = await _post(port, '/termEntries', {'term': 'わかる'});
    expect(noKey.statusCode, 401);

    final withKey = await _post(port, '/termEntries', {'term': 'わかる'},
        apiKey: 'secret');
    expect(withKey.statusCode, 200);
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test test/sync/yomitan_api_server_test.dart`
Expected: FAIL —— URI 不存在。

- [ ] **Step 3: 写实现**

```dart
// hibiki/lib/src/sync/yomitan_api_server.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'hibiki_remote_lookup_service.dart';
import 'hibiki_sync_server.dart' show SyncServerPortInUseException, isAddressInUseError;
import 'yomitan_term_entries_adapter.dart';
import 'yomitan_tokenize_adapter.dart';

/// yomitan-api 默认端口（Kuuuube/yomitan-api）。
const int kYomitanApiDefaultPort = 19633;

/// 兼容 `Kuuuube/yomitan-api` 的独立 HTTP server（宽松兼容）。
/// 只接受 POST；可选 X-API-Key 鉴权；端点 serverVersion/yomitanVersion/
/// termEntries/tokenize。查词复用 [HibikiRemoteLookupService]。
class YomitanApiServer {
  YomitanApiServer({
    required int port,
    required HibikiRemoteLookupService lookupService,
    required Tokenizer tokenizer,
    required ReadingResolver readingResolver,
    String? apiKey,
    bool allowLan = false,
  })  : _requestedPort = port,
        _lookup = lookupService,
        _tokenizer = tokenizer,
        _readingResolver = readingResolver,
        _apiKey = apiKey,
        _allowLan = allowLan;

  final int _requestedPort;
  final HibikiRemoteLookupService _lookup;
  final Tokenizer _tokenizer;
  final ReadingResolver _readingResolver;
  final String? _apiKey;
  final bool _allowLan;

  HttpServer? _server;

  bool get isRunning => _server != null;
  int get port => _server?.port ?? _requestedPort;

  Future<void> start() async {
    if (_server != null) return;
    final shelf.Handler handler = const shelf.Pipeline()
        .addMiddleware(_authMiddleware())
        .addHandler(_handleRequest);
    try {
      _server = await shelf_io.serve(
        handler,
        _allowLan ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4,
        _requestedPort,
      );
    } on SocketException catch (e) {
      if (isAddressInUseError(e)) {
        throw SyncServerPortInUseException(_requestedPort);
      }
      rethrow;
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  shelf.Middleware _authMiddleware() {
    return (shelf.Handler inner) {
      return (shelf.Request request) {
        final String? key = _apiKey;
        if (key == null || key.isEmpty) return inner(request);
        final String? provided = request.headers['x-api-key'];
        if (provided != key) {
          return shelf.Response(401, body: 'Unauthorized');
        }
        return inner(request);
      };
    };
  }

  Future<shelf.Response> _handleRequest(shelf.Request request) async {
    if (request.method.toUpperCase() != 'POST') {
      return shelf.Response(405, body: 'Method Not Allowed');
    }
    final String path = '/${request.url.path}';
    switch (path) {
      case '/serverVersion':
        return _json(<String, dynamic>{'version': 1});
      case '/yomitanVersion':
        return _json(<String, dynamic>{'version': '0.0.0.0'});
      case '/termEntries':
        return _handleTermEntries(request);
      case '/tokenize':
        return _handleTokenize(request);
      default:
        return shelf.Response.notFound('Unknown endpoint');
    }
  }

  Future<shelf.Response> _handleTermEntries(shelf.Request request) async {
    final Map<String, dynamic>? body = await _readJson(request);
    final dynamic term = body?['term'];
    if (term is List) {
      final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
      for (int i = 0; i < term.length; i++) {
        out.add(await _termEntriesFor(term[i]?.toString() ?? '', i));
      }
      return _jsonRaw(jsonEncode(out));
    }
    return _json(await _termEntriesFor(term?.toString() ?? '', 0));
  }

  Future<Map<String, dynamic>> _termEntriesFor(String term, int index) async {
    if (term.trim().isEmpty) {
      return buildYomitanTermEntriesResponse(null, index);
    }
    final result = await _lookup.searchDictionary(
      term: term, wildcards: false, maximumTerms: 10);
    return buildYomitanTermEntriesResponse(result, index);
  }

  Future<shelf.Response> _handleTokenize(shelf.Request request) async {
    final Map<String, dynamic>? body = await _readJson(request);
    final dynamic text = body?['text'];
    if (text is List) {
      final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
      for (int i = 0; i < text.length; i++) {
        out.add(buildYomitanTokenizeResponse(
          text: text[i]?.toString() ?? '',
          index: i,
          tokenize: _tokenizer,
          readingOf: _readingResolver,
        ));
      }
      return _jsonRaw(jsonEncode(out));
    }
    return _json(buildYomitanTokenizeResponse(
      text: text?.toString() ?? '',
      index: 0,
      tokenize: _tokenizer,
      readingOf: _readingResolver,
    ));
  }

  Future<Map<String, dynamic>?> _readJson(shelf.Request request) async {
    try {
      final String raw = await request.readAsString();
      if (raw.isEmpty) return null;
      final dynamic decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  shelf.Response _json(Object body) => _jsonRaw(jsonEncode(body));

  shelf.Response _jsonRaw(String body) => shelf.Response.ok(
        body,
        headers: <String, String>{'Content-Type': 'application/json; charset=utf-8'},
      );
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `flutter test test/sync/yomitan_api_server_test.dart`
Expected: PASS（5 tests）。

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/sync/yomitan_api_server.dart hibiki/test/sync/yomitan_api_server_test.dart
git commit -m "feat(yomitan): add yomitan-api compatible HTTP server"
```

---

## Task 4: 偏好开关（enabled / port / apiKey）

仿 `remote_lookup_enabled` 范式（`preferences_repository.dart:117-123` + `app_model.dart:2484-2486`）。

**Files:**
- Modify: `hibiki/lib/src/models/preferences_repository.dart`
- Modify: `hibiki/lib/src/models/app_model.dart`
- Test: `hibiki/test/models/preferences_repository_test.dart`（追加用例）

- [ ] **Step 1: 写失败测试**（追加到现有 `preferences_repository_test.dart`，仿其现有用例风格）

```dart
  test('yomitan api server prefs round-trip', () async {
    expect(repo.yomitanApiServerEnabled, false);
    expect(repo.yomitanApiPort, 19633);
    expect(repo.yomitanApiKey, '');

    await repo.setYomitanApiServerEnabled(true);
    await repo.setYomitanApiPort(19999);
    await repo.setYomitanApiKey('k');

    expect(repo.yomitanApiServerEnabled, true);
    expect(repo.yomitanApiPort, 19999);
    expect(repo.yomitanApiKey, 'k');
  });
```

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test test/models/preferences_repository_test.dart`
Expected: FAIL —— `getter yomitanApiServerEnabled isn't defined`。

- [ ] **Step 3: 写实现**

在 `preferences_repository.dart`（remote_lookup getter 之后，约 line 123 之后）加：

```dart
  bool get yomitanApiServerEnabled =>
      getPref('yomitan_api_server_enabled', defaultValue: false) as bool;

  Future<void> setYomitanApiServerEnabled(bool value) async {
    await setPref('yomitan_api_server_enabled', value);
    notifyListeners();
  }

  int get yomitanApiPort =>
      getPref('yomitan_api_port', defaultValue: 19633) as int;

  Future<void> setYomitanApiPort(int value) async {
    await setPref('yomitan_api_port', value);
    notifyListeners();
  }

  String get yomitanApiKey =>
      getPref('yomitan_api_key', defaultValue: '') as String;

  Future<void> setYomitanApiKey(String value) async {
    await setPref('yomitan_api_key', value);
    notifyListeners();
  }
```

在 `app_model.dart`（remote lookup 转发之后，约 line 2486）加：

```dart
  bool get yomitanApiServerEnabled => prefsRepo.yomitanApiServerEnabled;
  Future<void> setYomitanApiServerEnabled(bool value) =>
      prefsRepo.setYomitanApiServerEnabled(value);

  int get yomitanApiPort => prefsRepo.yomitanApiPort;
  Future<void> setYomitanApiPort(int value) => prefsRepo.setYomitanApiPort(value);

  String get yomitanApiKey => prefsRepo.yomitanApiKey;
  Future<void> setYomitanApiKey(String value) => prefsRepo.setYomitanApiKey(value);
```

- [ ] **Step 4: 运行测试确认通过**

Run: `flutter test test/models/preferences_repository_test.dart`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/models/preferences_repository.dart hibiki/lib/src/models/app_model.dart hibiki/test/models/preferences_repository_test.dart
git commit -m "feat(yomitan): add yomitan-api server prefs (enabled/port/key)"
```

---

## Task 5: server 生命周期管理（按开关启停）

新增一个轻量管理器持有 `YomitanApiServer` 实例，监听 `yomitanApiServerEnabled` 偏好开关启停。tokenizer/readingResolver 注入自 `JapaneseLanguage`（经 `HoshiDicts`）。

**Files:**
- Create: `hibiki/lib/src/sync/yomitan_api_server_manager.dart`
- Test: `hibiki/test/sync/yomitan_api_server_manager_test.dart`

- [ ] **Step 1: 写失败测试**

```dart
// hibiki/test/sync/yomitan_api_server_manager_test.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/src/sync/yomitan_api_server_manager.dart';

class _FakeLookup implements HibikiRemoteLookupService {
  @override
  Future<DictionarySearchResult?> searchDictionary(
          {required String term,
          required bool wildcards,
          required int maximumTerms}) async =>
      null;
  @override
  Future<RemoteAudioLookup?> lookupAudio(
          {required String expression, required String reading}) async =>
      null;
}

void main() {
  test('start then stop toggles isRunning and frees port', () async {
    final mgr = YomitanApiServerManager(
      lookupService: _FakeLookup(),
      tokenizer: (t) => [t],
      readingResolver: (w) => '',
    );

    await mgr.start(port: 19744, apiKey: '');
    expect(mgr.isRunning, true);

    // loopback 通：serverVersion 应答
    final client = HttpClient();
    final req = await client.post('127.0.0.1', 19744, '/serverVersion');
    final resp = await req.close();
    expect(resp.statusCode, 200);
    final body = jsonDecode(await resp.transform(utf8.decoder).join());
    expect(body['version'], 1);

    await mgr.stop();
    expect(mgr.isRunning, false);
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test test/sync/yomitan_api_server_manager_test.dart`
Expected: FAIL —— URI 不存在。

- [ ] **Step 3: 写实现**

```dart
// hibiki/lib/src/sync/yomitan_api_server_manager.dart
import 'hibiki_remote_lookup_service.dart';
import 'yomitan_api_server.dart';
import 'yomitan_tokenize_adapter.dart';

/// 持有并按需启停 [YomitanApiServer]。tokenizer/readingResolver 注入解耦 FFI。
class YomitanApiServerManager {
  YomitanApiServerManager({
    required HibikiRemoteLookupService lookupService,
    required Tokenizer tokenizer,
    required ReadingResolver readingResolver,
  })  : _lookup = lookupService,
        _tokenizer = tokenizer,
        _readingResolver = readingResolver;

  final HibikiRemoteLookupService _lookup;
  final Tokenizer _tokenizer;
  final ReadingResolver _readingResolver;

  YomitanApiServer? _server;

  bool get isRunning => _server?.isRunning ?? false;
  int? get port => _server?.port;

  Future<void> start({required int port, required String apiKey}) async {
    if (_server != null) return;
    final YomitanApiServer server = YomitanApiServer(
      port: port,
      lookupService: _lookup,
      tokenizer: _tokenizer,
      readingResolver: _readingResolver,
      apiKey: apiKey.isEmpty ? null : apiKey,
      allowLan: true,
    );
    await server.start();
    _server = server;
  }

  Future<void> stop() async {
    await _server?.stop();
    _server = null;
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `flutter test test/sync/yomitan_api_server_manager_test.dart`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/sync/yomitan_api_server_manager.dart hibiki/test/sync/yomitan_api_server_manager_test.dart
git commit -m "feat(yomitan): add server lifecycle manager"
```

---

## Task 6: 设置 UI + i18n + 接线启停

在设置里加开关/端口/key，开关打开时经 `YomitanApiServerManager` 启动。tokenizer 用 `JapaneseLanguage().textToWords`，readingResolver 用 `HoshiDicts.instance.lookup(w, maxResults:1)` 取首条 reading（命中才返回）。接线位置仿 `sync_settings_schema.dart:1903` 的 `_startServer`。

**Files:**
- Modify: `hibiki/lib/src/settings/settings_schema.dart`（加 SettingsSwitchItem + 端口/key 行）
- Modify: `hibiki/lib/i18n/*.i18n.json`（经工具）
- Modify: server 接线（设置页 stateful host，仿 sync_settings_schema 的 server 持有 + _startServer/_stopServer 范式；若 yomitan 设置嵌在同一设置 section，复用其 State）

- [ ] **Step 1: 加 i18n key**（在 `hibiki/` 目录运行）

Run:
```bash
dart tool/i18n_sync.dart --add yomitan_api_server "Yomitan API server" "Yomitan API 服务器"
dart tool/i18n_sync.dart --add yomitan_api_server_hint "Let yomitan-api clients query Hibiki's dictionaries (port 19633)" "让 yomitan-api 客户端查询 Hibiki 词典（端口 19633）"
dart tool/i18n_sync.dart --add yomitan_api_port "Yomitan API port" "Yomitan API 端口"
dart tool/i18n_sync.dart --add yomitan_api_key "Yomitan API key (optional)" "Yomitan API 密钥（可选）"
dart run slang
dart format lib/i18n/strings.g.dart
```
Expected: 17 个 json 各加 4 个 key；`strings.g.dart` 重新生成。

- [ ] **Step 2: 写 settings_schema switch 条目**

在 `settings_schema.dart` 合适 section（仿 line 865-876 的 `SettingsSwitchItem`）加：

```dart
SettingsSwitchItem(
  id: 'sync.yomitan_api_server',
  title: t.yomitan_api_server,
  subtitle: t.yomitan_api_server_hint,
  icon: Icons.hub_outlined,
  value: (SettingsContext c) => c.appModel.yomitanApiServerEnabled,
  onChanged: (SettingsContext c, bool value) async {
    await c.appModel.setYomitanApiServerEnabled(value);
    if (value) {
      await c.appModel.startYomitanApiServer();
    } else {
      await c.appModel.stopYomitanApiServer();
    }
    c.refresh();
  },
),
```

- [ ] **Step 3: 接线启停（AppModel 持有 manager）**

server 生命周期挂在 `AppModel`（全局状态拥有者，能拿到 `createRemoteLookupService` + `JapaneseLanguage` + `HoshiDicts`），不放进 settings State——比 sync server 简单，无 LAN 配对/广播等复杂状态。在 `app_model.dart` 加：

```dart
  YomitanApiServerManager? _yomitanServerManager;

  YomitanApiServerManager _ensureYomitanManager() {
    return _yomitanServerManager ??= YomitanApiServerManager(
      lookupService: createRemoteLookupService(),
      tokenizer: JapaneseLanguage().textToWords,
      readingResolver: (String w) {
        if (!HoshiDicts.isInitialized) return '';
        final List<HoshiLookupResult> r =
            HoshiDicts.instance.lookup(w, maxResults: 1);
        return r.isEmpty ? '' : r.first.term.reading;
      },
    );
  }

  Future<void> startYomitanApiServer() async {
    try {
      await _ensureYomitanManager()
          .start(port: yomitanApiPort, apiKey: yomitanApiKey);
    } on SyncServerPortInUseException {
      // 端口占用：回滚开关，避免卡在"已开但没起来"。
      await setYomitanApiServerEnabled(false);
      rethrow; // 让设置 UI 能 toast 提示（onChanged 外层可 catch 显示）
    }
  }

  Future<void> stopYomitanApiServer() async {
    await _yomitanServerManager?.stop();
  }
```

import 所需类型：`YomitanApiServerManager`、`SyncServerPortInUseException`、`JapaneseLanguage`/`HoshiDicts`/`HoshiLookupResult`（后三者来自 `package:hibiki_dictionary/hibiki_dictionary.dart`，AppModel 应已 import）。onChanged 外层可按现有设置 toast 范式 catch `SyncServerPortInUseException` 提示端口占用（与 sync server 的 `t.sync_server_port_in_use` 同款，可复用该 i18n key）。

- [ ] **Step 4: 开机自启**

在 AppModel 初始化流程**尾部**（词典引擎初始化之后、与其它子系统启动同级处；找现有初始化收尾位置，仿已有"启动时按偏好恢复"的写法）加：

```dart
    if (yomitanApiServerEnabled) {
      // server 可先起；查词/读音在引擎未就绪时各自降级为空，不阻塞启动。
      unawaited(startYomitanApiServer().catchError((Object _) {}));
    }
```

（`unawaited` 来自 `dart:async`；若 AppModel 初始化已是 async 且适合 await，也可 `await`，但不要让端口占用异常中断整个 app 初始化——故 catchError 吞掉，开关回滚已在 `startYomitanApiServer` 内处理。）

- [ ] **Step 5: 端口/API key 编辑 UI（按现有控件能力裁量）**

先查 `settings_destination.dart` 有没有可编辑文本/数字的 schema 项类型（如 `SettingsTextItem`/`SettingsTextFieldItem` 之类）：
- **有** → 在开关下加两行：端口（数字，写 `setYomitanApiPort`）+ API key（文本，写 `setYomitanApiKey`），改完若 server 正在跑则 `stop`+`start` 重启生效。i18n 用 Step 1 的 `yomitan_api_port`/`yomitan_api_key`。
- **没有现成可编辑项类型** → 本版只做开关，端口/key 走偏好默认值（19633/空），在报告里说明端口/key 编辑 UI 留作后续（不要为这个新造 schema 控件类型，避免 over-build）。

- [ ] **Step 6: 验证**

Run（在 `hibiki/`）: `dart format . && flutter analyze && flutter test test/sync/ test/models/preferences_repository_test.dart`
Expected: analyze 0 issues；相关测试全绿。

- [ ] **Step 7: 提交**

```bash
git add hibiki/lib/src/settings/settings_schema.dart hibiki/lib/i18n/ hibiki/lib/src/models/app_model.dart hibiki/lib/src/sync/
git commit -m "feat(yomitan): wire yomitan-api server settings + lifecycle"
```

---

## Self-Review 结论

- **Spec 覆盖**：§6.1 独立 server（Task 3/5/6）、§6.2 适配器宽松兼容（Task 1）、§6.3 端点 serverVersion/yomitanVersion/termEntries/tokenize（Task 1/2/3）、§7 开关 i18n（Task 4/6）、§9 测试（各 Task 测试 + loopback Task 5）。kanjiEntries/ankiFields 按非目标不实现，符合 spec。
- **占位符扫描**：无 TBD；每个新文件给完整实现；接入点给精确范式引用 + 代码。
- **类型一致**：`buildYomitanTermEntriesResponse(DictionarySearchResult?, int)`、`buildYomitanTokenizeResponse({text,index,tokenize,readingOf})`、`Tokenizer`/`ReadingResolver` typedef、`YomitanApiServer` 构造参数、`YomitanApiServerManager.start({port,apiKey})` 在各 Task 间一致。
- **复用真实签名**：`HibikiRemoteLookupService.searchDictionary`、`isAddressInUseError`/`SyncServerPortInUseException`、`JapaneseLanguage.textToWords`、`HoshiDicts.instance.lookup` 均为已验证的真实签名。
