import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 顶层大类顺序守卫：`buildSettingsSchema` 四块分层（外观 → 内容 → 横切工具 →
/// 数据与设备/系统）。
///
/// 这是「用户决策过的位置」（2026-07-26 用户拍板，取代阶段 G 纯任务优先排序）：
/// 外观置顶；内容块内相关项相邻（阅读→听书、视频→下载）；查词/制卡是跨媒体
/// 横切工具排内容之后；Profile / 同步备份 / 互联 / 系统殿后。锁死顺序让未来漂移
/// 必须是有意为之（改 `buildSettingsSchema` 时同步改本守卫）。用源码顺序断言
/// （零 harness 依赖：无需构造 SettingsContext + AppModel 即可校验列表次序）。
void main() {
  test('buildSettingsSchema keeps the four-block top-level destination order',
      () {
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
      'buildListeningDestination()',
      'buildVideoDestination()',
      'buildDownloadsDestination()',
      'buildLookupDestination()',
      'buildCardCreationDestination()',
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
