import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 音乐插件凭据（`<support>/music_plugins/.credentials/` 的密文，与 flutter_secure_storage 里的
/// 数据密钥）不随 Android 自动备份 / 设备迁移走：两份备份规则必须同步排除它们，且排除的路径
/// 必须跟着 AppModel 里插件根目录的名字走。
void main() {
  String read(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');

  test('插件根目录仍是 <数据库目录>/music_plugins', () {
    expect(
      read('lib/src/models/app_model.dart'),
      contains("path.join(databaseDirectory.path, 'music_plugins')"),
    );
  });

  test('Android 两份备份规则都排除凭据保险库', () {
    const List<String> rules = <String>[
      '<exclude domain="file" path="music_plugins/.credentials/" />',
      '<exclude domain="sharedpref" path="FlutterSecureStorage.xml" />',
      '<exclude domain="sharedpref" path="FlutterSecureKeyStorage.xml" />',
    ];
    final String legacy = read('android/app/src/main/res/xml/backup_rules.xml');
    final String modern = read(
      'android/app/src/main/res/xml/data_extraction_rules.xml',
    );
    final String cloud = modern.substring(
      modern.indexOf('<cloud-backup>'),
      modern.indexOf('</cloud-backup>'),
    );
    final String transfer = modern.substring(
      modern.indexOf('<device-transfer>'),
      modern.indexOf('</device-transfer>'),
    );
    for (final String rule in rules) {
      expect(legacy, contains(rule));
      expect(cloud, contains(rule));
      expect(transfer, contains(rule));
    }
  });
}
