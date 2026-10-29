import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 音乐插件凭据保险库（`<support>/music_plugins/.credentials/`）在非 Windows 平台上数据密钥与
/// 密文同目录：Android 自动备份 / 设备迁移若带上它，就等于把插件登录态一起上云。两份备份规则
/// 必须同步排除它，且排除的路径必须跟着 AppModel 里插件根目录的名字走。
void main() {
  String read(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');

  test('插件根目录仍是 <数据库目录>/music_plugins', () {
    expect(
      read('lib/src/models/app_model.dart'),
      contains(
        "rootDir: Directory(path.join(databaseDirectory.path, 'music_plugins')),",
      ),
    );
  });

  test('Android 两份备份规则都排除凭据保险库', () {
    const String rule =
        '<exclude domain="file" path="music_plugins/.credentials/" />';
    final String legacy = read('android/app/src/main/res/xml/backup_rules.xml');
    expect(legacy, contains(rule));
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
    expect(cloud, contains(rule));
    expect(transfer, contains(rule));
  });
}
