import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:path/path.dart' as p;

/// iOS「文件」App 里的 Fushi 文件夹 = 导入收件箱（拍板台 nLXhu0d7gV，2026-11-16）。
///
/// 历史：PR #2298 审查（2026-10-17）刻意不开文件共享——iOS 没有「只共享 Documents 的某个子目录」
/// 的办法，`UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace` 一开就是整份 Documents，
/// 而当时书正文、有声书、视频、词典资源、未脱敏错误日志全在 Documents 里，用户在「文件」App 里删改
/// 会让库条目指向丢失的文件。
///
/// 现在两个键都开了，前提是**Documents 里不再有任何书库 / 诊断数据**：
///  - iOS 书库根在 `<Library>/Fushi/data`（`AppPaths.iosDocumentsRoot`），存量从 Documents 搬过去；
///  - 错误日志与 MetricKit 诊断在 `<ApplicationSupport>/logs`（Dart 与 Swift 同一目录）；
///  - 数据库在 support 根。
/// 本守卫钉住这些前提：哪一条被改回 Documents，都等于把用户数据重新暴露给「文件」App。
void main() {
  // Tests run with CWD = `fushi/`.
  final String plist = File('ios/Runner/Info.plist').readAsStringSync();

  // 只看真正生效的 <key>，注释里提到键名不算。
  final String plistNoComments = plist.replaceAll(
    RegExp(r'<!--.*?-->', dotAll: true),
    '',
  );
  bool keyIsTrue(String key) =>
      RegExp('<key>$key</key>\\s*<true/>').hasMatch(plistNoComments);

  test('Info.plist 开「文件」App 共享（收件箱可见）', () {
    expect(keyIsTrue('UIFileSharingEnabled'), isTrue);
    expect(keyIsTrue('LSSupportsOpeningDocumentsInPlace'), isTrue);
    // 自检：去注释后确实还剩别的键（防止正则吃光整份文件）。
    expect(
      plistNoComments,
      contains('<key>ITSAppUsesNonExemptEncryption</key>'),
    );
  });

  final String paths = File(
    'lib/src/storage/app_paths.dart',
  ).readAsStringSync();

  String bodyOf(String source, String signature) {
    final int start = source.indexOf(signature);
    expect(start, isNot(-1), reason: '找不到 $signature');
    final int end = source.indexOf('\n  }\n', start);
    return source.substring(start, end);
  }

  test('iOS 默认书库根不在 Documents：走 iosDocumentsRoot（Library 下）', () {
    for (final String sig in <String>[
      'static Future<Directory> _resolveDefaultDocumentsRoot()',
      'static Future<Directory> defaultLocationDocumentsRoot()',
    ]) {
      expect(
        bodyOf(paths, sig),
        contains('if (Platform.isIOS) return iosDocumentsRoot();'),
        reason: '$sig 在 iOS 上必须解析到 Library 下的书库根',
      );
    }
    expect(
      paths,
      contains('iosDocumentsRootUnder(await getLibraryDirectory())'),
    );
    // 派生结果与 Documents 互不包含（同一容器内的兄弟目录）。
    const String container = '/var/mobile/Containers/Data/Application/X';
    final String root = AppPaths.iosDocumentsRootUnder(
      Directory('$container/Library'),
    ).path;
    expect(p.isWithin('$container/Documents', root), isFalse);
    expect(
      p.isWithin('$container/Library/Application Support', root),
      isFalse,
      reason: '书库根不能套在 support 根（数据库根）里',
    );
  });

  test('启动期先把 iOS 存量书库搬出 Documents，再解析根', () {
    final String resolve = bodyOf(paths, 'static Future<AppPaths> resolve()');
    final int vacate = resolve.indexOf(
      'await _ensureIosSharedDocumentsVacated();',
    );
    final int docs = resolve.indexOf('await _resolveDocumentsRoot();');
    expect(vacate, isNot(-1));
    expect(vacate, lessThan(docs));
  });

  test('iOS 诊断目录不在 Documents：与桌面同为 <ApplicationSupport>/logs', () {
    final String diag = bodyOf(
      paths,
      'static Future<Directory> _resolveDiagnosticsDirectory()',
    );
    expect(diag, contains('if (!isDesktopPlatform && !Platform.isIOS) {'));
    expect(diag, contains("p.join(support.path, 'logs')"));
    expect(diag, contains('migrateLegacyMetricKitDirectory('));
  });

  test('Swift MetricKit 落盘与 Dart 诊断目录一致，不写 Documents', () {
    final String swift = File(
      'ios/Runner/AppDelegate.swift',
    ).readAsStringSync();
    final int start = swift.indexOf(
      'func didReceive(_ payloads: [MXDiagnosticPayload])',
    );
    expect(start, isNot(-1));
    final String body = swift.substring(start, start + 900);
    expect(body, contains('.applicationSupportDirectory'));
    expect(body, contains('appendingPathComponent("logs"'));
    expect(body, contains('appendingPathComponent("metrickit"'));
    expect(body, isNot(contains('.documentDirectory')));
    expect(AppPaths.metricKitDirectoryName, 'metrickit');
  });

  test('同步与历史页保留「导出 .fushisrs（另存为 / 分享）」与「导入」两条带走 / 带回路径', () {
    final String page = File(
      'lib/src/pages/implementations/srs/srs_history_page.dart',
    ).readAsStringSync();
    expect(page, contains('FushiShare.shareFiles('));
    expect(page, contains('pickSystemFilePath('));
    expect(page, contains("ValueKey<String>('srs_timeline_export')"));
    expect(page, contains("ValueKey<String>('srs_timeline_import')"));
  });

  test('复习备份目录在 documents 根下、并随数据根迁移', () {
    expect(AppPaths.fushiOwnedDocumentsEntries, contains('srs_backups'));
    expect(paths, contains("documentsSubdirectory('srs_backups')"));
  });

  test('数据库目录是 support 根（不在会被「文件」App 共享的 Documents 里）', () {
    final String app = File('lib/src/models/app_model.dart').readAsStringSync();
    expect(
      RegExp(r'_databaseDirectory\s*=\s*_appPaths\.supportRoot').hasMatch(app),
      isTrue,
    );
  });
}
