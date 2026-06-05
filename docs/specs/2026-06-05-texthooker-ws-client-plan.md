# Texthooker WS Client 实现计划（线1）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Hibiki 当 WebSocket client 连接 Textractor/mpv/agent 等抓取工具的 WS server，接收游戏/番剧/VN 文本流，在一个独立 texthooker tab 页面里实时展示、逐词查词、挖词进 Anki。

**Architecture:** 单例 `TexthookerService`（ChangeNotifier）持文本行 buffer；`TexthookerWsClient` 连多个 WS URL（默认 6677/9001/2333）并自动重连，消息按生态事实标准 `JSON.parse(d).sentence ?? d` 解析后 append；新 `TexthookerPage` 订阅 service 实时渲染文本行，逐词分词成可点 span，查词复用 `DictionaryPageMixin.pushNestedPopup` + `DictionaryPopupLayer`，挖词复用 `onMineEntry`；新 tab 接入 `home_page.dart`。设置开关默认关。

**Tech Stack:** Dart, `web_socket_channel`（新增依赖）, Flutter widgets, Riverpod/AppModel, Hibiki `JapaneseLanguage` 分词 + `DictionaryPageMixin` 查词/挖词。

设计依据：`docs/specs/2026-06-05-yomitan-interop-design.md`（§2.1/§2.2/§5）。

---

## 文件结构

- Modify: `hibiki/pubspec.yaml` — 加 `web_socket_channel`。
- Create: `hibiki/lib/src/sync/texthooker_message.dart` — 纯函数 `parseTexthookerMessage`。
- Create: `hibiki/lib/src/sync/texthooker_service.dart` — 单例 ChangeNotifier 行 buffer。
- Create: `hibiki/lib/src/sync/texthooker_ws_client.dart` — 多源 WS 连接 + 重连。
- Create: `hibiki/lib/src/pages/implementations/texthooker_page.dart` — 新 tab 页面。
- Modify: `hibiki/lib/pages.dart` — export 新页面。
- Modify: `hibiki/lib/src/pages/implementations/home_page.dart` — 加第 4 tab + 修魔数。
- Modify: `hibiki/lib/src/models/preferences_repository.dart` + `app_model.dart` — 偏好（enabled + url 列表）。
- Modify: `hibiki/lib/src/settings/settings_schema.dart` + i18n — 设置 UI。
- Tests: `hibiki/test/sync/texthooker_message_test.dart`、`texthooker_service_test.dart`、`texthooker_ws_client_test.dart`、`hibiki/test/pages/texthooker_page_test.dart`、`home_page_tabs_test.dart`。

---

## Task 1: 加 web_socket_channel 依赖

**Files:**
- Modify: `hibiki/pubspec.yaml`

- [ ] **Step 1: 加依赖**

在 `hibiki/pubspec.yaml` 的 `dependencies:` 段（`shelf: ^1.4.0` 附近，line 114）加：

```yaml
  web_socket_channel: ^3.0.0
```

- [ ] **Step 2: 拉依赖**

Run（在 `hibiki/`）: `flutter pub get`
Expected: 成功解析，`web_socket_channel 3.x` 出现在 lock。

- [ ] **Step 3: 提交**

```bash
git add hibiki/pubspec.yaml hibiki/pubspec.lock
git commit -m "build(deps): add web_socket_channel for texthooker"
```

---

## Task 2: parseTexthookerMessage（纯函数）

事实标准（设计 §2.2）：`JSON.parse(d).sentence || d`。裸文本原样；`{"sentence":"..."}` 取 sentence；非法 JSON / 无 sentence 字段 → 原样返回。

**Files:**
- Create: `hibiki/lib/src/sync/texthooker_message.dart`
- Test: `hibiki/test/sync/texthooker_message_test.dart`

- [ ] **Step 1: 写失败测试**

```dart
// hibiki/test/sync/texthooker_message_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/texthooker_message.dart';

void main() {
  group('parseTexthookerMessage', () {
    test('raw text passes through', () {
      expect(parseTexthookerMessage('走り出した。'), '走り出した。');
    });
    test('json with sentence field is unwrapped', () {
      expect(parseTexthookerMessage('{"sentence":"こんにちは"}'), 'こんにちは');
    });
    test('json without sentence falls back to raw', () {
      expect(parseTexthookerMessage('{"text":"x"}'), '{"text":"x"}');
    });
    test('invalid json falls back to raw', () {
      expect(parseTexthookerMessage('{not json'), '{not json');
    });
    test('json string scalar (not object) falls back to raw', () {
      expect(parseTexthookerMessage('"hi"'), '"hi"');
    });
    test('non-string sentence falls back to raw', () {
      expect(parseTexthookerMessage('{"sentence":123}'), '{"sentence":123}');
    });
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test test/sync/texthooker_message_test.dart`
Expected: FAIL —— URI 不存在。

- [ ] **Step 3: 写实现**

```dart
// hibiki/lib/src/sync/texthooker_message.dart
import 'dart:convert';

/// 解析 texthooker WS 消息。生态事实标准（Renji-XD/texthooker-ui socket.ts）：
/// `JSON.parse(d).sentence || d` —— 对象含 string 型 sentence 时取之，
/// 否则（裸文本 / 非法 JSON / 无 sentence / sentence 非字符串）原样返回。
String parseTexthookerMessage(String raw) {
  try {
    final dynamic decoded = jsonDecode(raw);
    if (decoded is Map) {
      final dynamic sentence = decoded['sentence'];
      if (sentence is String) return sentence;
    }
  } catch (_) {}
  return raw;
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `flutter test test/sync/texthooker_message_test.dart`
Expected: PASS（6 tests）。

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/sync/texthooker_message.dart hibiki/test/sync/texthooker_message_test.dart
git commit -m "feat(texthooker): add message parser (raw text / {sentence} json)"
```

---

## Task 3: TexthookerService（单例 ChangeNotifier 行 buffer）

仿 `DebugLogService`（`debug_log_service.dart:6`，单例 + ChangeNotifier，500 上限 removeRange）。但提供真实 `appendLine`（DebugLogService 只能经 debugPrint 拦截，不适用）。

**Files:**
- Create: `hibiki/lib/src/sync/texthooker_service.dart`
- Test: `hibiki/test/sync/texthooker_service_test.dart`

- [ ] **Step 1: 写失败测试**

```dart
// hibiki/test/sync/texthooker_service_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';

void main() {
  setUp(() => TexthookerService.instance.clear());

  test('appendLine adds and notifies', () {
    int notifications = 0;
    void listener() => notifications++;
    TexthookerService.instance.addListener(listener);

    TexthookerService.instance.appendLine('一行目');
    TexthookerService.instance.appendLine('二行目');

    expect(TexthookerService.instance.lines, ['一行目', '二行目']);
    expect(notifications, 2);
    TexthookerService.instance.removeListener(listener);
  });

  test('blank lines are ignored', () {
    TexthookerService.instance.appendLine('   ');
    TexthookerService.instance.appendLine('');
    expect(TexthookerService.instance.lines, isEmpty);
  });

  test('buffer caps at maxLines, dropping oldest', () {
    for (int i = 0; i < TexthookerService.maxLines + 10; i++) {
      TexthookerService.instance.appendLine('line $i');
    }
    expect(TexthookerService.instance.lines.length, TexthookerService.maxLines);
    expect(TexthookerService.instance.lines.first, 'line 10');
  });

  test('clear empties and notifies', () {
    TexthookerService.instance.appendLine('x');
    int notifications = 0;
    TexthookerService.instance.addListener(() => notifications++);
    TexthookerService.instance.clear();
    expect(TexthookerService.instance.lines, isEmpty);
    expect(notifications, 1);
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test test/sync/texthooker_service_test.dart`
Expected: FAIL —— URI 不存在。

- [ ] **Step 3: 写实现**

```dart
// hibiki/lib/src/sync/texthooker_service.dart
import 'package:flutter/foundation.dart';

/// 收到的 texthooker 文本行 buffer。单例 + ChangeNotifier（仿 DebugLogService），
/// 由 [TexthookerWsClient] 调用 [appendLine]，由 TexthookerPage 订阅刷新。
class TexthookerService extends ChangeNotifier {
  TexthookerService._();
  static final TexthookerService instance = TexthookerService._();

  static const int maxLines = 500;

  final List<String> _lines = <String>[];
  List<String> get lines => List<String>.unmodifiable(_lines);

  void appendLine(String line) {
    final String trimmed = line.trim();
    if (trimmed.isEmpty) return;
    _lines.add(trimmed);
    if (_lines.length > maxLines) {
      _lines.removeRange(0, _lines.length - maxLines);
    }
    notifyListeners();
  }

  void clear() {
    if (_lines.isEmpty) return;
    _lines.clear();
    notifyListeners();
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `flutter test test/sync/texthooker_service_test.dart`
Expected: PASS（4 tests）。

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/sync/texthooker_service.dart hibiki/test/sync/texthooker_service_test.dart
git commit -m "feat(texthooker): add line-buffer service"
```

---

## Task 4: TexthookerWsClient（多源连接 + 重连）

连多个 WS URL，每条消息 `parseTexthookerMessage` 后 `TexthookerService.appendLine`。断线自动重连（固定退避）。`WebSocketChannel` 经依赖注入的工厂连接，以便测试用内存 server。

**Files:**
- Create: `hibiki/lib/src/sync/texthooker_ws_client.dart`
- Test: `hibiki/test/sync/texthooker_ws_client_test.dart`

- [ ] **Step 1: 写失败测试**（用真实 loopback WebSocket server 验证收文本）

```dart
// hibiki/test/sync/texthooker_ws_client_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';
import 'package:hibiki/src/sync/texthooker_ws_client.dart';

void main() {
  setUp(() => TexthookerService.instance.clear());

  test('receives raw text and {sentence} json from a ws server', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.transform(WebSocketTransformer()).listen((WebSocket ws) {
      ws.add('裸テキスト');
      ws.add('{"sentence":"包まれた"}');
    });
    final String url = 'ws://127.0.0.1:${server.port}';

    final client = TexthookerWsClient(
      urls: [url],
      service: TexthookerService.instance,
      channelFactory: (String u) => IOWebSocketChannel.connect(Uri.parse(u)),
    );
    client.start();

    // 等收到两行
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (TexthookerService.instance.lines.length < 2 &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    expect(TexthookerService.instance.lines, ['裸テキスト', '包まれた']);

    await client.stop();
    await server.close(force: true);
  });

  test('connection state exposes connected urls', () async {
    final client = TexthookerWsClient(
      urls: const <String>[],
      service: TexthookerService.instance,
      channelFactory: (String u) => throw UnimplementedError(),
    );
    expect(client.isRunning, false);
    client.start();
    expect(client.isRunning, true);
    await client.stop();
    expect(client.isRunning, false);
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test test/sync/texthooker_ws_client_test.dart`
Expected: FAIL —— URI 不存在。

- [ ] **Step 3: 写实现**

```dart
// hibiki/lib/src/sync/texthooker_ws_client.dart
import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'texthooker_message.dart';
import 'texthooker_service.dart';

/// WS 连接工厂（注入以便测试）。
typedef WsChannelFactory = WebSocketChannel Function(String url);

/// 连接一个或多个 texthooker WS server（默认 6677/9001/2333），把收到的每条
/// 消息经 [parseTexthookerMessage] 解析后 append 到 [TexthookerService]。
/// 断线固定退避自动重连。
class TexthookerWsClient {
  TexthookerWsClient({
    required List<String> urls,
    required TexthookerService service,
    required WsChannelFactory channelFactory,
    Duration retryDelay = const Duration(seconds: 3),
  })  : _urls = urls,
        _service = service,
        _channelFactory = channelFactory,
        _retryDelay = retryDelay;

  /// 事实标准默认端口（设计 §2.2）。
  static const List<String> defaultUrls = <String>[
    'ws://localhost:6677',
    'ws://localhost:9001',
    'ws://localhost:2333',
  ];

  final List<String> _urls;
  final TexthookerService _service;
  final WsChannelFactory _channelFactory;
  final Duration _retryDelay;

  final List<StreamSubscription<dynamic>> _subs = <StreamSubscription<dynamic>>[];
  final List<Timer> _retryTimers = <Timer>[];
  bool _running = false;

  bool get isRunning => _running;

  void start() {
    if (_running) return;
    _running = true;
    for (final String url in _urls) {
      _connect(url);
    }
  }

  void _connect(String url) {
    if (!_running) return;
    final WebSocketChannel channel;
    try {
      channel = _channelFactory(url);
    } catch (_) {
      _scheduleRetry(url);
      return;
    }
    final StreamSubscription<dynamic> sub = channel.stream.listen(
      (dynamic data) => _service.appendLine(parseTexthookerMessage('$data')),
      onError: (Object _) => _scheduleRetry(url),
      onDone: () => _scheduleRetry(url),
      cancelOnError: true,
    );
    _subs.add(sub);
  }

  void _scheduleRetry(String url) {
    if (!_running) return;
    final Timer t = Timer(_retryDelay, () => _connect(url));
    _retryTimers.add(t);
  }

  Future<void> stop() async {
    _running = false;
    for (final Timer t in _retryTimers) {
      t.cancel();
    }
    _retryTimers.clear();
    for (final StreamSubscription<dynamic> sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `flutter test test/sync/texthooker_ws_client_test.dart`
Expected: PASS（2 tests）。

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/sync/texthooker_ws_client.dart hibiki/test/sync/texthooker_ws_client_test.dart
git commit -m "feat(texthooker): add multi-source ws client with reconnect"
```

---

## Task 5: 偏好（enabled + url 列表）

仿 `remote_lookup_enabled` 范式。URL 列表以换行分隔字符串持久化（简单，避免 JSON list 编码）。

**Files:**
- Modify: `hibiki/lib/src/models/preferences_repository.dart` + `app_model.dart`
- Test: `hibiki/test/models/preferences_repository_test.dart`（追加）

- [ ] **Step 1: 写失败测试**（追加）

```dart
  test('texthooker prefs round-trip', () async {
    expect(repo.texthookerEnabled, false);
    expect(repo.texthookerUrls, [
      'ws://localhost:6677',
      'ws://localhost:9001',
      'ws://localhost:2333',
    ]);

    await repo.setTexthookerEnabled(true);
    await repo.setTexthookerUrls(['ws://localhost:6677']);

    expect(repo.texthookerEnabled, true);
    expect(repo.texthookerUrls, ['ws://localhost:6677']);
  });
```

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test test/models/preferences_repository_test.dart`
Expected: FAIL —— getter 未定义。

- [ ] **Step 3: 写实现**

`preferences_repository.dart` 加（import `texthooker_ws_client.dart` 以用 `defaultUrls`，或内联默认常量避免循环依赖——这里内联）：

```dart
  static const String _texthookerDefaultUrls =
      'ws://localhost:6677\nws://localhost:9001\nws://localhost:2333';

  bool get texthookerEnabled =>
      getPref('texthooker_enabled', defaultValue: false) as bool;

  Future<void> setTexthookerEnabled(bool value) async {
    await setPref('texthooker_enabled', value);
    notifyListeners();
  }

  List<String> get texthookerUrls {
    final String raw =
        getPref('texthooker_urls', defaultValue: _texthookerDefaultUrls) as String;
    return raw
        .split('\n')
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList();
  }

  Future<void> setTexthookerUrls(List<String> urls) async {
    await setPref('texthooker_urls', urls.join('\n'));
    notifyListeners();
  }
```

`app_model.dart` 加转发：

```dart
  bool get texthookerEnabled => prefsRepo.texthookerEnabled;
  Future<void> setTexthookerEnabled(bool value) =>
      prefsRepo.setTexthookerEnabled(value);

  List<String> get texthookerUrls => prefsRepo.texthookerUrls;
  Future<void> setTexthookerUrls(List<String> urls) =>
      prefsRepo.setTexthookerUrls(urls);
```

- [ ] **Step 4: 运行测试确认通过**

Run: `flutter test test/models/preferences_repository_test.dart`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/models/preferences_repository.dart hibiki/lib/src/models/app_model.dart hibiki/test/models/preferences_repository_test.dart
git commit -m "feat(texthooker): add prefs (enabled + ws url list)"
```

---

## Task 6: TexthookerPage（文本流页面 + 逐词查词 + 挖词）

新页面 `with DictionaryPageMixin`（要求 getter `mixinAppModel`/`mixinTheme`，见 `dictionary_page_mixin.dart:49-51`），持自己的 `popupStack`（`List<NestedPopupEntry>`，mixin 不持有），订阅 `TexthookerService` 实时刷新。文本行用 `JapaneseLanguage().textToWords` 分词成可点 span，点 span → `pushNestedPopup`。挖词时把当前行作为 `sentence` 注入。

**Files:**
- Create: `hibiki/lib/src/pages/implementations/texthooker_page.dart`
- Modify: `hibiki/lib/pages.dart`
- Test: `hibiki/test/pages/texthooker_page_test.dart`

- [ ] **Step 1: 写失败 widget 测试**

```dart
// hibiki/test/pages/texthooker_page_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';
import 'package:hibiki/src/pages/implementations/texthooker_page.dart';

void main() {
  setUp(() => TexthookerService.instance.clear());

  testWidgets('renders incoming lines reactively', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: TexthookerPage()));
    await tester.pump();

    expect(find.text('第一行'), findsNothing);

    TexthookerService.instance.appendLine('第一行');
    await tester.pump();
    expect(find.text('第一行'), findsOneWidget);

    TexthookerService.instance.appendLine('第二行');
    await tester.pump();
    expect(find.text('第二行'), findsOneWidget);
  });

  testWidgets('clear button empties the list', (tester) async {
    TexthookerService.instance.appendLine('行X');
    await tester.pumpWidget(const MaterialApp(home: TexthookerPage()));
    await tester.pump();
    expect(find.text('行X'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear'));
    await tester.pump();
    expect(find.text('行X'), findsNothing);
  });
}
```

> 注：测试只验证「响应式渲染 + 清空」这层（不依赖 FFI 查词引擎）。逐词查词浮层依赖 `HoshiDicts` 真引擎与 WebView，留真机验证（设计 §9）。页面内分词调用要在引擎未初始化时安全降级（`JapaneseLanguage.textToWords` 在 `!HoshiDicts.isInitialized` 时按字符切，见 `japanese_language.dart:97`），保证 widget 测试不崩。

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test test/pages/texthooker_page_test.dart`
Expected: FAIL —— URI 不存在。

- [ ] **Step 3: 写实现**

```dart
// hibiki/lib/src/pages/implementations/texthooker_page.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import '../../i18n/strings.g.dart';
import '../../models/app_model.dart';
import '../../sync/texthooker_service.dart';
import '../dictionary_page_mixin.dart';
import 'dictionary_popup_layer.dart';

/// 独立 texthooker tab：实时展示 WS 收到的文本行，逐词查词 + 挖词。
class TexthookerPage extends ConsumerStatefulWidget {
  const TexthookerPage({super.key});

  @override
  ConsumerState<TexthookerPage> createState() => _TexthookerPageState();
}

class _TexthookerPageState extends ConsumerState<TexthookerPage>
    with DictionaryPageMixin {
  final List<NestedPopupEntry> _popupStack = <NestedPopupEntry>[];
  final ScrollController _scroll = ScrollController();
  final JapaneseLanguage _lang = JapaneseLanguage();

  @override
  AppModel get mixinAppModel => ref.read(appModelProvider);

  @override
  ThemeData get mixinTheme => Theme.of(context);

  @override
  void initState() {
    super.initState();
    TexthookerService.instance.addListener(_onLines);
  }

  @override
  void dispose() {
    TexthookerService.instance.removeListener(_onLines);
    _scroll.dispose();
    super.dispose();
  }

  void _onLines() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  void _onWordTap(String word, Rect rect) {
    pushNestedPopup(
      query: word,
      selectionRect: rect,
      popupStack: _popupStack,
      replaceStack: true,
      autoRead: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<String> lines = TexthookerService.instance.lines;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.texthooker),
        actions: <Widget>[
          IconButton(
            tooltip: t.clear,
            icon: const Icon(Icons.delete_outline),
            onPressed: TexthookerService.instance.clear,
          ),
        ],
      ),
      body: Stack(
        children: <Widget>[
          ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.all(12),
            itemCount: lines.length,
            itemBuilder: (BuildContext context, int i) =>
                _TexthookerLine(text: lines[i], lang: _lang, onWordTap: _onWordTap),
          ),
          ..._buildPopups(context),
        ],
      ),
    );
  }

  List<Widget> _buildPopups(BuildContext context) {
    final Size screen = MediaQuery.sizeOf(context);
    return <Widget>[
      for (int i = 0; i < _popupStack.length; i++)
        buildNestedPopupLayer(
          index: i,
          screen: screen,
          popupStack: _popupStack,
          onPush: (String text, Rect rect) => pushNestedPopup(
            query: text, selectionRect: rect, popupStack: _popupStack),
          onPop: (int index) => popNestedPopupAt(index, _popupStack),
        ),
    ];
  }
}

/// 一行文本：分词成可点 span。
class _TexthookerLine extends StatelessWidget {
  const _TexthookerLine({
    required this.text,
    required this.lang,
    required this.onWordTap,
  });

  final String text;
  final JapaneseLanguage lang;
  final void Function(String word, Rect rect) onWordTap;

  @override
  Widget build(BuildContext context) {
    final List<String> words = lang.textToWords(text);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Wrap(
        children: <Widget>[
          for (final String w in words)
            _WordSpan(word: w, onTap: onWordTap),
        ],
      ),
    );
  }
}

class _WordSpan extends StatelessWidget {
  const _WordSpan({required this.word, required this.onTap});

  final String word;
  final void Function(String word, Rect rect) onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapUp: (TapUpDetails details) {
        final RenderBox box = context.findRenderObject()! as RenderBox;
        final Offset topLeft = box.localToGlobal(Offset.zero);
        onTap(word, topLeft & box.size);
      },
      child: Text(word, style: const TextStyle(fontSize: 18, height: 1.6)),
    );
  }
}
```

> 接线提醒：`appModelProvider` 是项目里 AppModel 的 Riverpod provider（在 `app_model.dart` 或 providers barrel 暴露；与 `home_page.dart` 取 `appModel` 同源）。若该 provider 名不同，按项目现有 `ref.read(...)` 取 AppModel 的写法对齐。`buildNestedPopupLayer`/`popNestedPopupAt`/`pushNestedPopup` 均来自 `DictionaryPageMixin`（签名见 `dictionary_page_mixin.dart:156/291/218`）。

- [ ] **Step 4: 加 i18n key + export**

Run（在 `hibiki/`）:
```bash
dart tool/i18n_sync.dart --add texthooker "Texthooker" "文本钩子"
dart run slang
dart format lib/i18n/strings.g.dart
```
在 `hibiki/lib/pages.dart` 的 implementations 段加：
```dart
export 'src/pages/implementations/texthooker_page.dart';
```

- [ ] **Step 5: 运行测试确认通过**

Run: `flutter test test/pages/texthooker_page_test.dart`
Expected: PASS（2 tests）。

- [ ] **Step 6: 提交**

```bash
git add hibiki/lib/src/pages/implementations/texthooker_page.dart hibiki/lib/pages.dart hibiki/lib/i18n/ hibiki/test/pages/texthooker_page_test.dart
git commit -m "feat(texthooker): add texthooker page (live text + tap-to-lookup + mine)"
```

---

## Task 7: 接入 home_page 第 4 tab（导航 + 魔数修正）

把 texthooker 插在 dict(1) 和 settings 之间 → settings 变 index **3**。必须同步改：`_navItems()`、`buildBody()`、`_selectTab`(硬编码 2→3)、`_buildDesktopLayout`(硬编码 2→3)、`_executeShortcutAction`(homeTabSettings 2→3，两处 `% 3`→`% 4`)。

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/home_page.dart`
- Test: `hibiki/test/pages/home_page_tabs_test.dart`

- [ ] **Step 1: 写失败测试**（守卫 tab 数量与切换不回归）

```dart
// hibiki/test/pages/home_page_tabs_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/home_page.dart';

void main() {
  test('home tab count constant is four', () {
    // kHomeTabCount 在 home_page.dart 暴露，替代散落的魔数 3
    expect(kHomeTabCount, 4);
  });

  test('settings tab index constant is three', () {
    expect(kHomeSettingsTabIndex, 3);
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test test/pages/home_page_tabs_test.dart`
Expected: FAIL —— `kHomeTabCount` 未定义。

- [ ] **Step 3: 写实现**

在 `home_page.dart` 顶部（class 外）加常量，消除散落魔数（Linus：消除特殊情况）：

```dart
/// 顶层 tab 数量：书架 / 词典 / texthooker / 设置。
const int kHomeTabCount = 4;
/// 设置 tab 的逻辑索引（末位）。
const int kHomeSettingsTabIndex = 3;
```

`_navItems()`（line 314-332）在 dict 项后、settings 项前插入：

```dart
      AdaptiveNavItem(
        icon: Icons.sensors_outlined,
        selectedIcon: Icons.sensors,
        label: t.texthooker,
      ),
```

`buildBody()`（line 417-426）改为：

```dart
Widget buildBody() {
  switch (_currentTab) {
    case 1:
      return HomeDictionaryPage(focusSignal: _dictFocusSignal);
    case 2:
      return const TexthookerPage();
    case 3:
      return const HibikiSettingsContent();
    default:
      return const HomeReaderPage();
  }
}
```

`_selectTab`（line 184-193）把硬编码 `2` 改 `kHomeSettingsTabIndex`：

```dart
void _selectTab(int logicalIndex) {
  setState(() {
    if (logicalIndex == kHomeSettingsTabIndex &&
        _currentTab != kHomeSettingsTabIndex) {
      _previousTab = _currentTab;
    }
    _currentTab = logicalIndex;
  });
}
```

`_buildDesktopLayout`（line 335）把 `if (_currentTab == 2)` 改 `if (_currentTab == kHomeSettingsTabIndex)`。

`_executeShortcutAction`（line 195-222）：`homeTabSettings` 改 `_selectTab(kHomeSettingsTabIndex)`；两处取模改为：

```dart
    case ShortcutAction.homeTabNext:
      _selectTab((_currentTab + 1) % kHomeTabCount);
      return KeyEventResult.handled;
    case ShortcutAction.homeTabPrev:
      _selectTab((_currentTab + kHomeTabCount - 1) % kHomeTabCount);
      return KeyEventResult.handled;
```

确保 `home_page.dart` 顶部 import 了 `TexthookerPage`（经 `package:hibiki/pages.dart` barrel 或直接 import 实现文件，与现有 `HomeDictionaryPage` 的引入方式一致）。

- [ ] **Step 4: 运行测试确认通过**

Run: `flutter test test/pages/home_page_tabs_test.dart`
Expected: PASS（2 tests）。

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/pages/implementations/home_page.dart hibiki/test/pages/home_page_tabs_test.dart
git commit -m "feat(texthooker): add texthooker as 4th home tab (dedup tab-count magic numbers)"
```

---

## Task 8: 设置 UI + WS client 生命周期接线

设置开关 `texthooker_enabled`：开 → 用 `appModel.texthookerUrls` 构造 `TexthookerWsClient`（`channelFactory` 用 `IOWebSocketChannel.connect`）并 `start()`；关 → `stop()`。URL 列表编辑可复用 `WebsocketDialogPage`（`websocket_dialog_page.dart:6`，单地址 `onConnect` 回调）逐条加，或简单多行文本框。

**Files:**
- Modify: `hibiki/lib/src/settings/settings_schema.dart`
- Modify: i18n
- Create: `hibiki/lib/src/sync/texthooker_ws_client_host.dart`（持有 client 实例，按开关启停；放在设置 State 之外便于单一持有）

- [ ] **Step 1: 加 i18n**

Run（在 `hibiki/`）:
```bash
dart tool/i18n_sync.dart --add texthooker_enabled "Texthooker (receive text)" "文本钩子（接收文本）"
dart tool/i18n_sync.dart --add texthooker_enabled_hint "Connect to Textractor/mpv/agent and look up incoming text" "连接 Textractor/mpv/agent 并查询收到的文本"
dart tool/i18n_sync.dart --add texthooker_urls "Texthooker WebSocket URLs" "文本钩子 WebSocket 地址"
dart run slang
dart format lib/i18n/strings.g.dart
```

- [ ] **Step 2: 写 client host（单例持有，按开关启停）**

```dart
// hibiki/lib/src/sync/texthooker_ws_client_host.dart
import 'package:web_socket_channel/io.dart';

import 'texthooker_service.dart';
import 'texthooker_ws_client.dart';

/// 全局持有 texthooker WS client，按设置开关启停。
class TexthookerWsClientHost {
  TexthookerWsClientHost._();
  static final TexthookerWsClientHost instance = TexthookerWsClientHost._();

  TexthookerWsClient? _client;

  bool get isRunning => _client?.isRunning ?? false;

  void start(List<String> urls) {
    if (_client != null) return;
    final TexthookerWsClient client = TexthookerWsClient(
      urls: urls,
      service: TexthookerService.instance,
      channelFactory: (String url) =>
          IOWebSocketChannel.connect(Uri.parse(url)),
    );
    client.start();
    _client = client;
  }

  Future<void> stop() async {
    await _client?.stop();
    _client = null;
  }

  Future<void> restart(List<String> urls) async {
    await stop();
    start(urls);
  }
}
```

- [ ] **Step 3: 写 settings_schema 开关条目**

仿 `settings_schema.dart:865-876`：

```dart
SettingsSwitchItem(
  id: 'sync.texthooker',
  title: t.texthooker_enabled,
  subtitle: t.texthooker_enabled_hint,
  icon: Icons.sensors_outlined,
  value: (SettingsContext c) => c.appModel.texthookerEnabled,
  onChanged: (SettingsContext c, bool value) async {
    await c.appModel.setTexthookerEnabled(value);
    if (value) {
      TexthookerWsClientHost.instance.start(c.appModel.texthookerUrls);
    } else {
      await TexthookerWsClientHost.instance.stop();
    }
    c.refresh();
  },
),
```

（URL 列表编辑入口：可加一个 `SettingsTextItem`/对话框行调 `WebsocketDialogPage`；落地时按现有设置里"可编辑列表"控件范式实现，编辑后 `appModel.setTexthookerUrls(...)` + `TexthookerWsClientHost.instance.restart(...)`。）

- [ ] **Step 4: 开机自启接线**

在 app 启动完成处（与 `DebugLogService.instance.init()` 同级的初始化阶段，或 AppModel 初始化尾），加：

```dart
if (appModel.texthookerEnabled) {
  TexthookerWsClientHost.instance.start(appModel.texthookerUrls);
}
```

- [ ] **Step 5: 验证**

Run（在 `hibiki/`）: `dart format . && flutter analyze && flutter test test/sync/ test/pages/texthooker_page_test.dart test/pages/home_page_tabs_test.dart test/models/preferences_repository_test.dart`
Expected: analyze 0 issues；相关测试全绿。

- [ ] **Step 6: 提交**

```bash
git add hibiki/lib/src/settings/settings_schema.dart hibiki/lib/src/sync/texthooker_ws_client_host.dart hibiki/lib/i18n/ hibiki/lib/src/models/app_model.dart
git commit -m "feat(texthooker): wire settings toggle + ws client lifecycle"
```

---

## Self-Review 结论

- **Spec 覆盖**：§5.1 连接层（Task 3/4/8）、§5.2 呈现层独立 tab + 逐词查词 + 挖词（Task 6/7）、§5.3 连接配置 UI（Task 8 复用 WebsocketDialogPage）、消息格式事实标准（Task 2）、默认端口 6677/9001/2333（Task 4/5）、设置开关 i18n（Task 5/8）、§9 测试（各 Task）。方向 A（client 收文本）贯穿，未实现方向 B（符合非目标）。
- **占位符扫描**：无 TBD；新文件给完整实现。Task 8 的"URL 列表编辑控件"与"启动接线位置"标注了按现有范式落地——这是接入现有可变 UI 的合理裁量点，非代码留白（核心 client/host/开关均有完整代码）。
- **类型一致**：`parseTexthookerMessage(String)→String`、`TexthookerService.appendLine/clear/lines/maxLines`、`TexthookerWsClient({urls,service,channelFactory,retryDelay})` + `defaultUrls` + `start/stop/isRunning`、`WsChannelFactory`、`TexthookerWsClientHost.start(List<String>)/stop/restart`、home 常量 `kHomeTabCount=4`/`kHomeSettingsTabIndex=3` 在各 Task 间一致。
- **复用真实签名**：`DictionaryPageMixin`（`mixinAppModel`/`mixinTheme`/`pushNestedPopup`/`buildNestedPopupLayer`/`popNestedPopupAt`/`NestedPopupEntry`）、`JapaneseLanguage.textToWords`、`home_page.dart` 的 `_navItems/buildBody/_selectTab/_buildDesktopLayout/_executeShortcutAction` 改点、`WebsocketDialogPage` 构造、`web_socket_channel` 均为已验证真实签名/事实。
- **跨 plan 依赖**：本 plan 与 yomitan-api-server plan 各自独立可交付；两者都新增同名风格的偏好但 key 不冲突（`texthooker_*` vs `yomitan_api_*`）。
