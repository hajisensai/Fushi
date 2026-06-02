# Hibiki 互联 LAN 配对 + 点击实时反馈 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 点击局域网发现的 Hibiki 设备时，通过服务端「配对窗口 + /api/pair 接口」自动拉取并填入 token，同时修复「点击后客户端配置界面不刷新」的 bug。

**Architecture:** 服务端 `HibikiSyncServer` 新增一个限时配对窗口（类似蓝牙配对模式）和一个免认证的 `POST /api/pair` 接口，仅在窗口开启期间返回 token；服务端设置页加「开启配对」按钮触发窗口。客户端点击发现设备时 `POST /api/pair`，成功则把 URL + token 写库。修复 stale-state 的根因：把 `_SyncSettingsState` 升级为单一真相源 + 一个 `ValueNotifier` 修订号，客户端配置组件订阅它，配对写库后 bump 修订号触发重载（URL 总是重载，token 仅在输入框无焦点时重载，避免覆盖正在输入的内容）。

**Tech Stack:** Dart / Flutter 3.41.6、shelf（服务端 HTTP）、package:http（客户端）、Slang i18n、flutter_test。

---

## 背景事实（实现前必读）

- 文件均在 `D:\APP\vs_claude_code\hibiki\hibiki\` 下；命令在该目录执行（除 i18n_sync 注明外）。
- 服务端：`lib/src/sync/hibiki_sync_server.dart`
  - `HibikiSyncServer` 构造持有 `_token`、`_allowLan`；`_authMiddleware()`（106-118 行）对所有非 OPTIONS 请求要求 HTTP Basic 认证；`_handleRequest()`（145-180 行）按路径分发，已有 `/api/lookup/` 分支。
  - 威胁模型（13-23 行注释）：明文 HTTP + Basic，token 每次请求 base64 近乎明文，**仅限可信 LAN**。配对窗口接口与此模型一致：用户在服务端显式开窗，60 秒内任何 LAN 设备能取 token——等同蓝牙配对模式，是用户已选定的方案。
- 设置 UI：`lib/src/sync/sync_settings_schema.dart`
  - `_SyncSettingsState`（1996-2028 行）+ 全局缓存 `_activeSyncState` / `_syncSettings(ctx)`（229-237 行）：按 `AppModel` 缓存的共享状态，是跨组件协调的天然单一真相源。
  - `_HibikiServerConfigWidget`（**客户端**配置，名字有误导，1318-1624 行）：持 `_tokenController`、`_urls`；只在 `initState→_load()`（1351-1360 行）加载一次，`refresh()` 不会重载（State 被复用，`initState` 不重跑）——这是「点击无反应」的根因。token 输入框在 1601-1605 行。
  - `_ServerModeWidget`（**服务端**，1628-1869 行）：持 `_server`（`HibikiSyncServer?`）、`_token`；`_startServer()`（1712 行）。服务器运行时 UI 在 1790 行起。
  - `_LanDiscoveryWidget`（1872-1994 行）：`_connectToDevice(device)`（1940-1950 行）当前只写 URL + `refresh()` + snackbar。设备 tile onTap 在 1988 行。
- 客户端仓库方法（`lib/src/sync/sync_repository.dart`，已存在）：`getHibikiClientUrls()`、`getHibikiClientToken()`、`setHibikiClientToken(String?)`、`addHibikiClientUrl(String)`、`setBackendType(...)`。
- `HibikiTextField`（`lib/src/utils/components/hibiki_material_components.dart:305`）支持可选 `focusNode`。
- i18n：基准 `lib/i18n/strings.i18n.json`（英文），中文 `strings_zh-CN.i18n.json`，共 17 文件，键为扁平 `sync_*`。**禁止手改**，用 `hibiki/tool/i18n_sync.dart`。slang 参数语法示例：`"${n} seconds"`、`"Already used by: $s"`。
- 验证工具链：项目 Flutter 3.41.6。本机若 flutter 不在 PATH，按 `CLAUDE.local.md` 写完整路径。测试按记忆 `--no-pub`：`flutter test --no-pub <file>`。

## 文件结构

| 文件 | 职责 | 操作 |
|---|---|---|
| `lib/src/sync/hibiki_sync_server.dart` | 配对窗口状态 + `/api/pair` 接口 + 认证白名单 | 修改 |
| `lib/src/sync/sync_settings_schema.dart` | 共享修订号；服务端「开启配对」按钮；客户端订阅重载；客户端 `_connectToDevice` 改为 /api/pair 拉取 | 修改 |
| `lib/i18n/strings*.i18n.json` + `strings.g.dart` | 5 个新 i18n 键 | 经 i18n_sync 生成 |
| `test/sync/hibiki_sync_server_pair_test.dart` | 配对接口单元/集成测试（loopback） | 新建 |

---

## Task 1: 服务端配对窗口状态 + /api/pair 接口（TDD）

**Files:**
- Modify: `lib/src/sync/hibiki_sync_server.dart`
- Test: `test/sync/hibiki_sync_server_pair_test.dart`（新建）

- [ ] **Step 1: 写失败测试**

新建 `test/sync/hibiki_sync_server_pair_test.dart`：

```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:http/http.dart' as http;

void main() {
  late Directory tempDir;
  late HibikiSyncServer server;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('hibiki_pair_test');
    server = HibikiSyncServer(
      syncDataDir: tempDir.path,
      port: 0, // ephemeral
      token: 'super-secret-token',
      allowLan: true,
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Uri pairUri() => Uri.parse('http://127.0.0.1:${server.port}/api/pair');

  test('POST /api/pair returns 403 when pairing window is closed', () async {
    final http.Response resp = await http.post(pairUri());
    expect(resp.statusCode, 403);
  });

  test('POST /api/pair returns the token while the window is open', () async {
    server.openPairing(window: const Duration(seconds: 60));
    final http.Response resp = await http.post(pairUri());
    expect(resp.statusCode, 200);
    final Map<String, dynamic> body =
        jsonDecode(resp.body) as Map<String, dynamic>;
    expect(body['token'], 'super-secret-token');
  });

  test('GET /api/pair is rejected with 405', () async {
    server.openPairing(window: const Duration(seconds: 60));
    final http.Response resp = await http.get(pairUri());
    expect(resp.statusCode, 405);
  });

  test('pairing endpoint needs no auth header (bypasses Basic auth)', () async {
    // No Authorization header at all, yet a normal WebDAV path returns 401.
    final http.Response davResp =
        await http.get(Uri.parse('http://127.0.0.1:${server.port}/'));
    expect(davResp.statusCode, 401);
    server.openPairing();
    final http.Response pairResp = await http.post(pairUri());
    expect(pairResp.statusCode, 200);
  });

  test('window expires: 403 again after it elapses', () async {
    server.openPairing(window: const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 120));
    final http.Response resp = await http.post(pairUri());
    expect(resp.statusCode, 403);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test --no-pub test/sync/hibiki_sync_server_pair_test.dart`
Expected: FAIL —`openPairing` 未定义 / `/api/pair` 返回 401 或 404。

- [ ] **Step 3: 实现服务端配对窗口 + 接口**

在 `hibiki_sync_server.dart` 的 `HibikiSyncServer` 类里，`HttpServer? _server;`（71 行）之后加字段与方法：

```dart
  /// Pairing window: while [isPairingOpen] is true, an unauthenticated client
  /// may POST /api/pair to fetch [_token]. The user explicitly opens this
  /// short window on the server device (Bluetooth-style pairing), so the raw
  /// token is only handed out during a window they deliberately opened.
  DateTime? _pairingExpiry;

  void openPairing({Duration window = const Duration(seconds: 60)}) {
    _pairingExpiry = DateTime.now().add(window);
  }

  bool get isPairingOpen {
    final DateTime? expiry = _pairingExpiry;
    return expiry != null && DateTime.now().isBefore(expiry);
  }
```

在 `_authMiddleware()`（109 行的 OPTIONS 判断之后）加配对白名单：

```dart
        if (request.method == 'OPTIONS') return innerHandler(request);
        // Pairing is the one unauthenticated route: the client has no token
        // yet — that is exactly what it is fetching. Gating is done by the
        // pairing window inside _handlePair, not by Basic auth.
        if (request.url.path == 'api/pair') return innerHandler(request);
```

在 `_handleRequest()` 里，`if (reqPath.startsWith('/api/lookup/'))`（148 行）之前加分发：

```dart
    if (reqPath == '/api/pair') {
      return _handlePair(method);
    }
```

在 `_handleLookupApi(...)` 方法之前（约 182 行）加处理函数：

```dart
  shelf.Response _handlePair(String method) {
    if (method != 'POST') return shelf.Response(405);
    if (!isPairingOpen) {
      return shelf.Response(403, body: 'Pairing window closed');
    }
    return _jsonResponse(<String, dynamic>{'token': _token});
  }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test --no-pub test/sync/hibiki_sync_server_pair_test.dart`
Expected: PASS（5 个用例全过）。

- [ ] **Step 5: analyze + 提交**

```bash
dart format lib/src/sync/hibiki_sync_server.dart test/sync/hibiki_sync_server_pair_test.dart
flutter analyze lib/src/sync/hibiki_sync_server.dart test/sync/hibiki_sync_server_pair_test.dart
git add lib/src/sync/hibiki_sync_server.dart test/sync/hibiki_sync_server_pair_test.dart
git commit -m "feat(sync): add LAN pairing window + /api/pair endpoint"
```

---

## Task 2: 新增 5 个 i18n 键

**Files:**
- Modify（经脚本）: `lib/i18n/strings*.i18n.json`、`lib/i18n/strings.g.dart`

- [ ] **Step 1: 用 i18n_sync 添加键**

在 `hibiki/` 目录依次执行（每条 `--add <key> <en> <zh>`）：

```bash
dart run tool/i18n_sync.dart --add sync_pair_open_button "Allow pairing" "开启配对"
dart run tool/i18n_sync.dart --add sync_pair_window_open "Pairing open: \${n}s" "配对开启中：剩 \${n} 秒"
dart run tool/i18n_sync.dart --add sync_pair_success "Paired — token filled in" "配对成功，已自动填入 token"
dart run tool/i18n_sync.dart --add sync_pair_window_closed "Open pairing on the other device first" "请先在对方设备上开启配对"
dart run tool/i18n_sync.dart --add sync_pair_failed "Pairing failed" "配对失败"
```

注意：`${n}` 是 slang 参数占位，shell 里用 `\${n}` 防止被展开。若脚本对参数键报错，则改为先 `--add` 普通文案，再手动确认 `${n}` 已正确写入 17 个文件的该键（仍不要逐个手动新增键）。

- [ ] **Step 2: 重新生成 strings.g.dart 并格式化**

```bash
dart run slang
dart format lib/i18n/strings.g.dart
```

- [ ] **Step 3: 验证键已生成**

Run: `grep -c "sync_pair_open_button\|sync_pair_window_open\|sync_pair_success\|sync_pair_window_closed\|sync_pair_failed" lib/i18n/strings.g.dart`
Expected: 计数 ≥ 5（getter 已生成）。`flutter analyze lib/i18n/strings.g.dart` 无错。

- [ ] **Step 4: 提交**

```bash
git add lib/i18n/strings.i18n.json lib/i18n/strings_*.i18n.json lib/i18n/strings.g.dart
git commit -m "i18n(sync): add LAN pairing strings"
```

---

## Task 3: 共享修订号——修复客户端配置 stale-state（根因修复）

**Files:**
- Modify: `lib/src/sync/sync_settings_schema.dart`

- [ ] **Step 1: 给 `_SyncSettingsState` 加修订号（单一真相源的变更信号）**

在 `_SyncSettingsState` 类（1996 行）字段区加：

```dart
  /// Bumped whenever the persisted Hibiki *client* config (URLs / token) is
  /// mutated from outside the client-config widget (e.g. LAN pairing). The
  /// client-config widget listens and reloads — this is the single source of
  /// truth replacing the previous "loaded once in initState" stale state.
  final ValueNotifier<int> clientConfigRevision = ValueNotifier<int>(0);

  void reloadClientConfig() => clientConfigRevision.value++;
```

确认文件顶部已 `import 'package:flutter/foundation.dart';` 或通过 `package:flutter/material.dart` 间接引入 `ValueNotifier`（material 已导出 foundation，通常已有）。若 analyze 报 `ValueNotifier` 未定义，补 `import 'package:flutter/foundation.dart';`。

- [ ] **Step 2: 客户端组件订阅修订号并重载（带 token 焦点保护）**

改 `_HibikiServerConfigWidgetState`（1327 行起）：

字段区（1333 行 `bool _loaded = false;` 之后）加：

```dart
  late final FocusNode _tokenFocus;
```

`initState`（1339-1343 行）改为：

```dart
  @override
  void initState() {
    super.initState();
    _tokenController = TextEditingController();
    _tokenFocus = FocusNode();
    _load();
    _syncSettings(widget.settingsContext)
        .clientConfigRevision
        .addListener(_onClientConfigRevision);
  }
```

`dispose`（1345-1349 行）改为：

```dart
  @override
  void dispose() {
    _syncSettings(widget.settingsContext)
        .clientConfigRevision
        .removeListener(_onClientConfigRevision);
    _tokenFocus.dispose();
    _tokenController.dispose();
    super.dispose();
  }
```

在 `_load()`（1351-1360 行）之后加重载回调。URL 总是重载；token 仅在输入框无焦点时重载（避免覆盖用户正在输入的内容）：

```dart
  void _onClientConfigRevision() {
    unawaited(_reloadFromStore());
  }

  Future<void> _reloadFromStore() async {
    final List<HibikiClientUrl> urls = await _repo.getHibikiClientUrls();
    final String? token = await _repo.getHibikiClientToken();
    if (!mounted) return;
    setState(() {
      _urls = urls;
      if (!_tokenFocus.hasFocus) {
        _tokenController.text = token ?? '';
      }
    });
  }
```

确认 `unawaited` 可用（`import 'dart:async';`）；文件已用到 `StreamSubscription`，通常已 import；若无则补。

把 token 输入框（1601-1605 行）接上焦点节点：

```dart
          HibikiTextField(
            controller: _tokenController,
            focusNode: _tokenFocus,
            labelText: t.sync_server_token,
            onChanged: (_) => _saveToken(),
          ),
```

- [ ] **Step 3: analyze 验证编译**

Run: `flutter analyze lib/src/sync/sync_settings_schema.dart`
Expected: No issues（无未定义符号 / 未用 import）。

- [ ] **Step 4: 提交**

```bash
git add lib/src/sync/sync_settings_schema.dart
git commit -m "fix(sync): client config reloads on shared revision (no stale URL/token)"
```

---

## Task 4: 客户端点击设备 → /api/pair 拉取并填入 token

**Files:**
- Modify: `lib/src/sync/sync_settings_schema.dart`

- [ ] **Step 1: 确认 import**

文件顶部需要 `dart:convert`（jsonDecode）与 `package:http/http.dart`。检查并按需补：

```dart
import 'dart:convert';
import 'package:http/http.dart' as http;
```

（`package:http` 已是项目依赖，见 `hibiki_remote_lookup_client.dart`。）

- [ ] **Step 2: 重写 `_connectToDevice`**

把 `_LanDiscoveryWidget` 的 `_connectToDevice`（1940-1950 行）整体替换为：

```dart
  Future<void> _connectToDevice(HibikiDevice device) async {
    final state = _syncSettings(widget.settingsContext);
    state.backendType = SyncBackendType.hibikiServer;
    final repo = SyncRepository(widget.settingsContext.appModel.database);
    await repo.setBackendType(SyncBackendType.hibikiServer);
    // Always record the address (deduped) so the user keeps the URL even if
    // pairing is not open yet and they fall back to pasting the token.
    await repo.addHibikiClientUrl(device.webDavUrl);

    String message;
    try {
      final http.Response resp = await http
          .post(Uri.parse('${device.webDavUrl}/api/pair'))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final dynamic body = jsonDecode(resp.body);
        final String? token =
            body is Map<String, dynamic> ? body['token'] as String? : null;
        if (token != null && token.isNotEmpty) {
          await repo.setHibikiClientToken(token);
          message = t.sync_pair_success;
        } else {
          message = t.sync_pair_failed;
        }
      } else if (resp.statusCode == 403) {
        message = t.sync_pair_window_closed;
      } else {
        message = t.sync_pair_failed;
      }
    } catch (e, stack) {
      // Pairing probe failed (window closed/no server/timeout). Keep the URL;
      // record why instead of swallowing.
      ErrorLogService.instance.log('LanDiscovery.pair:${device.webDavUrl}', e, stack);
      message = t.sync_pair_failed;
    }

    // Single source of truth bumped → client-config widget reloads URL + token.
    state.reloadClientConfig();
    widget.settingsContext.refresh();
    if (mounted) _showSnackBar(context, '${device.name}: $message');
  }
```

- [ ] **Step 3: analyze 验证**

Run: `flutter analyze lib/src/sync/sync_settings_schema.dart`
Expected: No issues。

- [ ] **Step 4: 跑相关已有测试，确认无回归**

Run: `flutter test --no-pub test/sync/ test/settings/settings_renderer_test.dart`
Expected: PASS（LAN discovery 单测、设置渲染测试不受影响）。

- [ ] **Step 5: 提交**

```bash
git add lib/src/sync/sync_settings_schema.dart
git commit -m "feat(sync): tap LAN device pairs via /api/pair and auto-fills token"
```

---

## Task 5: 服务端设置页「开启配对」按钮

**Files:**
- Modify: `lib/src/sync/sync_settings_schema.dart`

- [ ] **Step 1: 给 `_ServerModeWidgetState` 加配对窗口倒计时状态**

在 `_ServerModeWidgetState`（1636 行）字段区（`bool _loaded = false;` 之后）加：

```dart
  Timer? _pairCountdownTimer;
  int _pairSecondsLeft = 0;
```

确认 `import 'dart:async';` 已存在（`Timer`、`StreamSubscription` 用到）。

`dispose()`（1652-1658 行）里，`_portController.dispose();` 之前加：

```dart
    _pairCountdownTimer?.cancel();
```

- [ ] **Step 2: 加开窗 + 倒计时方法**

在 `_regenerateToken()`（1779-1788 行）之后加：

```dart
  /// Open a 60s pairing window on the running server and tick a countdown so
  /// the user sees how long peers may pair. No-op when the server isn't up.
  void _openPairing() {
    final HibikiSyncServer? server = _server;
    if (server == null || !server.isRunning) return;
    const int windowSeconds = 60;
    server.openPairing(window: const Duration(seconds: windowSeconds));
    _pairCountdownTimer?.cancel();
    setState(() => _pairSecondsLeft = windowSeconds);
    _pairCountdownTimer =
        Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _pairSecondsLeft -= 1;
        if (_pairSecondsLeft <= 0) timer.cancel();
      });
    });
  }
```

- [ ] **Step 3: 在服务器运行区加按钮**

`build`（1790 行）中，token 复制/重置那一行 `Row`（1844-1864 行，两个 `TextButton.icon` 所在的 Row）之后、`],`（1865 行结束 `if (running)` 块）之前，加配对按钮：

```dart
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _pairSecondsLeft > 0 ? null : _openPairing,
                    icon: const Icon(Icons.wifi_tethering, size: 18),
                    label: Text(_pairSecondsLeft > 0
                        ? t.sync_pair_window_open(n: _pairSecondsLeft)
                        : t.sync_pair_open_button),
                  ),
                ),
```

注意：`t.sync_pair_window_open(n: _pairSecondsLeft)` 的参数名 `n` 必须与 i18n 文案里的 `${n}` 一致（Task 2）。若 slang 生成的参数类型为 `String`，改成 `n: '$_pairSecondsLeft'`；以 `strings.g.dart` 实际生成签名为准。

- [ ] **Step 4: analyze 验证**

Run: `flutter analyze lib/src/sync/sync_settings_schema.dart`
Expected: No issues（确认 `t.sync_pair_window_open` 参数签名匹配）。

- [ ] **Step 5: 提交**

```bash
git add lib/src/sync/sync_settings_schema.dart
git commit -m "feat(sync): add 'Allow pairing' button with countdown on server settings"
```

---

## Task 6: 全量验证 + 设备复测

**Files:** 无（验证）

- [ ] **Step 1: 格式化 + 静态分析全仓**

```bash
dart format .
flutter analyze
```
Expected: 无新增告警/错误。

- [ ] **Step 2: 跑同步与设置相关测试**

Run: `flutter test --no-pub test/sync/ test/settings/ test/i18n/`
Expected: 全 PASS（含 Task 1 新测试、i18n 完整性测试）。

- [ ] **Step 3: 设备复测原始失败路径（项目规则强制：sync/UI 改动需真机/模拟器验证）**

按 `docs/agent/integration-testing.md` 用模拟器或用户指定设备，两台 Hibiki 实例：
1. 设备 A：设置 → 同步方式选 Hibiki P2P → 开启「同步服务器」→ 点「开启配对」（看到 60 秒倒计时）。
2. 设备 B：同页面 LAN 设备列表点设备 A → 期望：snackbar 显示「配对成功，已自动填入 token」，且**客户端 URL 列表立刻出现该 URL、token 输入框立刻填入**（验证 stale-state 已修复）。
3. 设备 B 点「测试连接」→ 期望成功（✓）。
4. 反例：设备 A 不开配对窗口时，设备 B 点设备 → snackbar「请先在对方设备上开启配对」，URL 仍被记录，token 不变。
5. 截图留证（`docs/REGRESSION_BUGS.md` / `.codex-test/`，按规则不入库）。

- [ ] **Step 4: 收尾提交（若设备验证中有微调）**

```bash
git status --short
# 仅 stage 本轮相关文件，禁止 git add -A
git diff --cached --check
```

---

## Self-Review 核对

- **Spec 覆盖**：问题1（点击无反馈）→ Task 3（共享修订号重载）+ Task 4（reloadClientConfig 调用）；问题2（token 自动填）→ Task 1（服务端接口）+ Task 4（客户端拉取）+ Task 5（服务端开窗按钮）+ Task 2（文案）。全覆盖。
- **类型一致性**：`openPairing({Duration window})` / `isPairingOpen` / `_handlePair(String method)`（Task 1）在 Task 5 以 `server.openPairing(window: ...)`、`server.isRunning` 调用，一致。`reloadClientConfig()` / `clientConfigRevision`（Task 3）在 Task 4 调用，一致。`_tokenFocus`（Task 3）在 token 框接入，一致。
- **无占位符**：所有步骤含完整代码与命令。
- **i18n 纪律**：只经 i18n_sync + slang，未手改生成文件。
- **根因修复**：stale-state 用「单一真相源 + 观察者」从数据结构层消除，而非 hack key/延迟/重建；token 拉取走显式配对窗口，符合服务端既有可信-LAN 威胁模型，未引入吞异常或特例分支。
