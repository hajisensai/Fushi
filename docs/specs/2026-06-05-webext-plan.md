# 浏览器扩展（网页查词）实现计划（线3）

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`).

**Goal:** 一个极薄 MV3 浏览器扩展，网页取词 → 查 Hibiki 已导入词典 → Shadow DOM 弹窗显示 → 挖词进 Anki，后端复用 `HibikiSyncServer`。

**Architecture:** Hibiki 后端在现有 `HibikiSyncServer`（「Hibiki 互联」server）加 `record` 写历史 + `POST /api/mine` 挖词（经新窄接口 `HibikiRemoteMiningService`，无 ref 用 `platformServices.createAnkiRepository()`）。扩展前端 `tools/browser-extension/`：content.js 取词扫描 + Shadow DOM 注入 vendor popup.js（复用 Hibiki 渲染）+ bridge-shim 垫 callHandler（仿 Android PopupDictActivity）+ background 代发请求 + options 配对。

**Tech Stack:** Dart/shelf（后端）, JS/MV3（扩展）, 复用 assets/popup/popup.js。

依据：`docs/specs/2026-06-05-webext-and-desktop-clipboard-design.md` §4。

---

## 文件结构
- Modify: `hibiki/lib/src/sync/hibiki_remote_lookup_service.dart`（加 `HibikiRemoteMiningService` 窄接口）
- Modify: `hibiki/lib/src/models/app_model.dart`（`_AppModelRemoteLookupService` implements 新接口 + `createRemoteMiningService()`）
- Modify: `hibiki/lib/src/sync/hibiki_sync_server.dart`（构造加 `miningService` + `record` + `/api/mine` 路由）
- Modify: `hibiki/lib/src/sync/sync_settings_schema.dart`（HibikiSyncServer 创建点注入 miningService）
- Test: `hibiki/test/sync/hibiki_sync_server_mine_test.dart`、`hibiki/test/sync/hibiki_sync_server_record_test.dart`
- Create: `tools/browser-extension/{manifest.json,background.js,content.js,bridge-shim.js,options.html,options.js,vendor/}`

---

## Task 1: 后端窄接口 `HibikiRemoteMiningService`

**Files:**
- Modify: `hibiki/lib/src/sync/hibiki_remote_lookup_service.dart`
- Modify: `hibiki/lib/src/models/app_model.dart`
- Test: `hibiki/test/sync/hibiki_remote_mining_service_test.dart`

- [ ] **Step 1: 写失败测试**

```dart
// hibiki/test/sync/hibiki_remote_mining_service_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_remote_lookup_service.dart';

void main() {
  test('HibikiRemoteMiningService is an abstract contract with mineEntry', () {
    // 编译期契约测试：实现类必须提供 mineEntry。
    expect(_FakeMining(), isA<HibikiRemoteMiningService>());
  });
}

class _FakeMining implements HibikiRemoteMiningService {
  @override
  Future<String> mineEntry({
    required Map<String, String> fields,
    required String sentence,
  }) async => 'success';
}
```

- [ ] **Step 2: 运行确认失败**

Run（worktree hibiki 下）: `flutter test test/sync/hibiki_remote_mining_service_test.dart`
Expected: FAIL（`HibikiRemoteMiningService` 未定义）。

- [ ] **Step 3: 写实现**

在 `hibiki_remote_lookup_service.dart` 末尾加：
```dart
/// 浏览器扩展挖词的窄接口（与查词分离，避免 server 直接依赖 AnkiRepository）。
abstract class HibikiRemoteMiningService {
  /// 返回 MineResult.name（'success'|'duplicate'|'notConfigured'|'error'）。
  Future<String> mineEntry({
    required Map<String, String> fields,
    required String sentence,
  });
}
```

在 `app_model.dart` 的 `_AppModelRemoteLookupService`（约 2825 行）改为同时 implements 新接口，并实现 mineEntry（用 `platformServices.createAnkiRepository()`，无 ref，无 toast）：
```dart
class _AppModelRemoteLookupService
    implements HibikiRemoteLookupService, HibikiRemoteMiningService {
  // ... 现有 searchDictionary / lookupAudio 不变 ...

  @override
  Future<String> mineEntry({
    required Map<String, String> fields,
    required String sentence,
  }) async {
    final repo = _appModel.platformServices.createAnkiRepository();
    final result = await repo.mineEntry(
      rawPayloadJson: jsonEncode(fields),
      context: AnkiMiningContext(sentence: sentence),
    );
    return result.name;
  }
}
```
在 AppModel 加工厂（紧邻 `createRemoteLookupService`，约 2645）：
```dart
HibikiRemoteMiningService createRemoteMiningService() =>
    _AppModelRemoteLookupService(this);
```
确认 import：`AnkiMiningContext`/`MineResult`（来自 hibiki_anki）、`jsonEncode`（dart:convert）在 app_model 已有则复用。

- [ ] **Step 4: 运行确认通过** Run: 同 Step 2 → PASS。
- [ ] **Step 5: 提交**
```bash
cd "D:/APP/vs_claude_code/hibiki/.claude/worktrees/yomitan-compat"
git add hibiki/lib/src/sync/hibiki_remote_lookup_service.dart hibiki/lib/src/models/app_model.dart hibiki/test/sync/hibiki_remote_mining_service_test.dart
git diff --cached --check && git commit -m "feat(webext): add HibikiRemoteMiningService narrow interface"
```

---

## Task 2: HibikiSyncServer `POST /api/mine` + record 写历史

**Files:**
- Modify: `hibiki/lib/src/sync/hibiki_sync_server.dart`
- Modify: `hibiki/lib/src/sync/sync_settings_schema.dart`（注入 miningService）
- Test: `hibiki/test/sync/hibiki_sync_server_mine_test.dart`

- [ ] **Step 1: 写失败测试**

```dart
// hibiki/test/sync/hibiki_sync_server_mine_test.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:hibiki/src/sync/hibiki_remote_lookup_service.dart';

class _FakeMining implements HibikiRemoteMiningService {
  Map<String, String>? lastFields;
  String? lastSentence;
  @override
  Future<String> mineEntry(
      {required Map<String, String> fields, required String sentence}) async {
    lastFields = fields;
    lastSentence = sentence;
    return 'success';
  }
}

Future<HttpClientResponse> _post(int port, String path, Object body, String token) async {
  final c = HttpClient();
  final r = await c.post('127.0.0.1', port, path);
  r.headers.set('authorization',
      'Basic ${base64Encode(utf8.encode('hibiki:$token'))}');
  r.headers.contentType = ContentType.json;
  r.write(jsonEncode(body));
  return r.close();
}

void main() {
  test('POST /api/mine maps MineResult to JSON', () async {
    final mining = _FakeMining();
    final server = HibikiSyncServer(
      syncDataDir: Directory.systemTemp.createTempSync('hbk').path,
      port: 0, token: 'tok', miningService: mining,
    );
    await server.start();
    final port = server.port;

    final resp = await _post(port, '/api/mine',
        {'fields': {'expression': '分かる', 'sentence': 'これは分かる'}, 'sentence': 'これは分かる'},
        'tok');
    expect(resp.statusCode, 200);
    final out = jsonDecode(await resp.transform(utf8.decoder).join());
    expect(out['result'], 'success');
    expect(mining.lastFields?['expression'], '分かる');
    expect(mining.lastSentence, 'これは分かる');

    await server.stop();
  });

  test('POST /api/mine without auth is 401', () async {
    final server = HibikiSyncServer(
      syncDataDir: Directory.systemTemp.createTempSync('hbk').path,
      port: 0, token: 'tok', miningService: _FakeMining(),
    );
    await server.start();
    final c = HttpClient();
    final r = await c.post('127.0.0.1', server.port, '/api/mine');
    r.headers.contentType = ContentType.json;
    r.write('{}');
    final resp = await r.close();
    expect(resp.statusCode, 401);
    await server.stop();
  });
}
```

- [ ] **Step 2: 运行确认失败** Run: `flutter test test/sync/hibiki_sync_server_mine_test.dart` → FAIL（构造无 miningService 参数 / 无 /api/mine）。

- [ ] **Step 3: 写实现**

`hibiki_sync_server.dart` 构造加可选参数 + 字段（仿 `_remoteLookupService`，见现有 66-86）：
```dart
    HibikiRemoteMiningService? miningService,
    // ...
        _miningService = miningService;
  final HibikiRemoteMiningService? _miningService;
```
在 `_handleRequest`（约 177，`/api/lookup/` 分支附近）加 mine 路由（`/api/mine` 不以 `/api/lookup/` 开头，进 `_handleRequest` dispatch）：
```dart
    if (reqPath == '/api/mine') {
      if (method != 'POST') return shelf.Response(405);
      return _handleMine(request);
    }
```
新增 handler：
```dart
  Future<shelf.Response> _handleMine(shelf.Request request) async {
    final HibikiRemoteMiningService? svc = _miningService;
    if (svc == null) return shelf.Response.notFound('Mining off');
    final Map<String, dynamic>? body = await _readJsonObject(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');
    final dynamic rawFields = body['fields'];
    if (rawFields is! Map) {
      return shelf.Response(400, body: 'Missing fields');
    }
    final Map<String, String> fields = rawFields.map(
        (dynamic k, dynamic v) => MapEntry(k.toString(), v?.toString() ?? ''));
    final String sentence =
        body['sentence']?.toString() ?? fields['sentence'] ?? '';
    final String result = await svc.mineEntry(fields: fields, sentence: sentence);
    return _jsonResponse(<String, dynamic>{'result': result});
  }
```
record 写历史：在 `_handleDictionaryLookup`（267-294）查到结果后，读 `body['record'] == true` 时写历史。**用无 UI 副作用路径**——给 `HibikiRemoteLookupService` 加一个可选 history 写入，或在窄接口里加。最小：本 task 只接 mine；record 放 Task 3（避免本 task 过大）。

`sync_settings_schema.dart` 的 HibikiSyncServer 创建点（约 1906 `_startServer`）注入：
```dart
      remoteLookupService: appModel.createRemoteLookupService(),
      miningService: appModel.createRemoteMiningService(),
```

- [ ] **Step 4: 运行确认通过** Run: 同 Step 2 → PASS（2 tests）。
- [ ] **Step 5: 提交**
```bash
git add hibiki/lib/src/sync/hibiki_sync_server.dart hibiki/lib/src/sync/sync_settings_schema.dart hibiki/test/sync/hibiki_sync_server_mine_test.dart
git diff --cached --check && git commit -m "feat(webext): add POST /api/mine to sync server"
```

---

## Task 3: record 写历史

**Files:**
- Modify: `hibiki/lib/src/sync/hibiki_remote_lookup_service.dart`（searchDictionary 加 record 或新增 history 写入方法）
- Modify: `hibiki/lib/src/models/app_model.dart`、`hibiki/lib/src/sync/hibiki_sync_server.dart`
- Test: `hibiki/test/sync/hibiki_sync_server_record_test.dart`

- [ ] **Step 1: 写失败测试**

```dart
// hibiki/test/sync/hibiki_sync_server_record_test.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:hibiki/src/sync/hibiki_remote_lookup_service.dart';

class _RecordingLookup implements HibikiRemoteLookupService {
  int historyWrites = 0;
  @override
  Future<DictionarySearchResult?> searchDictionary(
      {required String term, required bool wildcards, required int maximumTerms}) async {
    return DictionarySearchResult(searchTerm: term, entries: [
      DictionaryEntry(dictionaryName: 'D', word: term, reading: term,
          meaning: 'm', extra: '{}', popularity: 0)
    ], bestLength: term.length);
  }
  @override
  Future<RemoteAudioLookup?> lookupAudio(
      {required String expression, required String reading}) async => null;
  @override
  void recordHistory(DictionarySearchResult result) { historyWrites++; }
}

Future<HttpClientResponse> _post(int port, Object body, String token) async {
  final c = HttpClient();
  final r = await c.post('127.0.0.1', port, '/api/lookup/dictionary');
  r.headers.set('authorization', 'Basic ${base64Encode(utf8.encode('h:$token'))}');
  r.headers.contentType = ContentType.json;
  r.write(jsonEncode(body));
  return r.close();
}

void main() {
  test('record:true writes history, default does not', () async {
    final lookup = _RecordingLookup();
    final server = HibikiSyncServer(
      syncDataDir: Directory.systemTemp.createTempSync('h').path,
      port: 0, token: 't', remoteLookupService: lookup);
    await server.start();

    await (await _post(server.port, {'term': '見る'}, 't')).drain();
    expect(lookup.historyWrites, 0); // 默认不写

    await (await _post(server.port, {'term': '見る', 'record': true}, 't')).drain();
    expect(lookup.historyWrites, 1); // record 写

    await server.stop();
  });
}
```

- [ ] **Step 2: 运行确认失败** Run: `flutter test test/sync/hibiki_sync_server_record_test.dart` → FAIL（接口无 recordHistory / 端点不处理 record）。

- [ ] **Step 3: 写实现**

`HibikiRemoteLookupService` 加方法：
```dart
  /// 把一次查词结果写入 Hibiki 查词历史（无 UI 副作用）。
  void recordHistory(DictionarySearchResult result);
```
`_AppModelRemoteLookupService` 实现（用无副作用底层，**不调** `addToDictionaryHistory`，避免 currentHomeTabIndex/ScrollController 副作用）：
```dart
  @override
  void recordHistory(DictionarySearchResult result) {
    _appModel.mediaHistoryRepo.addToSearchHistory(
        historyKey: DictionaryMediaType.instance.uniqueKey,
        searchTerm: result.searchTerm);
    _appModel.dictRepo.addHistoryResult(
        result, _appModel.maximumDictionaryHistoryItems);
  }
```
（核对 `mediaHistoryRepo`/`dictRepo`/`maximumDictionaryHistoryItems`/`DictionaryMediaType.instance.uniqueKey` 真实可见性，对齐。）
`_handleDictionaryLookup` 在拿到非空 result 后：
```dart
    if (result != null && (body['record'] as bool? ?? false)) {
      service.recordHistory(result);
    }
```

- [ ] **Step 4: 运行确认通过** Run: 同 Step 2 → PASS。
- [ ] **Step 5: 提交**
```bash
git add hibiki/lib/src/sync/hibiki_remote_lookup_service.dart hibiki/lib/src/models/app_model.dart hibiki/lib/src/sync/hibiki_sync_server.dart hibiki/test/sync/hibiki_sync_server_record_test.dart
git diff --cached --check && git commit -m "feat(webext): add record param to write lookup history"
```

---

## Task 4: 扩展骨架（manifest + background + options + 连通性）

**Files:** Create `tools/browser-extension/{manifest.json,background.js,options.html,options.js}`

- [ ] **Step 1: manifest.json（MV3）**
```json
{
  "manifest_version": 3,
  "name": "Hibiki Reader Bridge",
  "version": "0.1.0",
  "description": "Look up words on web pages using Hibiki's dictionaries.",
  "permissions": ["storage", "contextMenus", "clipboardRead"],
  "host_permissions": ["http://localhost/*", "http://127.0.0.1/*"],
  "background": { "service_worker": "background.js" },
  "content_scripts": [
    { "matches": ["<all_urls>"], "js": ["bridge-shim.js", "vendor/popup.js", "content.js"], "css": ["vendor/popup.css"] }
  ],
  "options_page": "options.html",
  "action": { "default_title": "Hibiki Reader Bridge" }
}
```

- [ ] **Step 2: background.js（代发请求绕 CSP）**
```js
// 集中向 Hibiki server 发请求，避免页面 CSP 限制 content script fetch。
async function cfg() {
  const { host = '127.0.0.1', port = 0, token = '' } =
      await chrome.storage.local.get(['host', 'port', 'token']);
  return { base: `http://${host}:${port}`, token };
}
function authHeader(token) {
  return 'Basic ' + btoa('hibiki:' + token);
}
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  (async () => {
    const { base, token } = await cfg();
    try {
      if (msg.type === 'lookup') {
        const r = await fetch(base + '/api/lookup/dictionary', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: authHeader(token) },
          body: JSON.stringify({ term: msg.term, record: true }),
        });
        sendResponse({ ok: r.ok, status: r.status, data: r.ok ? await r.json() : null });
      } else if (msg.type === 'mine') {
        const r = await fetch(base + '/api/mine', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: authHeader(token) },
          body: JSON.stringify({ fields: msg.fields, sentence: msg.sentence || '' }),
        });
        sendResponse({ ok: r.ok, status: r.status, data: r.ok ? await r.json() : null });
      } else {
        sendResponse({ ok: false, error: 'unknown' });
      }
    } catch (e) {
      sendResponse({ ok: false, error: String(e) });
    }
  })();
  return true; // async sendResponse
});
```

- [ ] **Step 3: options.html / options.js**（host/port/token 表单，存 chrome.storage.local）
```html
<!-- options.html -->
<!DOCTYPE html><html><body>
<label>Host <input id="host" value="127.0.0.1"></label><br>
<label>Port <input id="port" type="number"></label><br>
<label>Token <input id="token"></label><br>
<button id="save">Save</button><span id="status"></span>
<script src="options.js"></script></body></html>
```
```js
// options.js
const $ = (id) => document.getElementById(id);
chrome.storage.local.get(['host','port','token']).then((c) => {
  if (c.host) $('host').value = c.host;
  if (c.port) $('port').value = c.port;
  if (c.token) $('token').value = c.token;
});
$('save').onclick = async () => {
  await chrome.storage.local.set({
    host: $('host').value.trim(),
    port: parseInt($('port').value, 10) || 0,
    token: $('token').value.trim(),
  });
  $('status').textContent = ' Saved';
};
```

- [ ] **Step 4: 验证 + 提交**（JS 无项目测试框架；手动 lint：确认 JSON 合法 `python -c "import json;json.load(open('tools/browser-extension/manifest.json'))"`）
```bash
git add tools/browser-extension/manifest.json tools/browser-extension/background.js tools/browser-extension/options.html tools/browser-extension/options.js
git diff --cached --check && git commit -m "feat(webext): extension skeleton (manifest + background + options)"
```

---

## Task 5: vendor popup + bridge-shim（渲染）

**Files:** Create `tools/browser-extension/vendor/{popup.js,popup.css,popup.html}`（从 `hibiki/assets/popup/` 复制）、`tools/browser-extension/bridge-shim.js`

- [ ] **Step 1: vendor 同步**（复制，不改）
```bash
cd "D:/APP/vs_claude_code/hibiki/.claude/worktrees/yomitan-compat"
mkdir -p tools/browser-extension/vendor
cp hibiki/assets/popup/popup.js hibiki/assets/popup/popup.css hibiki/assets/popup/popup.html tools/browser-extension/vendor/
# popup.js 还 require dict-media.js / selection.js（popup.html 引用）——一并 vendor
cp hibiki/assets/popup/dict-media.js hibiki/assets/popup/selection.js tools/browser-extension/vendor/
```

- [ ] **Step 2: bridge-shim.js**（仿 Android PopupDictActivity.kt:363-380，把 callHandler 转 chrome.runtime.sendMessage）
```js
// 垫掉 popup.js 里的 flutter_inappwebview.callHandler，转成扩展逻辑。
// 必须在 popup.js 之前加载（manifest content_scripts 顺序保证）。
window.flutter_inappwebview = {
  callHandler: function (name, ...args) {
    switch (name) {
      case 'popupRendered':
        if (window.__hibikiOnRendered) window.__hibikiOnRendered(args[0]);
        return Promise.resolve(null);
      case 'mineEntry':
        return new Promise((resolve) => {
          chrome.runtime.sendMessage(
            { type: 'mine', fields: args[0], sentence: (args[0] && args[0].popupSelectionText) || '' },
            (resp) => resolve(!!(resp && resp.ok && resp.data && resp.data.result === 'success')));
        });
      case 'duplicateCheck':
        return Promise.resolve(false); // 可后续接 /api/lookup/audio 式查重端点
      case 'onLinkClick':
        if (window.__hibikiOnLinkClick) window.__hibikiOnLinkClick(args[0]);
        return Promise.resolve(null);
      case 'tapOutside':
        if (window.__hibikiOnTapOutside) window.__hibikiOnTapOutside();
        return Promise.resolve(null);
      case 'openLink':
        try { window.open(args[0], '_blank'); } catch (_) {}
        return Promise.resolve(null);
      case 'resolveWordAudio':
      case 'playWordAudio':
      default:
        return Promise.resolve(null); // 音频等可选能力降级
    }
  },
};
```

- [ ] **Step 3: 验证 + 提交**（JSON/JS 语法手查）
```bash
git add tools/browser-extension/vendor tools/browser-extension/bridge-shim.js
git diff --cached --check && git commit -m "feat(webext): vendor popup.js + bridge-shim"
```

---

## Task 6: content.js 取词扫描 + Shadow DOM 弹窗 + 挖词（硬骨头）

**Files:** Create `tools/browser-extension/content.js`、`tools/browser-extension/scan.js`（取词纯函数，便于测）；可选 `tools/browser-extension/scan.test.js`（若有 node 环境）

- [ ] **Step 1: 取词纯函数 scan.js**
```js
// 给定一个 Range 起点（node, offset），向右扩取最长 maxLen 字的取词窗口。
// 纯函数（依赖 DOM Range API），便于 jsdom 测试。
function expandWordWindow(textNode, offset, maxLen) {
  const text = textNode.textContent || '';
  return text.slice(offset, offset + maxLen);
}
// 句子上下文：从 offset 向两侧扩到句末标点。
function extractSentence(text, offset) {
  const enders = /[。．.!?！？\n]/;
  let start = offset, end = offset;
  while (start > 0 && !enders.test(text[start - 1])) start--;
  while (end < text.length && !enders.test(text[end])) end++;
  return text.slice(start, end + 1).trim();
}
if (typeof module !== 'undefined') module.exports = { expandWordWindow, extractSentence };
```

- [ ] **Step 2: content.js**（修饰键 + caretRangeFromPoint 取词 → lookup → Shadow DOM 渲染 popup.js）
```js
// 取词扫描 + Shadow DOM 弹窗注入。修饰键默认 Shift。
const MOD = 'shiftKey';
const MAX_LEN = 12;
let shadowHost = null, shadowRoot = null;

function ensureShadow() {
  if (shadowHost) return shadowRoot;
  shadowHost = document.createElement('div');
  shadowHost.style.cssText = 'position:absolute;z-index:2147483647;top:0;left:0;';
  document.body.appendChild(shadowHost);
  shadowRoot = shadowHost.attachShadow({ mode: 'open' });
  const container = document.createElement('div');
  container.id = 'entries-container';
  shadowRoot.appendChild(container);
  return shadowRoot;
}

function caretFromPoint(x, y) {
  if (document.caretRangeFromPoint) return document.caretRangeFromPoint(x, y); // Chromium
  if (document.caretPositionFromPoint) { // Firefox
    const p = document.caretPositionFromPoint(x, y);
    if (!p) return null;
    const r = document.createRange();
    r.setStart(p.offsetNode, p.offset);
    return r;
  }
  return null;
}

document.addEventListener('mousemove', (e) => {
  if (!e[MOD]) return;
  const range = caretFromPoint(e.clientX, e.clientY);
  if (!range || range.startContainer.nodeType !== Node.TEXT_NODE) return;
  const term = expandWordWindow(range.startContainer, range.startOffset, MAX_LEN);
  if (!term.trim()) return;
  chrome.runtime.sendMessage({ type: 'lookup', term }, (resp) => {
    if (!resp || !resp.ok || !resp.data) return;
    renderPopup(resp.data.popupJson, e.pageX, e.pageY);
  });
});

function renderPopup(popupJson, x, y) {
  ensureShadow();
  shadowHost.style.left = x + 'px';
  shadowHost.style.top = y + 'px';
  try { window.lookupEntries = JSON.parse(popupJson); } catch (_) { window.lookupEntries = []; }
  window._noResultsMessage = 'No results';
  window.__hibikiOnTapOutside = () => { shadowHost.remove(); shadowHost = null; shadowRoot = null; };
  window.renderPopup(); // popup.js（已在 content_scripts 加载到页面）
}
document.addEventListener('keyup', (e) => {
  if (e.key === 'Shift' && shadowHost) { /* 可选：松开收起 */ }
});
```
> 注：popup.js 复用有一处现实约束——MV3 content script 与页面共享 DOM 但 JS 在 isolated world；`window.renderPopup`/`window.lookupEntries` 需在 content script 的 isolated world 里可达（popup.js 作为 content_scripts.js 注入即在该 world）。Shadow DOM 容器需 `#entries-container`，popup.js 找该 id 渲染。落地时若 popup.js 强依赖 `document` 顶层而非 shadowRoot，需在 content.js 里把渲染容器桥接给 popup.js（最小改：popup.js 用 `document.getElementById('entries-container')`，把 shadowRoot 的容器同 id；或退化为普通 div 不用 Shadow DOM，接受宿主样式风险）。**这是扩展唯一的集成不确定点，真浏览器联调时定。**

- [ ] **Step 3: 验证**（取词纯函数若有 node：`node --test` scan.test.js；否则 JSON/语法手查）+ 提交
```bash
git add tools/browser-extension/content.js tools/browser-extension/scan.js
git diff --cached --check && git commit -m "feat(webext): content script word scan + shadow dom popup"
```

---

## Self-Review
- Spec §4.1 后端 record（Task 3）+ /api/mine（Task 2）+ 窄接口（Task 1）+ 鉴权（沿用，Task 2 测 401）。§4.2 扩展 manifest/background/options（Task 4）+ vendor/bridge-shim（Task 5）+ content 取词/Shadow DOM/挖词（Task 6）。
- 占位符：content.js 的「Shadow DOM vs popup.js 容器」集成点明确标注为真浏览器联调点（JS 扩展无项目单测框架，端到端靠真浏览器，spec §6 已声明）。
- 真浏览器端到端验证留用户（Chrome + 运行中 Hibiki「互联」server）。
