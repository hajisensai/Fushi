# 日志导出 + 一键发送 GitHub 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给两个日志页（`DebugLogPage` / `ErrorLogPage`）加「桌面端另存为文件」和「一键发送到 GitHub Issue」两个动作。

**Architecture:** 抽一个共享 helper `LogExporter`，把可单测的纯函数（构造 issue URL / body）与有副作用的导出/发送动作分开。两个日志页各加最多两个 `HibikiIconButton`：桌面端显示「另存为」（复用备份功能的 `FilePicker.saveFile` 平台分流），全平台显示「发送 GitHub」（先复制完整日志到剪贴板兜底 URL 超长，再用 `launchUrl` 打开预填好的 `issues/new` 页面）。移动端「导出」缺口已被现有「分享」按钮覆盖，不重复加。

**Tech Stack:** Flutter / Dart 3.12；`url_launcher`、`package_info_plus`、`file_picker`(fork)、`share_plus` 均已是依赖；i18n 用 Slang（必须走 `tool/i18n_sync.dart`，禁止手改 17 个 json）。

---

## 关键事实（实现前必读）

- 仓库常量：app 自身 GitHub 仓库是 `hajisensai/hibiki`（见 `lib/src/utils/misc/update_checker.dart:13`）。
- 平台分流导出范例：`lib/src/sync/sync_settings_schema.dart:745-768`（`getTemporaryDirectory` → 移动 `Share.shareXFiles` / 桌面 `FilePicker.platform.saveFile` + `File.copy`）。
- 两个日志页现状：
  - `lib/src/pages/implementations/debug_log_page.dart`（StatefulWidget，`_log` 字段，已有 刷新/复制/分享/清除 四个按钮，分享 subject = `t.debug_log_share_subject`，文件名 `hibiki_debug_log.txt`）。
  - `lib/src/pages/implementations/error_log_page.dart`（StatelessWidget，`log` 局部变量，已有 复制/分享/清除 三个按钮，分享 subject = `t.error_log_share_subject`，文件名 `hibiki_error_log.txt`）。
- 日志取值：`DebugLogService.instance.getFullLog()` / `ErrorLogService.instance.getFullLog()`（无需 init 也返回空提示文案）。
- 版本/平台元信息：helper 内用 `PackageInfo.fromPlatform()` 取 `version`，`Platform.operatingSystem` / `Platform.operatingSystemVersion` 取系统。
- 桌面端判定：`Platform.isWindows || Platform.isMacOS || Platform.isLinux`。
- `launchUrl` 用法范例：`settings_schema.dart:1189`（`await launchUrl(Uri.parse(...))`）。
- 计划文档放 `docs/specs/`（`docs/superpowers` 被 gitignore）。

---

## 文件结构

| 文件 | 责任 | 操作 |
|---|---|---|
| `hibiki/lib/src/utils/misc/log_exporter.dart` | 纯函数（`buildGitHubIssueUri` / `buildIssueBody`）+ 副作用动作（`saveLogToFile` / `sendLogToGitHub`） | 新建 |
| `hibiki/test/utils/log_exporter_test.dart` | 纯函数单测（URL 结构、编码、body 含元信息） | 新建 |
| `hibiki/lib/src/pages/implementations/debug_log_page.dart` | 加桌面「另存为」+ 全平台「发送 GitHub」按钮 | 改 |
| `hibiki/lib/src/pages/implementations/error_log_page.dart` | 同上 | 改 |
| `hibiki/test/pages/log_pages_actions_test.dart` | widget 测试：桌面端两按钮在、移动端只发送按钮在 | 新建 |
| `hibiki/lib/i18n/*.i18n.json`（经 `tool/i18n_sync.dart`） | 6 个新 key | 改 |
| `hibiki/lib/utils.dart`（barrel） | 导出 `log_exporter.dart`（若 pages 经 barrel 引用） | 视情况改 |

新增 i18n key（`en` / `zh`）：

| key | en | zh |
|---|---|---|
| `log_export_file` | `Export to file` | `导出到文件` |
| `log_export_saved` | `Log saved` | `日志已保存` |
| `log_export_failed` | `Export failed` | `导出失败` |
| `log_send_github` | `Send to GitHub` | `发送到 GitHub` |
| `log_send_clipboard_hint` | `Log copied to clipboard — paste it into the issue` | `日志已复制到剪贴板，请粘贴到打开的页面` |
| `log_issue_body_placeholder` | `Paste the log here (already copied to clipboard).` | `请在此粘贴日志（已复制到剪贴板）。` |

issue 标题复用现有 `t.debug_log_share_subject` / `t.error_log_share_subject`，文件名复用现有 `hibiki_debug_log.txt` / `hibiki_error_log.txt`，不新增。

---

## Task 1: i18n key 落地

**Files:**
- Modify: `hibiki/lib/i18n/*.i18n.json`（17 个，禁止手改，走脚本）
- Modify: `hibiki/lib/i18n/strings.g.dart`（生成，禁止手改）

- [ ] **Step 1: 用脚本逐个加 key**

在 `hibiki/` 下运行（每条一次）：

```bash
dart run tool/i18n_sync.dart --add log_export_file "Export to file" "导出到文件"
dart run tool/i18n_sync.dart --add log_export_saved "Log saved" "日志已保存"
dart run tool/i18n_sync.dart --add log_export_failed "Export failed" "导出失败"
dart run tool/i18n_sync.dart --add log_send_github "Send to GitHub" "发送到 GitHub"
dart run tool/i18n_sync.dart --add log_send_clipboard_hint "Log copied to clipboard — paste it into the issue" "日志已复制到剪贴板，请粘贴到打开的页面"
dart run tool/i18n_sync.dart --add log_issue_body_placeholder "Paste the log here (already copied to clipboard)." "请在此粘贴日志（已复制到剪贴板）。"
```

- [ ] **Step 2: 重新生成并格式化**

```bash
dart run slang
dart format lib/i18n/strings.g.dart
```

Expected: 无报错；`strings.g.dart` 出现 `String get logExportFile` 等 6 个 getter。

- [ ] **Step 3: 验证 key 完整**

Run: `dart run tool/i18n_sync.dart --dry-run`
Expected: 报告无缺失 key（17 文件齐全）。

- [ ] **Step 4: Commit**

```bash
git add lib/i18n/strings.i18n.json lib/i18n/strings_*.i18n.json lib/i18n/strings.g.dart
git commit -m "i18n(log): add export/send-github keys"
```

---

## Task 2: LogExporter 纯函数（TDD）

**Files:**
- Create: `hibiki/lib/src/utils/misc/log_exporter.dart`
- Test: `hibiki/test/utils/log_exporter_test.dart`

- [ ] **Step 1: 写失败测试**

`hibiki/test/utils/log_exporter_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/log_exporter.dart';

void main() {
  group('buildGitHubIssueUri', () {
    test('points to issues/new on the given repo with encoded params', () {
      final Uri uri = buildGitHubIssueUri(
        repo: 'hajisensai/hibiki',
        title: '[Debug log] v1.2.3',
        body: 'line one\nline two & more',
      );
      expect(uri.scheme, 'https');
      expect(uri.host, 'github.com');
      expect(uri.path, '/hajisensai/hibiki/issues/new');
      // Uri 自动百分号编码，解码后应原样还原。
      expect(uri.queryParameters['title'], '[Debug log] v1.2.3');
      expect(uri.queryParameters['body'], 'line one\nline two & more');
    });
  });

  group('buildIssueBody', () {
    test('includes version, platform, os version and the placeholder', () {
      final String body = buildIssueBody(
        version: '1.2.3',
        platform: 'windows',
        osVersion: '10.0.26200',
        placeholder: 'PASTE HERE',
      );
      expect(body, contains('1.2.3'));
      expect(body, contains('windows'));
      expect(body, contains('10.0.26200'));
      expect(body, contains('PASTE HERE'));
    });
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/utils/log_exporter_test.dart --no-pub`
Expected: FAIL（`log_exporter.dart` 不存在 / 函数未定义）。

- [ ] **Step 3: 写最小实现（纯函数部分）**

`hibiki/lib/src/utils/misc/log_exporter.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:hibiki/i18n/strings.g.dart';

/// app 自身仓库，GitHub Issue 提交目标。与 update_checker 里的常量一致。
const String kHibikiGitHubRepo = 'hajisensai/hibiki';

/// 构造 GitHub 新建 issue 的预填 URL。title/body 自动百分号编码。
Uri buildGitHubIssueUri({
  required String repo,
  required String title,
  required String body,
}) {
  return Uri.https('github.com', '/$repo/issues/new', <String, String>{
    'title': title,
    'body': body,
  });
}

/// 构造 issue 正文：元信息 + 提示占位（完整日志走剪贴板）。
String buildIssueBody({
  required String version,
  required String platform,
  required String osVersion,
  required String placeholder,
}) {
  final StringBuffer buf = StringBuffer()
    ..writeln('| field | value |')
    ..writeln('| --- | --- |')
    ..writeln('| app version | $version |')
    ..writeln('| platform | $platform |')
    ..writeln('| os version | $osVersion |')
    ..writeln()
    ..writeln('---')
    ..writeln()
    ..writeln(placeholder);
  return buf.toString();
}

bool get _isDesktop =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/utils/log_exporter_test.dart --no-pub`
Expected: PASS（2 测试绿）。

- [ ] **Step 5: Commit**

```bash
git add lib/src/utils/misc/log_exporter.dart test/utils/log_exporter_test.dart
git commit -m "feat(log): add LogExporter pure helpers for issue url/body"
```

---

## Task 3: LogExporter 副作用动作（导出文件 / 发送 GitHub）

**Files:**
- Modify: `hibiki/lib/src/utils/misc/log_exporter.dart`

- [ ] **Step 1: 追加导出与发送函数**

在 `log_exporter.dart` 末尾追加（紧接 `_isDesktop`）：

```dart
/// 是否在工具栏给当前平台展示「另存为」按钮（桌面专属；移动端已有分享）。
bool get showSaveLogAction => _isDesktop;

/// 把日志写文件：桌面 FilePicker 另存为；移动端回退系统分享。
/// 复用 sync_settings_schema 的平台分流模式。
Future<void> saveLogToFile({
  required BuildContext context,
  required String log,
  required String fileName,
  required String subject,
}) async {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  try {
    final Directory tmpDir = await getTemporaryDirectory();
    final String tmpPath = '${tmpDir.path}/$fileName';
    final File tmp = File(tmpPath);
    await tmp.writeAsString(log);

    if (_isDesktop) {
      final String? savePath = await FilePicker.platform.saveFile(
        dialogTitle: t.log_export_file,
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: <String>['txt'],
      );
      if (savePath != null) {
        await tmp.copy(savePath);
        messenger.showSnackBar(SnackBar(content: Text(t.log_export_saved)));
      }
      await tmp.delete();
    } else {
      await Share.shareXFiles(
        <XFile>[XFile(tmpPath, mimeType: 'text/plain')],
        subject: subject,
      );
    }
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(t.log_export_failed)));
  }
}

/// 一键发送日志到 GitHub：先复制完整日志到剪贴板（兜底 URL 超长），
/// 再打开预填 title/body 的新建 issue 页面。
Future<void> sendLogToGitHub({
  required BuildContext context,
  required String log,
  required String title,
}) async {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  await Clipboard.setData(ClipboardData(text: log));

  final PackageInfo info = await PackageInfo.fromPlatform();
  final String body = buildIssueBody(
    version: info.version,
    platform: Platform.operatingSystem,
    osVersion: Platform.operatingSystemVersion,
    placeholder: t.log_issue_body_placeholder,
  );
  final Uri uri = buildGitHubIssueUri(
    repo: kHibikiGitHubRepo,
    title: title,
    body: body,
  );

  messenger.showSnackBar(SnackBar(content: Text(t.log_send_clipboard_hint)));
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}
```

- [ ] **Step 2: 静态分析**

Run: `flutter analyze lib/src/utils/misc/log_exporter.dart`
Expected: No issues found.

- [ ] **Step 3: 跑既有纯函数测试确保未回归**

Run: `flutter test test/utils/log_exporter_test.dart --no-pub`
Expected: PASS。

- [ ] **Step 4: Commit**

```bash
git add lib/src/utils/misc/log_exporter.dart
git commit -m "feat(log): add saveLogToFile + sendLogToGitHub actions"
```

---

## Task 4: DebugLogPage 接线

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/debug_log_page.dart`

- [ ] **Step 1: 加导入**

在文件顶部 import 区追加：

```dart
import 'package:hibiki/src/utils/misc/log_exporter.dart';
```

- [ ] **Step 2: 在 actions 列表里、`share` 按钮之后插入两个按钮**

在 `Icons.share_outlined` 那个 `HibikiIconButton` 之后、`Icons.delete_outline` 之前插入：

```dart
        if (showSaveLogAction)
          HibikiIconButton(
            icon: Icons.save_alt_outlined,
            tooltip: t.log_export_file,
            onTap: () => saveLogToFile(
              context: context,
              log: _log,
              fileName: 'hibiki_debug_log.txt',
              subject: t.debug_log_share_subject,
            ),
          ),
        HibikiIconButton(
          icon: Icons.send_outlined,
          tooltip: t.log_send_github,
          onTap: () => sendLogToGitHub(
            context: context,
            log: _log,
            title: t.debug_log_share_subject,
          ),
        ),
```

- [ ] **Step 3: 静态分析**

Run: `flutter analyze lib/src/pages/implementations/debug_log_page.dart`
Expected: No issues found.

- [ ] **Step 4: Commit**

```bash
git add lib/src/pages/implementations/debug_log_page.dart
git commit -m "feat(log): wire export/send-github into DebugLogPage"
```

---

## Task 5: ErrorLogPage 接线

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/error_log_page.dart`

- [ ] **Step 1: 加导入**

```dart
import 'package:hibiki/src/utils/misc/log_exporter.dart';
```

- [ ] **Step 2: 在 `share` 按钮之后、`delete` 之前插入**

注意本页日志变量名是 `log`（局部变量），subject 是 `t.error_log_share_subject`，文件名 `hibiki_error_log.txt`：

```dart
        if (showSaveLogAction)
          HibikiIconButton(
            icon: Icons.save_alt_outlined,
            tooltip: t.log_export_file,
            onTap: () => saveLogToFile(
              context: context,
              log: log,
              fileName: 'hibiki_error_log.txt',
              subject: t.error_log_share_subject,
            ),
          ),
        HibikiIconButton(
          icon: Icons.send_outlined,
          tooltip: t.log_send_github,
          onTap: () => sendLogToGitHub(
            context: context,
            log: log,
            title: t.error_log_share_subject,
          ),
        ),
```

- [ ] **Step 3: 静态分析**

Run: `flutter analyze lib/src/pages/implementations/error_log_page.dart`
Expected: No issues found.

- [ ] **Step 4: Commit**

```bash
git add lib/src/pages/implementations/error_log_page.dart
git commit -m "feat(log): wire export/send-github into ErrorLogPage"
```

---

## Task 6: 页面 widget 测试（按钮可见性守卫）

**Files:**
- Test: `hibiki/test/pages/log_pages_actions_test.dart`

> 目标：守住「全平台都有发送按钮」「桌面才有另存为按钮」这两条不变式。平台用 `debugDefaultTargetPlatformOverride` 不可控原生 `Platform.is*`（`showSaveLogAction` 读的是 `dart:io` 的 host 平台），因此 widget 测试只能断言**当前 host（CI/本机）下**的真实结果，再用源码守卫覆盖另一侧。

- [ ] **Step 1: 写测试 —— 发送按钮恒在 + 纯函数不变式**

`hibiki/test/pages/log_pages_actions_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/debug_log_page.dart';
import 'package:hibiki/src/pages/implementations/error_log_page.dart';
import 'package:hibiki/src/utils/misc/log_exporter.dart';

Widget _wrap(Widget child) {
  return TranslationProvider(
    child: MaterialApp(home: child),
  );
}

void main() {
  testWidgets('DebugLogPage always shows the send-to-github action',
      (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(const DebugLogPage()));
    await tester.pumpAndSettle();
    expect(find.byTooltip(t.log_send_github), findsOneWidget);
    // 另存为按钮跟随 host 平台：与 showSaveLogAction 一致。
    expect(
      find.byTooltip(t.log_export_file),
      showSaveLogAction ? findsOneWidget : findsNothing,
    );
  });

  testWidgets('ErrorLogPage always shows the send-to-github action',
      (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(const ErrorLogPage()));
    await tester.pumpAndSettle();
    expect(find.byTooltip(t.log_send_github), findsOneWidget);
    expect(
      find.byTooltip(t.log_export_file),
      showSaveLogAction ? findsOneWidget : findsNothing,
    );
  });
}
```

- [ ] **Step 2: 跑测试**

Run: `flutter test test/pages/log_pages_actions_test.dart --no-pub`
Expected: PASS（host 是桌面则两按钮都在，移动 CI 则只发送按钮）。

> 若 `TranslationProvider` 需要先 `LocaleSettings` 初始化才能渲染，按 `test/pages/` 现有页面测试的 setup（参考 `book_css_editor_page_test.dart`）补上；不要改 `t` 的全局用法。

- [ ] **Step 3: Commit**

```bash
git add test/pages/log_pages_actions_test.dart
git commit -m "test(log): guard send/export action visibility on log pages"
```

---

## Task 7: 全量验证

- [ ] **Step 1: 格式化**

Run（在 `hibiki/`）: `dart format .`

- [ ] **Step 2: 静态分析**

Run: `flutter analyze`
Expected: No issues found.

- [ ] **Step 3: 全量测试**

Run: `flutter test`
Expected: 全绿（新增 4 测试 + 既有全部）。

- [ ] **Step 4: 代码审查**

按项目工作流调 `superpowers:requesting-code-review` 启动 code-reviewer subagent，**显式 `model: "opus"`**。审查重点：
- issue URL 在超大日志下不会因 URL 超长崩（剪贴板兜底是否真先于 launchUrl 执行）。
- `saveLogToFile` 临时文件清理（`tmp.delete()`）在桌面取消保存时也会执行。
- 移动端是否真未新增冗余按钮（`showSaveLogAction` 门控）。
- `launchUrl` 失败（无浏览器）是否需要提示——当前静默，确认可接受。

- [ ] **Step 5: 真机/桌面复测（声明修好前必做）**

按 `docs/agent/integration-testing.md`：Windows 桌面验「另存为」弹出真实保存对话框且文件内容正确；任一平台验「发送 GitHub」打开浏览器到 `hajisensai/hibiki/issues/new` 且剪贴板含完整日志。留证据。

---

## Self-Review 结论

- **Spec 覆盖**：导出（Task 3 `saveLogToFile` + Task 4/5 接线，桌面另存为；移动端复用现有分享）✅；发送 GitHub（Task 2/3 + 接线）✅。
- **Placeholder**：无 TBD/TODO；每个代码步骤含完整代码。
- **类型一致**：`buildGitHubIssueUri` / `buildIssueBody` / `saveLogToFile` / `sendLogToGitHub` / `showSaveLogAction` 在 Task 2/3 定义，Task 4/5/6 引用名一致。
- **i18n 纪律**：新 key 全走 `i18n_sync.dart`，不手改 json/生成文件（Task 1）。
- **向后兼容**：不动现有 刷新/复制/分享/清除 按钮；新按钮纯追加。
