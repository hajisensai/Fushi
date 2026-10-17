import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/storage/app_paths.dart';

/// iOS 刻意**不开**「文件」App 共享（PR #2298 审查，2026-10-17）。
///
/// iOS 没有「只共享 Documents 的某个子目录」的办法：`UIFileSharingEnabled` /
/// `LSSupportsOpeningDocumentsInPlace` 一开就是整份 Documents——书正文、有声书、视频、词典资源、
/// 卡片来源回写草稿、未脱敏的错误日志全部可见、可被用户删改（删改让库条目指向丢失的文件）。
/// 复习备份的「带走」需求走备份页的「另存为 / 分享」与「从文件恢复」，不靠暴露 Documents。
///
/// 另外钉住「数据库目录 = support 根」：哪怕将来有人重新打开共享，数据库也不能在 Documents 里。
void main() {
  // Tests run with CWD = `fushi/`.
  final String plist = File('ios/Runner/Info.plist').readAsStringSync();

  // 只看真正生效的 <key>，注释里提到键名不算。
  final String plistNoComments = plist.replaceAll(
    RegExp(r'<!--.*?-->', dotAll: true),
    '',
  );
  bool hasKey(String key) => plistNoComments.contains('<key>$key</key>');

  test('Info.plist 不开「文件」App 共享（两个键都不许出现）', () {
    expect(hasKey('UIFileSharingEnabled'), isFalse);
    expect(hasKey('LSSupportsOpeningDocumentsInPlace'), isFalse);
    // 自检：去注释后确实还剩别的键（防止正则吃光整份文件让上面两条恒真）。
    expect(hasKey('ITSAppUsesNonExemptEncryption'), isTrue);
  });

  test('备份页保留「另存为 / 分享」与「从文件恢复」两条带走 / 带回路径', () {
    final String page = File(
      'lib/src/pages/implementations/srs/srs_backups_page.dart',
    ).readAsStringSync();
    expect(page, contains('FushiShare.shareFiles('));
    expect(page, contains('pickSystemFilePath('));
    expect(page, contains("ValueKey<String>('srs_backup_restore_file')"));
  });

  test('复习备份目录在 documents 根下、并随数据根迁移', () {
    expect(AppPaths.fushiOwnedDocumentsEntries, contains('srs_backups'));
    final String paths = File(
      'lib/src/storage/app_paths.dart',
    ).readAsStringSync();
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
