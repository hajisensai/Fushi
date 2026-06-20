import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-607 P0-3/③：诊断区「崩溃转储」项必须 Windows-only 门控。
///
/// native minidump 只在 Windows runner 经 SetUnhandledExceptionFilter 写出，移动端
/// 无此机制（仿 wgc_capture_log 的 isWindows 门控）。该诊断项暴露 crashdumps 列表 +
/// 打开文件夹 + 分享 .dmp；这些能力在非 Windows 平台没有意义，必须隐藏。
void main() {
  late String schema;

  setUp(() {
    schema =
        File('lib/src/settings/settings_schema_system.dart').readAsStringSync();
  });

  test('诊断区有崩溃转储项且 Windows-only 可见', () {
    final int idx = schema.indexOf("id: 'diagnostics.crash_dumps'");
    expect(idx, isNonNegative, reason: '诊断区必须有崩溃转储项');
    // 该项 200 字符窗口内必须有 Platform.isWindows 门控。
    final String item = schema.substring(idx, idx + 300);
    expect(
      item.contains('visible: (_) => Platform.isWindows'),
      isTrue,
      reason: '崩溃转储项必须 Windows-only（native dump 仅 Windows runner 写）',
    );
    expect(item.contains('CrashDumpPage'), isTrue,
        reason: '崩溃转储项导航到 CrashDumpPage');
  });

  test('CrashDumpPage 列表/打开文件夹/分享均经 Windows 门控的 locator', () {
    final String page =
        File('lib/src/pages/implementations/crash_dump_page.dart')
            .readAsStringSync();
    // 列表：经 listCurrentPlatformDumps（内部 Platform.isWindows 门控，非 Windows 空）。
    expect(
        page.contains('CrashDumpLocator.listCurrentPlatformDumps()'), isTrue);
    // 打开文件夹：Process.run explorer（净新增能力）。
    expect(page.contains("Process.run('explorer'"), isTrue,
        reason: '打开文件夹用 explorer');
    // 分享：Share.shareXFiles 分享 .dmp（净新增使用点）。
    expect(page.contains('Share.shareXFiles'), isTrue);
    // 打开文件夹的目录解析也走 Windows 门控的 resolveDumpDirectory。
    expect(
      page.contains('isWindows: Platform.isWindows'),
      isTrue,
      reason: '打开文件夹的目录解析必须经 Platform.isWindows 门控',
    );
  });

  test('CrashDumpPage 常驻 .dmp 隐私提示文案', () {
    final String page =
        File('lib/src/pages/implementations/crash_dump_page.dart')
            .readAsStringSync();
    expect(
      page.contains('t.crash_dump_privacy_notice'),
      isTrue,
      reason: '必须显示 .dmp 含进程内存快照的隐私提示',
    );
  });

  test('locator 把 crashdumps 目录门控在 Windows', () {
    final String locator =
        File('lib/src/utils/misc/crash_dump_locator.dart').readAsStringSync();
    // resolveDumpDirectory 非 Windows 返回 null（整项隐藏的根因门控）。
    final int idx = locator.indexOf('static Directory? resolveDumpDirectory(');
    expect(idx, isNonNegative);
    final String body = locator.substring(idx, idx + 300);
    expect(body.contains('if (!isWindows) return null;'), isTrue,
        reason: '非 Windows 必须返回 null，使诊断项与列表整体不可用');
  });
}
