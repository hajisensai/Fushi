import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 顶层大类顺序守卫：`buildSettingsSchema`「外观」置顶 + 内容类在前、系统类殿后。
///
/// 这是「用户决策过的位置」——外观置顶（2026-07-25 用户拍板，覆盖阶段 G 纯任务
/// 优先排序），其后是最常改的阅读 / 查词 / 制卡 / 视频 / 听书 / 下载，
/// Profile / 同步备份 / 互联 / 系统殿后。锁死顺序让未来漂移必须是有意为之
/// （改 `buildSettingsSchema` 时同步改本守卫）。用源码顺序断言（零 harness 依赖：
/// 无需构造 SettingsContext + AppModel 即可校验 destination 列表次序）。
void main() {
  test(
      'buildSettingsSchema keeps the appearance-first top-level destination '
      'order', () {
    final String src = File('lib/src/settings/settings_schema.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    final int fnStart =
        src.indexOf('List<SettingsDestination> buildSettingsSchema');
    expect(fnStart, isNonNegative, reason: 'buildSettingsSchema must exist');
    final int fnEnd = src.indexOf('\n}', fnStart);
    expect(fnEnd, greaterThan(fnStart));
    final String body = src.substring(fnStart, fnEnd);

    const List<String> expectedOrder = <String>[
      'buildAppearanceDestination()',
      'buildReadingDestination()',
      'buildLookupDestination()',
      'buildCardCreationDestination()',
      'buildVideoDestination()',
      'buildListeningDestination()',
      'buildDownloadsDestination()',
      'buildProfilesDestination()',
      'buildSyncBackupDestination()',
      'buildInterconnectDestination()',
      'buildSystemDestination()',
    ];

    int previous = -1;
    for (final String token in expectedOrder) {
      final int idx = body.indexOf(token);
      expect(idx, isNonNegative,
          reason: 'buildSettingsSchema must call $token');
      expect(idx, greaterThan(previous),
          reason: '$token 必须排在前一个 destination 之后（顶层大类顺序被锁定）');
      previous = idx;
    }
  });
}
