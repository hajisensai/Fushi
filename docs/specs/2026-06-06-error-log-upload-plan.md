# 报错日志上传到服务器 — 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在日志页加「上传到服务器」按钮，把日志+元信息经 EdgeOne 反代发到自建 Linux 上的 Go 源站，开发者用带密码的只读网页查看。

**Architecture:** App（Flutter）POST JSON 到 EO 域名 → EO 反代/限流/注入密钥头回源 → Go 单文件服务把日志当哑文件落盘 + 提供 Basic Auth 只读查看页。源站对日志内容只存取、绝不执行/解释。

**Tech Stack:** Dart/Flutter（`http` + `package_info_plus`，端点走 `--dart-define`）；Go 标准库（`net/http` + `crypto/subtle` + `crypto/rand` + `html/template`）；systemd；EdgeOne 控制台配置。

**对 spec 的实现改良（已告知用户）：** App 端配置不用 gitignored 文件，改用 `--dart-define` 编译期注入（`String.fromEnvironment`）——配置文件可入库、空值时按钮隐藏、fresh clone 可编译，消除「缺文件编译失败」特例。其余完全按 spec `docs/specs/2026-06-06-error-log-upload-design.md`。

**安全硬约束（贯穿全程，代码审查逐条卡）：** 见 spec §5。源站不执行输入 / 防存储型 XSS（text/plain + 转义 + nosniff + CSP）/ 防路径穿越（服务端生成文件名 + id 白名单）/ Basic Auth 常数时间比较 + 仅 HTTPS / 防绕过 EO（校验 `X-EO-Secret`）/ 限流限大小 + 滚动删旧 / 只读无 CSRF / systemd 最小权限。

---

## 文件结构

**App 端（`hibiki/`）：**
- Create `lib/src/utils/misc/log_upload_config.dart` — 端点/token 常量（`String.fromEnvironment`）+ 纯函数门控 `isLogUploadConfigured`。
- Create `lib/src/utils/misc/log_uploader.dart` — 上传核心 `performLogUpload`（可测）+ UI 包装 `uploadLogToServer`（弹 SnackBar）。
- Modify `lib/src/pages/implementations/error_log_page.dart` — 加上传按钮。
- Modify `lib/src/pages/implementations/debug_log_page.dart` — 加上传按钮。
- Modify `lib/i18n/*.i18n.json` + `lib/i18n/strings.g.dart` — 经 `i18n_sync.dart` + `slang` 增 key。
- Test `test/utils/log_upload_config_test.dart`、`test/utils/log_uploader_test.dart`。

**Go 源站（仓库新目录 `server/log-collector/`）：**
- Create `go.mod`、`main.go`、`main_test.go`、`systemd/hibiki-logs.service`、`README.md`。

---

## Task 1: App 端配置常量 + 可测门控

**Files:**
- Create: `hibiki/lib/src/utils/misc/log_upload_config.dart`
- Test: `hibiki/test/utils/log_upload_config_test.dart`

- [ ] **Step 1: 写失败测试**

`hibiki/test/utils/log_upload_config_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/log_upload_config.dart';

void main() {
  group('isLogUploadConfigured', () {
    test('空端点 → 未配置', () {
      expect(isLogUploadConfigured(''), isFalse);
      expect(isLogUploadConfigured('   '), isFalse);
    });
    test('非 http 端点 → 未配置（防误填）', () {
      expect(isLogUploadConfigured('logs.example.com'), isFalse);
    });
    test('https 端点 → 已配置', () {
      expect(isLogUploadConfigured('https://logs.example.com/api/logs'), isTrue);
    });
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd hibiki && flutter test test/utils/log_upload_config_test.dart`
Expected: FAIL —「Target of URI doesn't exist: log_upload_config.dart」/ `isLogUploadConfigured` 未定义。

- [ ] **Step 3: 写最小实现**

`hibiki/lib/src/utils/misc/log_upload_config.dart`:
```dart
/// 日志上传端点配置。真实值在构建时通过 --dart-define 注入，不入库：
///   flutter build apk \
///     --dart-define=HIBIKI_LOG_ENDPOINT=https://logs.example.com/api/logs \
///     --dart-define=HIBIKI_LOG_TOKEN=<上传token>
/// 未注入时两常量为空串 → 上传按钮自动隐藏，fresh clone 即可编译。
const String kLogUploadEndpoint =
    String.fromEnvironment('HIBIKI_LOG_ENDPOINT');
const String kLogUploadToken =
    String.fromEnvironment('HIBIKI_LOG_TOKEN');

/// 上传单条日志的请求体字节硬上限（与源站/EO 各自上限呼应）。
const int kMaxLogUploadBytes = 512 * 1024;

/// 端点是否已配置成可上传的 https 地址（纯函数，便于测试门控）。
bool isLogUploadConfigured(String endpoint) {
  final String e = endpoint.trim();
  return e.startsWith('https://') || e.startsWith('http://');
}

/// 当前构建是否展示「上传」按钮。
bool get showUploadLogAction => isLogUploadConfigured(kLogUploadEndpoint);
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd hibiki && flutter test test/utils/log_upload_config_test.dart`
Expected: PASS（3 个）。

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/utils/misc/log_upload_config.dart hibiki/test/utils/log_upload_config_test.dart
git commit -m "feat(log): upload endpoint config via dart-define + testable gate"
```

---

## Task 2: App 端上传核心 performLogUpload（MockClient 可测）

**Files:**
- Create: `hibiki/lib/src/utils/misc/log_uploader.dart`
- Test: `hibiki/test/utils/log_uploader_test.dart`

- [ ] **Step 1: 写失败测试**

`hibiki/test/utils/log_uploader_test.dart`:
```dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hibiki/src/utils/misc/log_uploader.dart';

void main() {
  const String endpoint = 'https://logs.example.com/api/logs';
  const String token = 'test-token';

  Future<LogUploadOutcome> run(
    MockClient client, {
    String log = 'hello log',
  }) {
    return performLogUpload(
      log: log,
      kind: 'error',
      endpoint: endpoint,
      token: token,
      appVersion: '1.0.0+1',
      platform: 'android',
      device: 'Pixel 7 / Android 14',
      tsIso: '2026-06-06T12:34:56Z',
      client: client,
    );
  }

  test('200 → success 带 id，请求体含元信息 + 正确头', () async {
    late http.Request seen;
    final MockClient client = MockClient((http.Request req) async {
      seen = req;
      return http.Response('{"id":"20260606-123456-android-ab12cd"}', 200);
    });

    final LogUploadOutcome out = await run(client);

    expect(out.kind, LogUploadStatus.success);
    expect(out.id, '20260606-123456-android-ab12cd');
    expect(seen.method, 'POST');
    expect(seen.headers['x-upload-token'], token);
    expect(seen.headers['content-type'], contains('application/json'));
    final Map<String, dynamic> body =
        jsonDecode(seen.body) as Map<String, dynamic>;
    expect(body['kind'], 'error');
    expect(body['app_version'], '1.0.0+1');
    expect(body['platform'], 'android');
    expect(body['device'], 'Pixel 7 / Android 14');
    expect(body['ts'], '2026-06-06T12:34:56Z');
    expect(body['log'], 'hello log');
  });

  test('超大日志被截断到上限内并标记', () async {
    late http.Request seen;
    final MockClient client = MockClient((http.Request req) async {
      seen = req;
      return http.Response('{"id":"x"}', 200);
    });
    // 1MB 远超 512KB 上限
    final String big = 'A' * (1024 * 1024);

    final LogUploadOutcome out = await run(client, log: big);

    expect(out.kind, LogUploadStatus.success);
    final Map<String, dynamic> body =
        jsonDecode(seen.body) as Map<String, dynamic>;
    final String sentLog = body['log'] as String;
    expect(utf8.encode(sentLog).length, lessThanOrEqualTo(512 * 1024));
    expect(sentLog, contains('[truncated]'));
  });

  test('401 → unauthorized', () async {
    final MockClient client =
        MockClient((http.Request req) async => http.Response('no', 401));
    expect((await run(client)).kind, LogUploadStatus.unauthorized);
  });

  test('413 → tooLarge', () async {
    final MockClient client =
        MockClient((http.Request req) async => http.Response('too big', 413));
    expect((await run(client)).kind, LogUploadStatus.tooLarge);
  });

  test('网络异常 → networkError', () async {
    final MockClient client =
        MockClient((http.Request req) async => throw Exception('boom'));
    expect((await run(client)).kind, LogUploadStatus.networkError);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd hibiki && flutter test test/utils/log_uploader_test.dart`
Expected: FAIL — `log_uploader.dart`/`performLogUpload`/`LogUploadOutcome` 未定义。

- [ ] **Step 3: 写最小实现**

`hibiki/lib/src/utils/misc/log_uploader.dart`:
```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/utils/misc/log_upload_config.dart';

/// 上传结果状态。
enum LogUploadStatus {
  success,
  unauthorized,
  tooLarge,
  rateLimited,
  serverError,
  networkError,
}

/// 上传结果（成功时带服务端返回 id）。
class LogUploadOutcome {
  const LogUploadOutcome(this.kind, {this.id});
  final LogUploadStatus kind;
  final String? id;
}

/// 把日志正文截断到 [kMaxLogUploadBytes] 字节内（保留尾部最近内容），
/// 截断时在头部插入标记。返回 UTF-8 字节数 <= 上限的字符串。
String _capLogBytes(String log) {
  final List<int> bytes = utf8.encode(log);
  if (bytes.length <= kMaxLogUploadBytes) return log;
  const String marker = '[truncated] 日志过大，仅上传最近部分\n';
  final int budget = kMaxLogUploadBytes - utf8.encode(marker).length;
  // 从尾部取 budget 字节，避免切坏多字节字符：用 allowMalformed 解码后再修边界。
  final List<int> tail = bytes.sublist(bytes.length - budget);
  final String tailStr = utf8.decode(tail, allowMalformed: true);
  return marker + tailStr;
}

/// 执行一次日志上传（纯逻辑，便于用 MockClient 测试）。
/// 不弹 UI；调用方据返回的 [LogUploadOutcome] 决定提示。
Future<LogUploadOutcome> performLogUpload({
  required String log,
  required String kind,
  required String endpoint,
  required String token,
  required String appVersion,
  required String platform,
  required String device,
  required String tsIso,
  http.Client? client,
}) async {
  final http.Client c = client ?? http.Client();
  try {
    final String body = jsonEncode(<String, dynamic>{
      'kind': kind,
      'app_version': appVersion,
      'platform': platform,
      'device': device,
      'ts': tsIso,
      'log': _capLogBytes(log),
    });
    final http.Response resp = await c.post(
      Uri.parse(endpoint),
      headers: <String, String>{
        'Content-Type': 'application/json; charset=utf-8',
        'X-Upload-Token': token,
      },
      body: body,
    );
    switch (resp.statusCode) {
      case 200:
        String? id;
        try {
          final Object? decoded = jsonDecode(resp.body);
          if (decoded is Map && decoded['id'] is String) {
            id = decoded['id'] as String;
          }
        } catch (_) {}
        return LogUploadOutcome(LogUploadStatus.success, id: id);
      case 401:
      case 403:
        return const LogUploadOutcome(LogUploadStatus.unauthorized);
      case 413:
        return const LogUploadOutcome(LogUploadStatus.tooLarge);
      case 429:
        return const LogUploadOutcome(LogUploadStatus.rateLimited);
      default:
        return const LogUploadOutcome(LogUploadStatus.serverError);
    }
  } catch (_) {
    return const LogUploadOutcome(LogUploadStatus.networkError);
  } finally {
    if (client == null) c.close();
  }
}

/// 收集设备/版本元信息（平台 + OS 版本字符串，无需额外插件）。
Future<({String appVersion, String platform, String device})>
    _collectMeta() async {
  String appVersion = 'unknown';
  try {
    final PackageInfo info = await PackageInfo.fromPlatform();
    appVersion = '${info.version}+${info.buildNumber}';
  } catch (_) {}
  return (
    appVersion: appVersion,
    platform: Platform.operatingSystem,
    device: Platform.operatingSystemVersion,
  );
}

/// UI 入口：收集元信息 → 上传 → 按结果弹 SnackBar。
Future<void> uploadLogToServer({
  required BuildContext context,
  required String log,
  required String kind,
}) async {
  void notify(String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  notify(t.log_upload_in_progress);
  final meta = await _collectMeta();
  final LogUploadOutcome out = await performLogUpload(
    log: log,
    kind: kind,
    endpoint: kLogUploadEndpoint,
    token: kLogUploadToken,
    appVersion: meta.appVersion,
    platform: meta.platform,
    device: meta.device,
    tsIso: DateTime.now().toUtc().toIso8601String(),
  );

  switch (out.kind) {
    case LogUploadStatus.success:
      notify(out.id == null
          ? t.log_upload_success
          : '${t.log_upload_success} (${out.id})');
    case LogUploadStatus.tooLarge:
      notify(t.log_upload_too_large);
    default:
      notify(t.log_upload_failed);
  }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd hibiki && flutter test test/utils/log_uploader_test.dart`
Expected: PASS（5 个）。i18n key 此刻还没加，但测试只调 `performLogUpload`，不触发 `t.*`，故能过。

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/utils/misc/log_uploader.dart hibiki/test/utils/log_uploader_test.dart
git commit -m "feat(log): performLogUpload core with size cap + outcome mapping"
```

---

## Task 3: i18n key（17 语言）

**Files:**
- Modify: `hibiki/lib/i18n/*.i18n.json`（经脚本）
- Modify: `hibiki/lib/i18n/strings.g.dart`（经 slang 生成）

- [ ] **Step 1: 用脚本增 key（禁手改逐文件）**

Run（在 `hibiki/` 下，逐条）:
```bash
dart tool/i18n_sync.dart --add log_upload_action "Upload to server" "上传到服务器"
dart tool/i18n_sync.dart --add log_upload_in_progress "Uploading log…" "正在上传日志…"
dart tool/i18n_sync.dart --add log_upload_success "Log uploaded" "日志已上传"
dart tool/i18n_sync.dart --add log_upload_failed "Upload failed" "上传失败"
dart tool/i18n_sync.dart --add log_upload_too_large "Log too large to upload" "日志过大，无法上传"
```

- [ ] **Step 2: 重新生成 + 格式化**

Run:
```bash
cd hibiki && dart run slang && dart format lib/i18n/strings.g.dart
```
Expected: `strings.g.dart` 现含 `log_upload_action` 等 getter，无缺 key 报错。

- [ ] **Step 3: 校验 i18n 完整性**

Run: `cd hibiki && flutter test test/i18n/`
Expected: PASS（17 语言 key 齐）。

- [ ] **Step 4: 提交**

```bash
git add hibiki/lib/i18n
git commit -m "i18n: add log upload action/status keys (17 locales)"
```

---

## Task 4: 接入两个日志页的工具栏

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/error_log_page.dart`
- Modify: `hibiki/lib/src/pages/implementations/debug_log_page.dart`
- Test: `hibiki/test/pages/log_upload_button_test.dart`

- [ ] **Step 1: 写 widget 失败测试（门控 + 不崩）**

`hibiki/test/pages/log_upload_button_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/log_upload_config.dart';

void main() {
  // 纯门控守卫：未注入 dart-define 时构建不展示上传按钮，
  // 保证 fresh clone / 默认构建零行为变化、不暴露端点。
  test('默认构建（无 dart-define）→ 上传按钮隐藏', () {
    expect(showUploadLogAction, isFalse);
    expect(isLogUploadConfigured(kLogUploadEndpoint), isFalse);
  });
}
```

- [ ] **Step 2: 跑测试确认通过（守卫先立）**

Run: `cd hibiki && flutter test test/pages/log_upload_button_test.dart`
Expected: PASS（默认无 dart-define，端点空 → 隐藏）。这是防回归守卫：若日后误把端点写死进源码，此测试转红。

- [ ] **Step 3: 在 error_log_page.dart 加上传按钮**

`error_log_page.dart`：在 import 区已有 `log_exporter.dart`，新增：
```dart
import 'package:hibiki/src/utils/misc/log_uploader.dart';
```
在 `actions` 列表里，`share_outlined` 按钮之后、`if (showSaveLogAction)` 之前插入：
```dart
        if (showUploadLogAction)
          HibikiIconButton(
            icon: Icons.cloud_upload_outlined,
            tooltip: t.log_upload_action,
            onTap: () => uploadLogToServer(
              context: context,
              log: log,
              kind: 'error',
            ),
          ),
```

- [ ] **Step 4: 在 debug_log_page.dart 加上传按钮**

`debug_log_page.dart`：import 区新增：
```dart
import 'package:hibiki/src/utils/misc/log_uploader.dart';
```
在 `actions` 列表里，`share_outlined` 按钮之后、`if (showSaveLogAction)` 之前插入（注意用 `_log` 字段）：
```dart
        if (showUploadLogAction)
          HibikiIconButton(
            icon: Icons.cloud_upload_outlined,
            tooltip: t.log_upload_action,
            onTap: () => uploadLogToServer(
              context: context,
              log: _log,
              kind: 'debug',
            ),
          ),
```

- [ ] **Step 5: 分析 + 测试 + 格式化**

Run:
```bash
cd hibiki && flutter analyze lib/src/pages/implementations/error_log_page.dart lib/src/pages/implementations/debug_log_page.dart lib/src/utils/misc/log_uploader.dart
dart format lib/src/utils/misc/log_uploader.dart lib/src/utils/misc/log_upload_config.dart lib/src/pages/implementations/error_log_page.dart lib/src/pages/implementations/debug_log_page.dart
flutter test test/pages/log_upload_button_test.dart test/utils/log_uploader_test.dart test/utils/log_upload_config_test.dart
```
Expected: analyze 0 issue；测试全 PASS。

- [ ] **Step 6: 提交**

```bash
git add hibiki/lib/src/pages/implementations/error_log_page.dart hibiki/lib/src/pages/implementations/debug_log_page.dart hibiki/test/pages/log_upload_button_test.dart
git commit -m "feat(log): wire upload button into error/debug log pages"
```

---

## Task 5: Go 源站 — 上传接收端（TDD）

**Files:**
- Create: `server/log-collector/go.mod`
- Create: `server/log-collector/main.go`
- Create: `server/log-collector/main_test.go`

- [ ] **Step 1: 建 go module**

`server/log-collector/go.mod`:
```
module hibiki-log-collector

go 1.21
```

- [ ] **Step 2: 写失败测试（上传路径全约束）**

`server/log-collector/main_test.go`:
```go
package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"regexp"
	"strings"
	"testing"
)

func testConfig(t *testing.T) Config {
	t.Helper()
	return Config{
		UploadToken:  "good-token",
		BasicUser:    "admin",
		BasicPass:    "secret-pass",
		EOSecret:     "eo-shared",
		DataDir:      t.TempDir(),
		MaxBodyBytes: 1024,
		Retain:       100,
	}
}

func uploadReq(token, eo, body string) *http.Request {
	r := httptest.NewRequest(http.MethodPost, "/api/logs", strings.NewReader(body))
	r.Header.Set("Content-Type", "application/json")
	if token != "" {
		r.Header.Set("X-Upload-Token", token)
	}
	if eo != "" {
		r.Header.Set("X-EO-Secret", eo)
	}
	return r
}

func TestUploadHappyPath(t *testing.T) {
	cfg := testConfig(t)
	h := newServer(cfg)
	body := `{"kind":"error","app_version":"1.0+1","platform":"android","device":"Pixel","ts":"2026-06-06T00:00:00Z","log":"hello"}`
	w := httptest.NewRecorder()
	h.ServeHTTP(w, uploadReq("good-token", "eo-shared", body))

	if w.Code != http.StatusOK {
		t.Fatalf("want 200, got %d (%s)", w.Code, w.Body.String())
	}
	var resp struct{ ID string }
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("bad json: %v", err)
	}
	if !regexp.MustCompile(`^\d{8}-\d{6}-[a-z]+-[a-z0-9]{6}\.txt$`).MatchString(resp.ID) {
		t.Fatalf("id not whitelisted shape: %q", resp.ID)
	}
	if _, err := os.Stat(cfg.DataDir + "/" + resp.ID); err != nil {
		t.Fatalf("file not written: %v", err)
	}
}

func TestUploadWrongToken(t *testing.T) {
	h := newServer(testConfig(t))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, uploadReq("bad", "eo-shared", `{"log":"x"}`))
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("want 401, got %d", w.Code)
	}
}

func TestUploadMissingEOSecret(t *testing.T) {
	h := newServer(testConfig(t))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, uploadReq("good-token", "", `{"log":"x"}`))
	if w.Code != http.StatusForbidden {
		t.Fatalf("want 403 (bare-origin bypass blocked), got %d", w.Code)
	}
}

func TestUploadTooLarge(t *testing.T) {
	h := newServer(testConfig(t)) // MaxBodyBytes=1024
	big := `{"log":"` + strings.Repeat("A", 4096) + `"}`
	w := httptest.NewRecorder()
	h.ServeHTTP(w, uploadReq("good-token", "eo-shared", big))
	if w.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("want 413, got %d", w.Code)
	}
}

func TestUploadMaliciousPlatformStaysInDataDir(t *testing.T) {
	cfg := testConfig(t)
	h := newServer(cfg)
	body := `{"kind":"error","platform":"../../etc","device":"x","log":"y"}`
	w := httptest.NewRecorder()
	h.ServeHTTP(w, uploadReq("good-token", "eo-shared", body))
	if w.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", w.Code)
	}
	// 数据目录里只有刚写的 1 个文件，且没逃逸到上级
	entries, _ := os.ReadDir(cfg.DataDir)
	if len(entries) != 1 {
		t.Fatalf("expected 1 file in data dir, got %d", len(entries))
	}
	if strings.Contains(entries[0].Name(), "/") || strings.Contains(entries[0].Name(), "..") {
		t.Fatalf("filename not sanitized: %q", entries[0].Name())
	}
}
```

- [ ] **Step 3: 跑测试确认失败**

Run: `cd server/log-collector && go test ./...`
Expected: FAIL — `newServer`/`Config` 未定义（编译失败）。

- [ ] **Step 4: 写实现（上传部分；查看部分 Task 6 补）**

`server/log-collector/main.go`:
```go
package main

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// Config 全部从环境变量注入，绝不写进源码/仓库。
type Config struct {
	UploadToken  string
	BasicUser    string
	BasicPass    string
	EOSecret     string
	DataDir      string
	MaxBodyBytes int64
	Retain       int
	ListenAddr   string
}

type uploadPayload struct {
	Kind       string `json:"kind"`
	AppVersion string `json:"app_version"`
	Platform   string `json:"platform"`
	Device     string `json:"device"`
	Ts         string `json:"ts"`
	Log        string `json:"log"`
}

var idPattern = regexp.MustCompile(`^\d{8}-\d{6}-[a-z]+-[a-z0-9]{6}\.txt$`)
var platSanitize = regexp.MustCompile(`[^a-z]`)

const randAlphabet = "abcdefghijklmnopqrstuvwxyz0123456789"

func ctEqual(a, b string) bool {
	return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}

func randCode(n int) string {
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		// crypto/rand 失败极罕见；用时间兜底，仍非攻击者可控
		for i := range buf {
			buf[i] = byte(time.Now().UnixNano() >> (i * 8))
		}
	}
	out := make([]byte, n)
	for i, b := range buf {
		out[i] = randAlphabet[int(b)%len(randAlphabet)]
	}
	return string(out)
}

func sanitizePlatform(p string) string {
	p = strings.ToLower(p)
	p = platSanitize.ReplaceAllString(p, "")
	if p == "" {
		return "unknown"
	}
	if len(p) > 16 {
		p = p[:16]
	}
	return p
}

// securityHeaders 给所有响应钉上防御头。
func securityHeaders(w http.ResponseWriter) {
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("X-Frame-Options", "DENY")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
}

func (c Config) handleUpload(w http.ResponseWriter, r *http.Request) {
	securityHeaders(w)
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	// 防绕过 EO：必须带 EO 回源注入的密钥头。
	if !ctEqual(r.Header.Get("X-EO-Secret"), c.EOSecret) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	// 弱上传凭据（App 内置）。
	if !ctEqual(r.Header.Get("X-Upload-Token"), c.UploadToken) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	// 限大小：超限读取直接 413。
	r.Body = http.MaxBytesReader(w, r.Body, c.MaxBodyBytes)
	var p uploadPayload
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
		if strings.Contains(err.Error(), "http: request body too large") {
			http.Error(w, "too large", http.StatusRequestEntityTooLarge)
			return
		}
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}

	// 文件名完全由服务端生成，绝不用客户端字段拼路径。
	name := time.Now().UTC().Format("20060102-150405") + "-" +
		sanitizePlatform(p.Platform) + "-" + randCode(6) + ".txt"

	// 元信息作为文件头部写入正文（去除换行注入）。
	header := strings.NewReplacer("\n", " ", "\r", " ")
	content := "# kind: " + header.Replace(p.Kind) + "\n" +
		"# app_version: " + header.Replace(p.AppVersion) + "\n" +
		"# platform: " + header.Replace(p.Platform) + "\n" +
		"# device: " + header.Replace(p.Device) + "\n" +
		"# ts: " + header.Replace(p.Ts) + "\n\n" + p.Log

	if err := os.MkdirAll(c.DataDir, 0o750); err != nil {
		http.Error(w, "server error", http.StatusInternalServerError)
		return
	}
	if err := os.WriteFile(filepath.Join(c.DataDir, name), []byte(content), 0o640); err != nil {
		http.Error(w, "server error", http.StatusInternalServerError)
		return
	}
	c.rotate()

	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(map[string]string{"id": name})
}

// rotate 保留最近 Retain 个文件，删最旧的，防塞盘。
func (c Config) rotate() {
	if c.Retain <= 0 {
		return
	}
	entries, err := os.ReadDir(c.DataDir)
	if err != nil {
		return
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if !e.IsDir() && idPattern.MatchString(e.Name()) {
			names = append(names, e.Name())
		}
	}
	if len(names) <= c.Retain {
		return
	}
	sort.Strings(names) // 文件名前缀是时间戳 → 字典序即时间序
	for _, old := range names[:len(names)-c.Retain] {
		_ = os.Remove(filepath.Join(c.DataDir, old))
	}
}

// newServer 装配路由（查看路由在 Task 6 补）。
func newServer(c Config) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/logs", c.handleUpload)
	return mux
}

func main() {
	cfg := Config{
		UploadToken:  os.Getenv("UPLOAD_TOKEN"),
		BasicUser:    os.Getenv("BASIC_USER"),
		BasicPass:    os.Getenv("BASIC_PASS"),
		EOSecret:     os.Getenv("EO_SECRET"),
		DataDir:      envOr("DATA_DIR", "/var/lib/hibiki-logs/data"),
		MaxBodyBytes: envInt64("MAX_BODY_BYTES", 1<<20),
		Retain:       int(envInt64("RETAIN", 2000)),
		ListenAddr:   envOr("LISTEN_ADDR", "127.0.0.1:8787"),
	}
	srv := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           newServer(cfg),
		ReadHeaderTimeout: 10 * time.Second,
	}
	if err := srv.ListenAndServe(); err != nil {
		os.Exit(1)
	}
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func envInt64(k string, def int64) int64 {
	v := os.Getenv(k)
	if v == "" {
		return def
	}
	var n int64
	for _, ch := range v {
		if ch < '0' || ch > '9' {
			return def
		}
		n = n*10 + int64(ch-'0')
	}
	return n
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `cd server/log-collector && go test ./...`
Expected: PASS（5 个上传相关测试）。

- [ ] **Step 6: 提交**

```bash
git add server/log-collector/go.mod server/log-collector/main.go server/log-collector/main_test.go
git commit -m "feat(server): log upload receiver — server-named files, EO-secret gate, size cap, rotation"
```

---

## Task 6: Go 源站 — Basic Auth 只读查看页（TDD）

**Files:**
- Modify: `server/log-collector/main.go`（加 `/` 与 `/log/` 路由）
- Modify: `server/log-collector/main_test.go`（加查看 + 安全测试）

- [ ] **Step 1: 写失败测试（鉴权 / 穿越 / XSS）**

在 `main_test.go` 追加：
```go
func basicAuthReq(method, target, user, pass string) *http.Request {
	r := httptest.NewRequest(method, target, nil)
	if user != "" || pass != "" {
		r.SetBasicAuth(user, pass)
	}
	return r
}

func seedOneLog(t *testing.T, cfg Config, h http.Handler, log string) string {
	t.Helper()
	body, _ := json.Marshal(uploadPayload{Kind: "error", Platform: "android", Log: log})
	w := httptest.NewRecorder()
	h.ServeHTTP(w, uploadReq("good-token", "eo-shared", string(body)))
	if w.Code != http.StatusOK {
		t.Fatalf("seed upload failed: %d", w.Code)
	}
	var resp struct{ ID string }
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	return resp.ID
}

func TestViewerRequiresBasicAuth(t *testing.T) {
	h := newServer(testConfig(t))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, basicAuthReq(http.MethodGet, "/", "", ""))
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("want 401 without auth, got %d", w.Code)
	}
}

func TestViewerWrongPassword(t *testing.T) {
	h := newServer(testConfig(t))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, basicAuthReq(http.MethodGet, "/", "admin", "nope"))
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("want 401, got %d", w.Code)
	}
}

func TestViewerListsLogs(t *testing.T) {
	cfg := testConfig(t)
	h := newServer(cfg)
	id := seedOneLog(t, cfg, h, "hello")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, basicAuthReq(http.MethodGet, "/", "admin", "secret-pass"))
	if w.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", w.Code)
	}
	if !strings.Contains(w.Body.String(), id) {
		t.Fatalf("listing missing id %q", id)
	}
}

func TestViewLogServedAsPlainText_XSSInert(t *testing.T) {
	cfg := testConfig(t)
	h := newServer(cfg)
	id := seedOneLog(t, cfg, h, "<script>alert(1)</script>")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, basicAuthReq(http.MethodGet, "/log/"+id, "admin", "secret-pass"))
	if w.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", w.Code)
	}
	ct := w.Header().Get("Content-Type")
	if !strings.HasPrefix(ct, "text/plain") {
		t.Fatalf("log must be text/plain (inert), got %q", ct)
	}
	if w.Header().Get("X-Content-Type-Options") != "nosniff" {
		t.Fatalf("missing nosniff")
	}
	// 原文按字节返回（text/plain 下浏览器不执行），断言确实是 text/plain 而非 html
	if strings.Contains(ct, "html") {
		t.Fatalf("must not be html")
	}
}

func TestViewLogRejectsPathTraversal(t *testing.T) {
	h := newServer(testConfig(t))
	for _, bad := range []string{
		"/log/..%2f..%2fetc%2fpasswd",
		"/log/evil.txt",
		"/log/20260606-000000-android-ab12cd.txt.bak",
	} {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, basicAuthReq(http.MethodGet, bad, "admin", "secret-pass"))
		if w.Code == http.StatusOK {
			t.Fatalf("traversal/unknown id served: %s", bad)
		}
	}
}

func TestValidateLogIDUnit(t *testing.T) {
	if validLogID("../../etc/passwd") {
		t.Fatal("must reject traversal")
	}
	if validLogID("evil.txt") {
		t.Fatal("must reject non-pattern")
	}
	if !validLogID("20260606-123456-android-ab12cd.txt") {
		t.Fatal("must accept valid id")
	}
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd server/log-collector && go test ./...`
Expected: FAIL — `validLogID` 未定义 + 查看路由缺失（401/404 期望不满足）。

- [ ] **Step 3: 实现查看路由**

在 `main.go` 的 import 增加 `"html/template"`。新增：
```go
func validLogID(id string) bool {
	return idPattern.MatchString(id)
}

func (c Config) checkBasicAuth(w http.ResponseWriter, r *http.Request) bool {
	user, pass, ok := r.BasicAuth()
	if ok && ctEqual(user, c.BasicUser) && ctEqual(pass, c.BasicPass) {
		return true
	}
	w.Header().Set("WWW-Authenticate", `Basic realm="hibiki-logs", charset="UTF-8"`)
	http.Error(w, "unauthorized", http.StatusUnauthorized)
	return false
}

var listTmpl = template.Must(template.New("list").Parse(`<!doctype html>
<html><head><meta charset="utf-8"><title>hibiki logs</title></head>
<body><h1>hibiki logs ({{len .}})</h1><ul>
{{range .}}<li><a href="/log/{{.}}">{{.}}</a></li>{{end}}
</ul></body></html>`))

func (c Config) handleList(w http.ResponseWriter, r *http.Request) {
	securityHeaders(w)
	if !c.checkBasicAuth(w, r) {
		return
	}
	entries, _ := os.ReadDir(c.DataDir)
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if !e.IsDir() && validLogID(e.Name()) {
			names = append(names, e.Name())
		}
	}
	sort.Sort(sort.Reverse(sort.StringSlice(names))) // 最新在前
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	// html/template 自动转义 names，杜绝列表页 XSS。
	_ = listTmpl.Execute(w, names)
}

func (c Config) handleViewLog(w http.ResponseWriter, r *http.Request) {
	securityHeaders(w)
	if !c.checkBasicAuth(w, r) {
		return
	}
	id := strings.TrimPrefix(r.URL.Path, "/log/")
	if !validLogID(id) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	data, err := os.ReadFile(filepath.Join(c.DataDir, id))
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	// 日志正文一律 text/plain 原样吐 → 浏览器当纯文本，脚本不执行。
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = w.Write(data)
}
```
把 `newServer` 改成：
```go
func newServer(c Config) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/logs", c.handleUpload)
	mux.HandleFunc("/log/", c.handleViewLog)
	mux.HandleFunc("/", c.handleList)
	return mux
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd server/log-collector && go test ./...`
Expected: PASS（上传 + 查看 + 安全全绿）。

- [ ] **Step 5: go vet + 提交**

```bash
cd server/log-collector && go vet ./...
git add server/log-collector/main.go server/log-collector/main_test.go
git commit -m "feat(server): basic-auth read-only viewer — text/plain logs, id whitelist, escaped listing"
```

---

## Task 7: systemd 单元 + 部署/EO 配置文档

**Files:**
- Create: `server/log-collector/systemd/hibiki-logs.service`
- Create: `server/log-collector/README.md`

- [ ] **Step 1: 写 systemd 单元（最小权限加固）**

`server/log-collector/systemd/hibiki-logs.service`:
```ini
[Unit]
Description=Hibiki log collector
After=network.target

[Service]
Type=simple
User=hibiki-logs
Group=hibiki-logs
# 真实密钥放 /etc/hibiki-logs.env（chmod 600，不入库）
EnvironmentFile=/etc/hibiki-logs.env
ExecStart=/usr/local/bin/hibiki-log-collector
Restart=on-failure
RestartSec=2

# 最小权限加固：只能写数据目录，碰不到系统其它地方
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=/var/lib/hibiki-logs
RestrictAddressFamilies=AF_INET AF_INET6
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 2: 写 README（部署 + EO 配置 + 安全说明）**

`server/log-collector/README.md`：包含
1. 构建：`go build -o hibiki-log-collector .`（单文件，零依赖）。
2. 部署：建用户 `hibiki-logs`、建 `/var/lib/hibiki-logs/data`、放二进制到 `/usr/local/bin/`、写 `/etc/hibiki-logs.env`（`UPLOAD_TOKEN`/`BASIC_USER`/`BASIC_PASS`/`EO_SECRET`/`DATA_DIR`/`MAX_BODY_BYTES`/`RETAIN`/`LISTEN_ADDR=127.0.0.1:8787`，chmod 600）、`systemctl enable --now hibiki-logs`。
3. **EdgeOne 控制台**：
   - 加速域名 → 源站设为你服务器（建议源站只监听内网/本机，前置 nginx/caddy 终结到 127.0.0.1:8787，或用 EO 私有连接）。
   - 回源配置：注入自定义头 `X-EO-Secret: <与 env 同值>`（源站靠它拒裸连）。
   - 针对 `POST /api/logs` 配速率限制规则 + 请求体大小上限。
   - `GET /`、`/log/*` 设不缓存（含鉴权内容）。
   - 强制 HTTPS。
4. App 构建注入：`flutter build apk --dart-define=HIBIKI_LOG_ENDPOINT=https://<EO域名>/api/logs --dart-define=HIBIKI_LOG_TOKEN=<UPLOAD_TOKEN>`。
5. 安全说明：App 内 token 只能写日志（可被逆向，已限权）；查看密码只在服务端；日志只读、text/plain。

- [ ] **Step 3: 校验 + 提交**

Run: `git diff --cached --check`
```bash
git add server/log-collector/systemd/hibiki-logs.service server/log-collector/README.md
git commit -m "docs(server): systemd hardened unit + deploy/EdgeOne config guide"
```

---

## Task 8: 全量验证 + 代码审查

- [ ] **Step 1: App 全量验证**

Run（`hibiki/` 下，用项目 Flutter 3.44.0 工具链）:
```bash
dart format .
flutter analyze
flutter test
```
Expected: format 无改动残留、analyze 0 issue、test 全绿（含新增 + i18n）。

- [ ] **Step 2: Go 全量验证**

Run:
```bash
cd server/log-collector && go vet ./... && go test ./... && go build -o /tmp/hibiki-log-collector .
```
Expected: vet 干净、test 全绿、单文件二进制构建成功。

- [ ] **Step 3: 代码审查（opus）**

调用 `superpowers:requesting-code-review`，spawn code-reviewer agent（**必须 `model: "opus"`**），逐条核对 spec §5 安全硬约束：
- 源站不执行/不解释输入；
- 文件名服务端生成、`GET /log/<id>` 白名单、无路径拼接穿越；
- 日志 text/plain + nosniff + CSP、列表页 `html/template` 自动转义；
- Basic Auth 常数时间比较、`X-EO-Secret` 常数时间校验；
- body 上限 413、滚动删旧；
- systemd 最小权限；
- App token 不入库、空端点隐藏按钮、截断逻辑不切坏多字节。
修复审查问题后重跑 Step 1/2，再提交。

- [ ] **Step 4: 设备验证（待用户）**

按 CLAUDE.md：上传链路属「导入/网络」真实路径，声明「修好了」前需真机/模拟器实测一次端到端（配 dart-define 构建 → 点上传 → 服务器落盘 → 网页可见）。本计划交付到代码 + 自动化测试 + 文档，**真机端到端验证留给用户**（需用户提供真实 EO 域名 + 服务器）。

---

## 自查覆盖（spec → task 映射）

- §2 架构三层：App（Task 1/2/4）、EO（Task 7 文档）、Go 源站（Task 5/6）。✅
- §3.1 上传契约（头/JSON/大小）：Task 2 + Task 5。✅
- §3.2 响应码映射：Task 2（401/413/429/5xx）+ Task 5。✅
- §3.3 服务端生成文件名、不拼客户端字段：Task 5（`TestUploadMaliciousPlatformStaysInDataDir`）。✅
- §3.4 查看 `/` + `/log/<id>`：Task 6。✅
- §4.1 App helper + 配置 + UI + i18n：Task 1/2/3/4。✅
- §4.2 Go 标准库单文件 + env 配置 + 滚动清理：Task 5。✅
- §4.3 EO 配置文档：Task 7。✅
- §5 安全 1–9：分散在 Task 5/6/7 实现 + Task 8 审查逐条核。✅
- §6 测试策略：Task 1/2/4（App）+ Task 5/6（Go）。✅
- §7 向后兼容（空端点隐藏、纯新增）：Task 1 + Task 4 守卫。✅
