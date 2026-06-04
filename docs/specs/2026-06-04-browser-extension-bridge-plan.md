# Hibiki 浏览器查词桥 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 做一个极薄的浏览器扩展，Shift 悬停网页取词 → 查 Hibiki 词典 → 弹同款弹窗 → 挖词进 Anki，查词历史并入 Hibiki。

**Architecture:** 扩展当前端、Hibiki 已有本地 HTTP 服务器（`HibikiSyncServer`，shelf）当后端。查词复用已存在的 `POST /api/lookup/dictionary`（已返回 `popupJson`）；历史给该接口加 `record` 开关；挖词新增 `POST /api/mine` + 一个 mining seam。弹窗渲染把 Hibiki 的 `popup.js`/`popup.css` 原样打进扩展，在 Shadow DOM 里渲染服务器返回的 popup JSON，`popup.js` 里的 `flutter_inappwebview.callHandler` 用一个 bridge-shim 接管。

**Tech Stack:** Dart（shelf 服务器 + Riverpod app）、Flutter test（HttpClient 驱动）、浏览器扩展 Manifest V3（vanilla JS + chrome.storage + service worker）。

**设计依据：** `docs/specs/2026-06-04-browser-extension-bridge-design.md`（含 §11 弹窗渲染核实结论）。

**关键约束：**
- 本计划在 worktree 分支 `feature/browser-extension-bridge` 上执行；功能后续才推出。
- 执行前先 `git merge develop`（或 rebase）同步并发改动——`hibiki_sync_server.dart` 一直在被并发 agent 改。
- Hibiki 验证命令（worktree 的 `hibiki/` 下）：`dart format .` + `flutter test`（项目 Flutter 3.44.0 工具链）。
- 扩展依赖 Hibiki 正在运行且开启「Hibiki 互联」服务器；扩展只配 localhost。

---

## 文件结构

**Hibiki 侧（Dart）**
- 修改 `hibiki/lib/src/sync/hibiki_remote_lookup_service.dart` — `searchDictionary` 加 `bool record`。
- 修改 `hibiki/lib/src/models/app_model.dart` — `_AppModelRemoteLookupService.searchDictionary` 实现 `record` 写历史；新增 `_AppModelRemoteMiningService` + `createRemoteMiningService()`。
- 新建 `hibiki/lib/src/sync/hibiki_remote_mining_service.dart` — mining seam 抽象接口（不引入 hibiki_anki 类型，返回 `MineResult.name` 字符串）。
- 修改 `hibiki/lib/src/sync/hibiki_sync_server.dart` — 构造函数加 `remoteMiningService`；`_handleDictionaryLookup` 读 `record`；新增 `_handleMine` + 路由分支。
- 修改 `hibiki/lib/src/sync/sync_settings_schema.dart:1952` — 构造 server 时注入 `remoteMiningService`。
- 修改 `hibiki/test/sync/hibiki_sync_server_test.dart` — fake 加 `record`；新增 mining 测试 + fake mining service。

**浏览器扩展（新目录 `tools/browser-extension/`）**
- `manifest.json` — MV3 清单。
- `background.js` — service worker，集中发带鉴权的 fetch（绕页面 CSP），接 content 消息。
- `content.js` — 取词扫描 + Shadow DOM 挂载 + 弹窗渲染编排。
- `bridge-shim.js` — 接管 popup.js 的 `flutter_inappwebview.callHandler`。
- `options.html` / `options.js` — 配置 host/port/token/修饰键。
- `vendor/`（从 `hibiki/assets/popup/` 同步）— `popup.js` / `popup.css` / `popup.html` / `dict-media.js` / `selection.js`。
- `vendor/sync.md` — 记录 vendor 来源 commit，便于以后同步。

---

## Part 1 — Hibiki 服务器侧（Dart, TDD）

### Task 1: 查词接口加 `record` 开关写历史

**Files:**
- Modify: `hibiki/lib/src/sync/hibiki_remote_lookup_service.dart:5`
- Modify: `hibiki/lib/src/models/app_model.dart:2799`（`_AppModelRemoteLookupService.searchDictionary`）
- Modify: `hibiki/lib/src/sync/hibiki_sync_server.dart:267`（`_handleDictionaryLookup`）
- Test: `hibiki/test/sync/hibiki_sync_server_test.dart`

- [ ] **Step 1: 先更新现有测试的 fake 签名（否则编译失败），并加新失败测试**

在 `hibiki/test/sync/hibiki_sync_server_test.dart` 里，把现有 `_FakeRemoteLookupService.searchDictionary` 改成带 `record`，并记录收到的 `record`：

```dart
class _FakeRemoteLookupService implements HibikiRemoteLookupService {
  bool lastRecord = false;
  int recordedHistoryCalls = 0;

  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
    bool record = false,
  }) async {
    lastRecord = record;
    if (record) recordedHistoryCalls++;
    final result = DictionarySearchResult(
      searchTerm: term,
      entries: <DictionaryEntry>[
        DictionaryEntry(
          dictionaryName: 'remote', word: term,
          reading: 'ねこ', meaning: 'remote meaning'),
      ],
    );
    result.popupJson = '{"source":"remote-popup"}';
    return result;
  }

  @override
  Future<RemoteAudioLookup?> lookupAudio({
    required String expression, required String reading}) async =>
      RemoteAudioLookup(
        bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
        contentType: 'audio/mpeg');
}
```

新增测试（放进现有 `group('HibikiSyncServer', ...)`，server 用现有 setUp 起的 `server` + `token`，fake 命名 `fakeLookup`——若现有 setUp 没把 fake 存成变量，先把 `remoteLookupService: _FakeRemoteLookupService()` 改成存到 `late _FakeRemoteLookupService fakeLookup;` 再注入）：

```dart
test('dictionary lookup forwards record=true to the lookup service', () async {
  final client = HttpClient();
  final request = await client.postUrl(Uri.parse(
    'http://localhost:${server.port}/api/lookup/dictionary'));
  request.headers
    ..set('Authorization', 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}')
    ..contentType = ContentType.json;
  request.add(utf8.encode(jsonEncode(<String, dynamic>{
    'term': '猫', 'wildcards': false, 'maximumTerms': 3, 'record': true,
  })));
  final response = await request.close();
  await response.drain<void>();
  client.close();

  expect(response.statusCode, 200);
  expect(fakeLookup.lastRecord, isTrue);
});

test('dictionary lookup defaults record to false', () async {
  final client = HttpClient();
  final request = await client.postUrl(Uri.parse(
    'http://localhost:${server.port}/api/lookup/dictionary'));
  request.headers
    ..set('Authorization', 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}')
    ..contentType = ContentType.json;
  request.add(utf8.encode(jsonEncode(<String, dynamic>{'term': '猫'})));
  final response = await request.close();
  await response.drain<void>();
  client.close();

  expect(response.statusCode, 200);
  expect(fakeLookup.lastRecord, isFalse);
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd hibiki && flutter test test/sync/hibiki_sync_server_test.dart`
Expected: 编译失败或断言失败——接口 `searchDictionary` 还没有 `record` 参数 / 路由还没读 `record`。

- [ ] **Step 3: 接口加 `record` 参数**

`hibiki/lib/src/sync/hibiki_remote_lookup_service.dart:5`：

```dart
abstract class HibikiRemoteLookupService {
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
    bool record = false,
  });
  Future<RemoteAudioLookup?> lookupAudio({
    required String expression, required String reading});
}
```

- [ ] **Step 4: 具体实现写历史**

`hibiki/lib/src/models/app_model.dart:2799`，`_AppModelRemoteLookupService.searchDictionary` 改为：

```dart
@override
Future<DictionarySearchResult?> searchDictionary({
  required String term,
  required bool wildcards,
  required int maximumTerms,
  bool record = false,
}) async {
  final DictionarySearchResult result = await _appModel.searchDictionary(
    searchTerm: term,
    searchWithWildcards: wildcards,
    overrideMaximumTerms: maximumTerms,
    useCache: false,
    allowRemoteLookup: false,
  );
  if (result.entries.isEmpty) return null;
  if (record) {
    _appModel.addToSearchHistory(
      historyKey: DictionaryMediaType.instance.uniqueKey,
      searchTerm: term,
    );
    _appModel.addToDictionaryHistory(result: result);
  }
  return result;
}
```

确认 `app_model.dart` 顶部已 import `DictionaryMediaType` 所在文件（dictionary media type 定义处）；若未 import 则补上。

- [ ] **Step 5: 路由读 `record` 并透传**

`hibiki/lib/src/sync/hibiki_sync_server.dart:267` `_handleDictionaryLookup`，在解析 `maximumTerms` 后加一行并把它传进 `searchDictionary`：

```dart
final bool wildcards = body['wildcards'] as bool? ?? false;
final int maximumTerms = (body['maximumTerms'] as num?)?.toInt() ?? 10;
final bool record = body['record'] as bool? ?? false;
final result = await service.searchDictionary(
  term: term, wildcards: wildcards, maximumTerms: maximumTerms, record: record);
```

- [ ] **Step 6: 跑测试确认通过**

Run: `cd hibiki && flutter test test/sync/hibiki_sync_server_test.dart`
Expected: PASS（含原有 lookup 测试 + 两个新 record 测试）。

- [ ] **Step 7: 提交**

```bash
git add hibiki/lib/src/sync/hibiki_remote_lookup_service.dart \
        hibiki/lib/src/models/app_model.dart \
        hibiki/lib/src/sync/hibiki_sync_server.dart \
        hibiki/test/sync/hibiki_sync_server_test.dart
git commit -m "feat(sync): dictionary lookup API can record search/dictionary history (record flag)"
```

---

### Task 2: 新增 `POST /api/mine` 挖词路由 + mining seam

**Files:**
- Create: `hibiki/lib/src/sync/hibiki_remote_mining_service.dart`
- Modify: `hibiki/lib/src/models/app_model.dart`（新增 `createRemoteMiningService()` + `_AppModelRemoteMiningService`）
- Modify: `hibiki/lib/src/sync/hibiki_sync_server.dart`（字段 + 构造参数 + 路由 + `_handleMine`）
- Modify: `hibiki/lib/src/sync/sync_settings_schema.dart:1952`
- Test: `hibiki/test/sync/hibiki_sync_server_test.dart`

- [ ] **Step 1: 写失败测试（mining 路由）**

在 `hibiki_sync_server_test.dart` 顶部加一个 fake mining service（放文件末尾与 `_FakeRemoteLookupService` 并列）：

```dart
class _FakeRemoteMiningService implements HibikiRemoteMiningService {
  String? lastPayloadJson;
  String? lastSentence;
  String resultToReturn = 'success';

  @override
  Future<String> mineEntry({
    required String rawPayloadJson,
    required String sentence,
    String? cueSentence,
    String? documentTitle,
    int? sentenceOffset,
  }) async {
    lastPayloadJson = rawPayloadJson;
    lastSentence = sentence;
    return resultToReturn;
  }
}
```

把 setUp 里的 server 构造加上 `remoteMiningService: fakeMining`（先声明 `late _FakeRemoteMiningService fakeMining;` 并在 setUp 里 `fakeMining = _FakeRemoteMiningService();`）。新增测试：

```dart
test('mine route forwards payload + sentence and returns MineResult name', () async {
  final client = HttpClient();
  final request = await client.postUrl(
    Uri.parse('http://localhost:${server.port}/api/mine'));
  request.headers
    ..set('Authorization', 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}')
    ..contentType = ContentType.json;
  request.add(utf8.encode(jsonEncode(<String, dynamic>{
    'payload': <String, dynamic>{'expression': '猫', 'reading': 'ねこ'},
    'sentence': '猫がいる。',
    'documentTitle': 'web',
  })));
  final response = await request.close();
  final bodyStr = await response.transform(utf8.decoder).join();
  client.close();

  expect(response.statusCode, 200);
  final json = jsonDecode(bodyStr) as Map<String, dynamic>;
  expect(json['type'], 'mineResult');
  expect(json['result'], 'success');
  expect(fakeMining.lastSentence, '猫がいる。');
  expect(fakeMining.lastPayloadJson, contains('"expression":"猫"'));
});

test('mine route requires auth', () async {
  final client = HttpClient();
  final request = await client.postUrl(
    Uri.parse('http://localhost:${server.port}/api/mine'));
  request.headers.contentType = ContentType.json;
  request.add(utf8.encode(jsonEncode(<String, dynamic>{
    'payload': <String, dynamic>{}, 'sentence': '',
  })));
  final response = await request.close();
  await response.drain<void>();
  client.close();
  expect(response.statusCode, 401);
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd hibiki && flutter test test/sync/hibiki_sync_server_test.dart`
Expected: 编译失败——`HibikiRemoteMiningService` 类型不存在、server 构造无 `remoteMiningService`、无 `/api/mine` 路由。

- [ ] **Step 3: 新建 mining seam 接口**

Create `hibiki/lib/src/sync/hibiki_remote_mining_service.dart`：

```dart
/// 浏览器扩展挖词桥接口：把网页里挖的词交给 Hibiki 的 Anki 集成。
///
/// 返回 `MineResult.name`（`success` / `duplicate` / `notConfigured` / `error`），
/// 让 sync 层不必依赖 hibiki_anki 的枚举类型。
abstract class HibikiRemoteMiningService {
  Future<String> mineEntry({
    required String rawPayloadJson,
    required String sentence,
    String? cueSentence,
    String? documentTitle,
    int? sentenceOffset,
  });
}
```

- [ ] **Step 4: 具体实现（app_model.dart）**

在 `app_model.dart` 里 `createRemoteLookupService()`（约 :2643）旁加：

```dart
HibikiRemoteMiningService createRemoteMiningService() =>
    _AppModelRemoteMiningService(this);
```

在 `_AppModelRemoteLookupService`（约 :2793）旁加：

```dart
class _AppModelRemoteMiningService implements HibikiRemoteMiningService {
  _AppModelRemoteMiningService(this._appModel);

  final AppModel _appModel;

  @override
  Future<String> mineEntry({
    required String rawPayloadJson,
    required String sentence,
    String? cueSentence,
    String? documentTitle,
    int? sentenceOffset,
  }) async {
    final BaseAnkiRepository repo = _appModel.platformServices.createAnkiRepository();
    final MineResult result = await repo.mineEntry(
      rawPayloadJson: rawPayloadJson,
      context: AnkiMiningContext(
        sentence: sentence,
        cueSentence: cueSentence,
        documentTitle: documentTitle,
        sentenceOffset: sentenceOffset,
      ),
    );
    return result.name;
  }
}
```

确认 `app_model.dart` 顶部 import 了：`hibiki_remote_mining_service.dart`、`BaseAnkiRepository`/`MineResult`/`AnkiMiningContext`（来自 `package:hibiki_anki/...`，app_model 现有挖词导出代码 :2724 已用 `mineEntry`，故大概率已 import；缺则补）。并确认 `AppModel.platformServices` 是公开 getter/字段（若是私有 `_platformServices`，则用其公开访问器；若无则在 `_AppModelRemoteMiningService` 构造时把 `platformServices` 传进来而不是经 `_appModel`）。

- [ ] **Step 5: server 加字段 + 构造参数**

`hibiki/lib/src/sync/hibiki_sync_server.dart` 构造函数（:66）加可选命名参数与字段：

```dart
HibikiSyncServer({
  required String syncDataDir,
  required int port,
  required String token,
  bool allowLan = false,
  HibikiRemoteLookupService? remoteLookupService,
  HibikiRemoteMiningService? remoteMiningService,
})  : syncDataDir = p.join(syncDataDir, 'sync-data'),
      _requestedPort = port,
      _token = token,
      _allowLan = allowLan,
      _remoteLookupService = remoteLookupService,
      _remoteMiningService = remoteMiningService;
```

字段区（:79 附近）加：`final HibikiRemoteMiningService? _remoteMiningService;`
并在文件顶部 import `hibiki_remote_mining_service.dart`。

- [ ] **Step 6: server 加路由分支 + `_handleMine`**

`_handleRequest`（:171）在 `/api/lookup/` 分支后、WebDAV 之前加：

```dart
if (reqPath == '/api/mine') {
  return _handleMine(request, method);
}
```

在 `_handleDictionaryLookup` 旁加：

```dart
Future<shelf.Response> _handleMine(shelf.Request request, String method) async {
  if (method != 'POST') return shelf.Response(405, body: 'Use POST');
  final HibikiRemoteMiningService? service = _remoteMiningService;
  if (service == null) return shelf.Response.notFound('Mining off');
  final Map<String, dynamic>? body = await _readJsonObject(request);
  if (body == null) return shelf.Response(400, body: 'Invalid JSON');

  final dynamic payload = body['payload'];
  if (payload == null) return shelf.Response(400, body: 'Missing payload');
  final String rawPayloadJson =
      payload is String ? payload : jsonEncode(payload);
  final String sentence = body['sentence']?.toString() ?? '';

  final String resultName = await service.mineEntry(
    rawPayloadJson: rawPayloadJson,
    sentence: sentence,
    cueSentence: body['cueSentence']?.toString(),
    documentTitle: body['documentTitle']?.toString(),
    sentenceOffset: (body['sentenceOffset'] as num?)?.toInt(),
  );
  return _jsonResponse(<String, dynamic>{
    'type': 'mineResult', 'result': resultName,
  });
}
```

（`/api/mine` 不加进 `_authMiddleware` 豁免，默认走 Basic 鉴权，满足「mine route requires auth」测试。）

- [ ] **Step 7: 跑测试确认通过**

Run: `cd hibiki && flutter test test/sync/hibiki_sync_server_test.dart`
Expected: PASS（含两个新 mining 测试）。

- [ ] **Step 8: 真实注入点接线**

`hibiki/lib/src/sync/sync_settings_schema.dart:1952` 构造 `HibikiSyncServer` 处，加一行：

```dart
remoteLookupService: appModel.createRemoteLookupService(),
remoteMiningService: appModel.createRemoteMiningService(),
```

- [ ] **Step 9: 全量验证 + 提交**

Run: `cd hibiki && dart format . && flutter test`
Expected: 全绿（关注 sync 与 app_model 相关）。

```bash
git add hibiki/lib/src/sync/hibiki_remote_mining_service.dart \
        hibiki/lib/src/models/app_model.dart \
        hibiki/lib/src/sync/hibiki_sync_server.dart \
        hibiki/lib/src/sync/sync_settings_schema.dart \
        hibiki/test/sync/hibiki_sync_server_test.dart
git commit -m "feat(sync): add POST /api/mine route + mining seam for browser bridge"
```

---

## Part 2 — 浏览器扩展（`tools/browser-extension/`）

> 说明：扩展侧无法用 flutter test 验证，靠真实 Chrome + 运行中的 Hibiki 手测；每个 Task 末尾给出明确的人工验证步骤与预期。这部分代码块是可执行起点，`popup.js` 集成（Task 5）需对照真实 `popupJson` 形状迭代一次。

### Task 3: 扩展骨架 + 配置页 + 连通性

**Files:**
- Create: `tools/browser-extension/manifest.json`
- Create: `tools/browser-extension/options.html` / `tools/browser-extension/options.js`
- Create: `tools/browser-extension/background.js`
- Create: `tools/browser-extension/vendor/sync.md`

- [ ] **Step 1: manifest.json**

```json
{
  "manifest_version": 3,
  "name": "Hibiki Reader Bridge",
  "version": "0.1.0",
  "description": "网页 Shift 取词查 Hibiki 词典并挖词进 Anki",
  "permissions": ["storage"],
  "host_permissions": ["http://localhost/*", "http://127.0.0.1/*"],
  "options_ui": { "page": "options.html", "open_in_tab": true },
  "background": { "service_worker": "background.js" },
  "content_scripts": [
    {
      "matches": ["<all_urls>"],
      "js": ["content.js"],
      "run_at": "document_idle"
    }
  ],
  "web_accessible_resources": [
    {
      "resources": ["vendor/popup.js", "vendor/popup.css",
                    "vendor/dict-media.js", "vendor/selection.js",
                    "bridge-shim.js"],
      "matches": ["<all_urls>"]
    }
  ]
}
```

- [ ] **Step 2: options 页（配置存储）**

`options.html`：

```html
<!doctype html><meta charset="utf-8">
<body style="font-family:sans-serif;max-width:420px;margin:24px auto">
  <h3>Hibiki Reader Bridge</h3>
  <label>Host <input id="host" value="127.0.0.1"></label><br><br>
  <label>Port <input id="port" type="number" value="0"></label><br><br>
  <label>Token <input id="token" style="width:100%"></label><br><br>
  <label>修饰键
    <select id="modifier">
      <option value="shiftKey">Shift</option>
      <option value="ctrlKey">Ctrl</option>
      <option value="altKey">Alt</option>
    </select>
  </label><br><br>
  <button id="save">保存</button>
  <button id="test">测试连接</button>
  <pre id="status"></pre>
  <script src="options.js"></script>
</body>
```

`options.js`：

```javascript
const $ = (id) => document.getElementById(id);
const KEYS = ['host', 'port', 'token', 'modifier'];

async function load() {
  const cfg = await chrome.storage.local.get(KEYS);
  if (cfg.host) $('host').value = cfg.host;
  if (cfg.port) $('port').value = cfg.port;
  if (cfg.token) $('token').value = cfg.token;
  if (cfg.modifier) $('modifier').value = cfg.modifier;
}

$('save').onclick = async () => {
  await chrome.storage.local.set({
    host: $('host').value.trim(),
    port: Number($('port').value),
    token: $('token').value.trim(),
    modifier: $('modifier').value,
  });
  $('status').textContent = '已保存';
};

$('test').onclick = async () => {
  $('status').textContent = '测试中…';
  const res = await chrome.runtime.sendMessage({
    type: 'lookup', term: '猫', wildcards: false, maximumTerms: 3, record: false,
  });
  $('status').textContent = res && res.ok
    ? '连接成功，popupJson 长度=' + (res.data.popupJson || '').length
    : '失败: ' + (res && res.error);
};

load();
```

- [ ] **Step 3: background service worker（带鉴权的 fetch）**

`background.js`：

```javascript
async function cfg() {
  return chrome.storage.local.get(['host', 'port', 'token']);
}

function authHeader(token) {
  return 'Basic ' + btoa('hibiki:' + token);
}

async function post(path, bodyObj) {
  const c = await cfg();
  if (!c.host || !c.port || !c.token) {
    return { ok: false, error: '未配置 host/port/token' };
  }
  const url = `http://${c.host}:${c.port}${path}`;
  try {
    const resp = await fetch(url, {
      method: 'POST',
      headers: {
        'Authorization': authHeader(c.token),
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(bodyObj),
    });
    if (!resp.ok) return { ok: false, error: 'HTTP ' + resp.status };
    return { ok: true, data: await resp.json() };
  } catch (e) {
    return { ok: false, error: String(e) + '（Hibiki 未运行或互联服务器未开？）' };
  }
}

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg.type === 'lookup') {
    post('/api/lookup/dictionary', {
      term: msg.term, wildcards: !!msg.wildcards,
      maximumTerms: msg.maximumTerms || 10, record: msg.record !== false,
    }).then(sendResponse);
    return true; // async
  }
  if (msg.type === 'mine') {
    post('/api/mine', {
      payload: msg.payload, sentence: msg.sentence || '',
      documentTitle: msg.documentTitle, cueSentence: msg.cueSentence,
      sentenceOffset: msg.sentenceOffset,
    }).then(sendResponse);
    return true;
  }
  return false;
});
```

- [ ] **Step 4: vendor 同步说明占位**

`vendor/sync.md`：

```markdown
# vendor 来源
这些文件从 hibiki/assets/popup/ 原样复制，请勿手改。
重新同步：把 hibiki/assets/popup/{popup.js,popup.css,popup.html,dict-media.js,selection.js}
覆盖到本目录，并记录来源 commit。
来源 commit: <Task 4 执行时填写 git rev-parse HEAD>
```

- [ ] **Step 5: 人工验证（连通性）**

1. 启动 Hibiki（桌面），设置里开「Hibiki 互联」服务器，记下端口与配对 token。
2. Chrome `chrome://extensions` → 开发者模式 → 「加载已解压的扩展程序」选 `tools/browser-extension/`。
3. 打开扩展 options，填 host=`127.0.0.1`、port=Hibiki 端口、token=配对 token、保存。
4. 点「测试连接」。
   Expected: 显示「连接成功，popupJson 长度=…」（非 0）。若失败看 status 报错（鉴权/未运行）。

- [ ] **Step 6: 提交**

```bash
git add tools/browser-extension/manifest.json \
        tools/browser-extension/options.html tools/browser-extension/options.js \
        tools/browser-extension/background.js tools/browser-extension/vendor/sync.md
git commit -m "feat(extension): scaffold MV3 bridge + options + background fetch"
```

---

### Task 4: vendor 弹窗资源 + bridge-shim 骨架

**Files:**
- Create: `tools/browser-extension/vendor/{popup.js,popup.css,popup.html,dict-media.js,selection.js}`（复制）
- Create: `tools/browser-extension/bridge-shim.js`

- [ ] **Step 1: 复制 vendor 资源并记录来源 commit**

```bash
mkdir -p tools/browser-extension/vendor
cp hibiki/assets/popup/popup.js hibiki/assets/popup/popup.css \
   hibiki/assets/popup/popup.html hibiki/assets/popup/dict-media.js \
   hibiki/assets/popup/selection.js tools/browser-extension/vendor/
git rev-parse HEAD   # 把输出填进 vendor/sync.md 的来源 commit
```

- [ ] **Step 2: bridge-shim.js（接管 popup.js 的 callHandler）**

依据 `popup.js` 实际 handler 清单（`openLink`/`mineEntry`/`onLinkClick`/`resolveWordAudio`/`playWordAudio`/`duplicateCheck`/`popupRendered`/`tapOutside`）。shim 在 popup.js 加载**之前**注入，提供 `window.flutter_inappwebview`：

```javascript
// bridge-shim.js —— 在 popup.js 之前加载；用扩展逻辑接管 Flutter 桥。
// content.js 会先设置 window.__hibikiBridge = { onMine, onDuplicateCheck,
//   onResize, onDismiss, onRelookup, onAudioResolve, onAudioPlay }。
(function () {
  function bridge() { return window.__hibikiBridge || {}; }
  window.flutter_inappwebview = {
    callHandler: function (name, ...args) {
      const b = bridge();
      switch (name) {
        case 'popupRendered':                 // args[0] = scrollHeight
          if (b.onResize) b.onResize(args[0]);
          return Promise.resolve();
        case 'mineEntry':                     // args[0] = payload object
          return Promise.resolve(b.onMine ? b.onMine(args[0]) : false);
        case 'duplicateCheck':                // args[0] = {expression, reading}
          return Promise.resolve(
            b.onDuplicateCheck ? b.onDuplicateCheck(args[0]) : false);
        case 'onLinkClick':                   // re-lookup; args[0] = {query/char/expression, rect}
          if (b.onRelookup) b.onRelookup(args[0]);
          return Promise.resolve();
        case 'tapOutside':
          if (b.onDismiss) b.onDismiss();
          return Promise.resolve();
        case 'resolveWordAudio':              // args[0] = {expression, reading}
          return Promise.resolve(
            b.onAudioResolve ? b.onAudioResolve(args[0]) : null);
        case 'playWordAudio':                 // args[0] = {url, mode}
          if (b.onAudioPlay) b.onAudioPlay(args[0]);
          return Promise.resolve();
        case 'openLink':
          if (args[0]) window.open(args[0], '_blank', 'noopener');
          return Promise.resolve();
        default:
          return Promise.resolve();           // 未知 handler no-op
      }
    },
  };
})();
```

- [ ] **Step 3: 人工验证（资源就位）**

`chrome://extensions` 重新加载扩展，确认无清单/资源报错（vendor 文件都在 `web_accessible_resources`）。此 Task 还不接渲染，验证点仅为「扩展能加载、无报错」。

- [ ] **Step 4: 提交**

```bash
git add tools/browser-extension/vendor/ tools/browser-extension/bridge-shim.js
git commit -m "feat(extension): vendor Hibiki popup assets + flutter bridge shim"
```

---

### Task 5: content.js —— Shadow DOM 挂载 + 渲染 popupJson

**Files:**
- Create: `tools/browser-extension/content.js`

> 关键未知：服务器 `popupJson` 解码后要赋给 `window.lookupEntries`（popup.js 的 `renderPopup` 读它，渲染进 `#entries-container`）。`popupJson` 的真实结构（是数组还是 `{entries:[...]}`）需在本 Task 第 1 步用真实 Hibiki 实测一次再定映射。

- [ ] **Step 1: 实测 popupJson 形状（一次性探查，非占位）**

在扩展 options 的「测试连接」基础上，临时在 `background.js` 的 lookup 分支里 `console.log(JSON.stringify(data.popupJson).slice(0,500))`，或在 Hibiki 仓库搜 `lookupPopupJson` 的产出结构 / 看 `popup.js:1684` 对 `window.lookupEntries` 的消费（`entry.glossaries` / `entry.expression` / `entry.reading`）。确定：`JSON.parse(popupJson)` 是「entries 数组」还是「含 entries 字段的对象」。记录结论到 content.js 顶部注释，并据此实现 Step 2 的 `entriesFromPopupJson()`。

- [ ] **Step 2: content.js 挂载 + 渲染**

```javascript
// content.js —— 取词 + 在 Shadow DOM 里用 Hibiki popup.js 渲染。
let host, shadow, popupWin;        // 单例浮层
let currentSentence = '';

function url(p) { return chrome.runtime.getURL(p); }

// 依据 Step 1 实测结论实现：把服务器 popupJson 映射成 popup.js 要的 entries 数组。
function entriesFromPopupJson(popupJson) {
  if (!popupJson) return [];
  const parsed = JSON.parse(popupJson);
  return Array.isArray(parsed) ? parsed : (parsed.entries || []);
}

async function ensureHost() {
  if (host) return;
  host = document.createElement('div');
  host.style.cssText =
    'position:absolute;z-index:2147483647;top:0;left:0;display:none';
  document.documentElement.appendChild(host);
  shadow = host.attachShadow({ mode: 'open' });

  // 注入 popup.css
  const css = document.createElement('link');
  css.rel = 'stylesheet';
  css.href = url('vendor/popup.css');
  shadow.appendChild(css);

  // 注入空壳容器（对应 popup.html 的 #entries-container + overlay）
  const container = document.createElement('div');
  container.id = 'entries-container';
  shadow.appendChild(container);

  // 在 Shadow 里建一个独立的 window 上下文不可行；popup.js 用全局 window/document，
  // 因此把 #entries-container 暴露到 document.getElementById 可见的位置：
  // 方案——popup.js 用 document.getElementById('entries-container')，Shadow DOM 不可见。
  // 故改为「open shadow + 用同名 id 挂在 light DOM 容器内」由 content 自己驱动 render。
  // 详见 Step 3 决策。
}
```

> **设计决策（Step 2 暴露的真问题）：** `popup.js` 全程用 `document.getElementById('entries-container')` 与全局 `window.*`，**它假设自己跑在一个文档顶层**。Shadow DOM 里的元素 `document.getElementById` 取不到。两条可行路径，二选一并在本步落定：
> - **(a) iframe 隔离（推荐）**：用一个扩展页面 iframe（`chrome-extension://.../vendor/popup-host.html`，内含 popup.html 壳 + bridge-shim + popup.js），content.js 通过 `postMessage` 把 `lookupEntries` 传进去、把 `popupRendered` 高度传出来。`popup.js` 在 iframe 文档顶层运行，`getElementById` 正常，样式天然隔离。
> - **(b) 改 vendor popup.js 取容器方式**：把 `document.getElementById('entries-container')` 换成可注入的根节点。违反「vendor 原样不改」，不推荐。
>
> 采用 **(a)**。下面 Step 3 按 iframe 方案重写。

- [ ] **Step 3: 新建 iframe 宿主页 + content.js 用 postMessage 驱动**

Create `tools/browser-extension/vendor/popup-host.html`（基于 vendor/popup.html，但先加载 bridge-shim，再 popup.js；并加一段桥接监听）：

```html
<!doctype html><meta charset="utf-8">
<head>
  <link rel="stylesheet" href="popup.css">
  <script src="dict-media.js"></script>
  <script src="selection.js"></script>
  <script src="../bridge-shim.js"></script>
</head>
<body>
  <div id="entries-container"></div>
  <div class="overlay">
    <div class="overlay-close" onclick="closeOverlay()">×</div>
    <div class="overlay-content"></div>
  </div>
  <script src="popup.js"></script>
  <script src="popup-host-bridge.js"></script>
</body>
```

Create `tools/browser-extension/vendor/popup-host-bridge.js`：

```javascript
// 运行在 iframe 内：连接 bridge-shim 与父窗口（content.js）。
window.__hibikiBridge = {
  onResize: (h) => parent.postMessage({ __hibiki: 'resize', height: h }, '*'),
  onMine: (payload) => { parent.postMessage({ __hibiki: 'mine', payload }, '*'); return true; },
  onDuplicateCheck: () => false,
  onDismiss: () => parent.postMessage({ __hibiki: 'dismiss' }, '*'),
  onRelookup: (arg) => parent.postMessage({ __hibiki: 'relookup', arg }, '*'),
  onAudioResolve: () => null,
  onAudioPlay: () => {},
};

window.addEventListener('message', (e) => {
  const m = e.data;
  if (!m || m.__hibiki !== 'render') return;
  window.lookupEntries = m.entries;
  if (typeof window.renderPopup === 'function') window.renderPopup();
});
```

`content.js`（替换 Step 2 草稿）：

```javascript
let host, frame, ready = false, pending = null;
let currentSentence = '';

function url(p) { return chrome.runtime.getURL(p); }

function entriesFromPopupJson(popupJson) {
  if (!popupJson) return [];
  const parsed = JSON.parse(popupJson);
  return Array.isArray(parsed) ? parsed : (parsed.entries || []);
}

function ensureHost() {
  if (host) return;
  host = document.createElement('div');
  host.style.cssText =
    'position:absolute;z-index:2147483647;display:none;border:0';
  frame = document.createElement('iframe');
  frame.src = url('vendor/popup-host.html');
  frame.style.cssText = 'border:0;width:420px;height:200px;background:transparent';
  frame.onload = () => { ready = true; if (pending) { flush(); } };
  host.appendChild(frame);
  document.documentElement.appendChild(host);

  window.addEventListener('message', (e) => {
    const m = e.data;
    if (!m || !m.__hibiki) return;
    if (m.__hibiki === 'resize') frame.style.height = (m.height + 8) + 'px';
    else if (m.__hibiki === 'dismiss') hide();
    else if (m.__hibiki === 'mine') doMine(m.payload);
    else if (m.__hibiki === 'relookup') lookupAndShow(m.arg.query || m.arg.expression || m.arg.char, null);
  });
}

function flush() {
  frame.contentWindow.postMessage({ __hibiki: 'render', entries: pending }, '*');
  pending = null;
}

function showAt(x, y) {
  host.style.left = (window.scrollX + x) + 'px';
  host.style.top = (window.scrollY + y + 16) + 'px';
  host.style.display = 'block';
}
function hide() { if (host) host.style.display = 'none'; }

async function lookupAndShow(term, anchor) {
  if (!term) return;
  ensureHost();
  const res = await chrome.runtime.sendMessage({
    type: 'lookup', term, wildcards: false, maximumTerms: 10, record: true,
  });
  if (!res || !res.ok) return;
  pending = entriesFromPopupJson(res.data.popupJson);
  if (ready) flush();
  if (anchor) showAt(anchor.x, anchor.y);
}

async function doMine(payload) {
  const res = await chrome.runtime.sendMessage({
    type: 'mine', payload, sentence: currentSentence,
    documentTitle: document.title,
  });
  // 可选：toast 提示 res.data.result（success/duplicate/notConfigured/error）
  console.log('[Hibiki] mine:', res && res.ok ? res.data.result : res);
}
```

- [ ] **Step 4: 人工验证（渲染链路，先用固定词触发）**

临时在 content.js 末尾加 `window.addEventListener('dblclick', e => lookupAndShow(getSelection().toString().trim(), {x:e.clientX,y:e.clientY}));`，重载扩展，在日文网页双击选中一个词。
Expected: 鼠标下方出现 Hibiki 同款弹窗（样式正确、有释义）；iframe 高度自适应。若弹窗空白，回 Step 1 核对 `entriesFromPopupJson` 映射。验证后删掉这行临时 dblclick（Task 6 接真正的取词）。

- [ ] **Step 5: 提交**

```bash
git add tools/browser-extension/content.js \
        tools/browser-extension/vendor/popup-host.html \
        tools/browser-extension/vendor/popup-host-bridge.js
git commit -m "feat(extension): render Hibiki popup in isolated iframe via postMessage bridge"
```

---

### Task 6: 取词扫描（Shift 悬停）+ 句子上下文

**Files:**
- Modify: `tools/browser-extension/content.js`

- [ ] **Step 1: 取词与句子提取函数**

在 content.js 加（取词窗口 + 句子边界）：

```javascript
const SCAN_MAX = 12; // 取词窗口最长字数

function caretInfoFromPoint(x, y) {
  // Chromium: caretRangeFromPoint; Firefox: caretPositionFromPoint
  if (document.caretRangeFromPoint) {
    const r = document.caretRangeFromPoint(x, y);
    return r ? { node: r.startContainer, offset: r.startOffset } : null;
  }
  if (document.caretPositionFromPoint) {
    const p = document.caretPositionFromPoint(x, y);
    return p ? { node: p.offsetNode, offset: p.offset } : null;
  }
  return null;
}

function scanWord(node, offset) {
  if (!node || node.nodeType !== Node.TEXT_NODE) return null;
  const text = node.textContent;
  if (offset >= text.length) return null;
  const window_ = text.slice(offset, offset + SCAN_MAX).trim();
  return window_ || null;
}

function sentenceAround(node, offset) {
  if (!node || node.nodeType !== Node.TEXT_NODE) return '';
  const text = node.textContent;
  const enders = '。．.!?！？\n';
  let s = offset, e = offset;
  while (s > 0 && !enders.includes(text[s - 1])) s--;
  while (e < text.length && !enders.includes(text[e])) e++;
  return text.slice(s, e + 1).trim();
}
```

- [ ] **Step 2: 修饰键 + mousemove 驱动（节流）**

```javascript
let cfgCache = {};
chrome.storage.local.get(['modifier']).then((c) => { cfgCache = c; });
chrome.storage.onChanged.addListener((ch) => {
  if (ch.modifier) cfgCache.modifier = ch.modifier.newValue;
});

let lastTerm = '';
let scanTimer = null;

document.addEventListener('mousemove', (e) => {
  const mod = cfgCache.modifier || 'shiftKey';
  if (!e[mod]) return;                      // 仅按住修饰键时取词
  if (scanTimer) return;                    // 节流
  scanTimer = setTimeout(() => { scanTimer = null; }, 30);

  const info = caretInfoFromPoint(e.clientX, e.clientY);
  if (!info) return;
  const term = scanWord(info.node, info.offset);
  if (!term || term === lastTerm) return;
  lastTerm = term;
  currentSentence = sentenceAround(info.node, info.offset);
  lookupAndShow(term, { x: e.clientX, y: e.clientY });
}, true);

// 松开修饰键 / 点击别处收起
document.addEventListener('keyup', (e) => {
  const mod = (cfgCache.modifier || 'shiftKey').replace('Key', '');
  if (e.key === 'Shift' || e.key === 'Control' || e.key === 'Alt') {
    // 不立即收，留给 tapOutside；这里仅清 lastTerm 便于再次触发
    lastTerm = '';
  }
});
document.addEventListener('mousedown', (e) => {
  if (host && host.style.display === 'block' && !host.contains(e.target)) hide();
}, true);
```

- [ ] **Step 3: 人工验证（真实取词）**

删掉 Task 5 的临时 dblclick。重载扩展。在日文网页按住 Shift，鼠标移到一个词上。
Expected:
- 词上方/下方弹出 Hibiki 弹窗，内容是该词去屈折后的释义。
- 移到不同词刷新；松开 Shift 不再新触发；点别处收起。
- Hibiki 端「查词历史」里出现这些词（验证 record=true 生效）。

- [ ] **Step 4: 提交**

```bash
git add tools/browser-extension/content.js
git commit -m "feat(extension): Shift-hover word scan + sentence context"
```

---

### Task 7: 挖词按钮联调 + 端到端验证

**Files:**
- 无新增（mineEntry 桥已在 Task 4/5 接好）；本 Task 为联调与真实 Anki 验证。

- [ ] **Step 1: 确认弹窗内挖词按钮经 shim 流向 /api/mine**

弹窗里 popup.js 的挖词 UI 点击会调 `callHandler('mineEntry', payload)`（`popup.js:839`）→ bridge-shim → `popup-host-bridge.js onMine` → postMessage → content.js `doMine` → background `/api/mine`。无需新增代码，仅核对链路。

- [ ] **Step 2: 人工端到端验证（含 Anki）**

前置：Hibiki 桌面端配好 AnkiConnect（Anki 开着、AnkiConnect 插件在）。
1. 按住 Shift 悬停取词 → 弹窗出现。
2. 点弹窗里的「挖词/+」按钮。
3. 看 content.js console：`[Hibiki] mine: success`。
4. Anki 里出现新卡片，sentence 字段是网页里那句话，expression/reading/glossary 正确。
5. 再挖同一个词 → `duplicate`（如果 Hibiki Anki 配置查重）。

Expected：全部符合；失败按 `notConfigured`/`error` 提示回查 Hibiki Anki 设置。

- [ ] **Step 3: 收尾提交（如有 toast/小修）**

```bash
git add tools/browser-extension/content.js
git commit -m "feat(extension): wire mine button end-to-end to /api/mine"
```

---

## 范围外（本计划不做）

- 桌面端剪贴板监听 + 全局热键弹窗（独立 spec）。
- 网页阅读位置同步。
- 跨设备（非 localhost）扩展使用；音频播放（`resolveWordAudio`/`playWordAudio` 当前在 shim 里 no-op，可后续接 background fetch `/api/lookup/audio`）。
- 弹窗内查重 `duplicateCheck`（当前返回 false，后续可接一个 `/api/anki/duplicate` 路由）。

## 验证总览

- Part 1 每 Task：`flutter test test/sync/hibiki_sync_server_test.dart`；Task 2 末尾全量 `flutter test`。
- Part 2：真实 Chrome + 运行中的 Hibiki 手测（每 Task 的人工验证步骤），最终 Task 7 跑通取词→弹窗→挖 Anki 全链路并留证据（截图/console）。
