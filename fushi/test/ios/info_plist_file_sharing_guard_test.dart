import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/storage/app_paths.dart';

/// 复习自动备份放在 documents 根下（与 Anki / AnkiMobile 一样用户看得到、换设备能带走）。
/// iOS 上要让「文件」App 看得到 app 的 Documents，Info.plist 必须同时开
/// `UIFileSharingEnabled` 与 `LSSupportsOpeningDocumentsInPlace`；少一个「我的 iPhone」里就没有 Fushi。
///
/// 开共享的前提是 Documents 里没有数据库 / 凭据：数据库与偏好在 support 根（Library），
/// 这里一并钉住「数据库目录 = support 根」，有人把它挪进 documents 根就红。
void main() {
  // Tests run with CWD = `fushi/`.
  final String plist = File('ios/Runner/Info.plist').readAsStringSync();

  bool keyIsTrue(String key) =>
      RegExp('<key>$key</key>\\s*<true\\s*/>').hasMatch(plist);

  test('Info.plist 开了「文件」App 共享（两个键都要）', () {
    expect(keyIsTrue('UIFileSharingEnabled'), isTrue);
    expect(keyIsTrue('LSSupportsOpeningDocumentsInPlace'), isTrue);
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
