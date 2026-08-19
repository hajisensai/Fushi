import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 顶层大类顺序守卫：设置 schema 四块分层（外观 → 内容 → 横切工具 →
/// 数据与设备/系统）。
///
/// 这是「用户决策过的位置」（2026-07-26 用户拍板，取代阶段 G 纯任务优先排序）：
/// 外观置顶；内容块内相关项相邻（阅读→听书、视频→下载→游戏）；查词/制卡是跨媒体
/// 横切工具排内容之后；Profile / 同步备份 / 互联 / 系统殿后。锁死顺序让未来漂移
/// 必须是有意为之（改分类顺序时同步改本守卫）。用源码顺序断言
/// （零 harness 依赖：无需构造 SettingsContext + AppModel 即可校验列表次序）。
///
/// 顺序真相源是 `_buildDestinations()`——`buildSettingsSchema()` 自 schema 缓存
/// （见 settings_schema_cache_test.dart）起只是读快照的薄入口，13 个分类调用留在
/// 前者体内。
void main() {
  test('_buildDestinations keeps the four-block top-level destination order',
      () {
    final String src = File('lib/src/settings/settings_schema.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    final int fnStart =
        src.indexOf('List<SettingsDestination> _buildDestinations');
    expect(fnStart, isNonNegative, reason: '_buildDestinations must exist');
    final int fnEnd = src.indexOf('\n}', fnStart);
    expect(fnEnd, greaterThan(fnStart));
    final String body = src.substring(fnStart, fnEnd);

    const List<String> expectedOrder = <String>[
      'buildAppearanceDestination()',
      'buildReadingDestination()',
      'buildMangaDestination()',
      'buildListeningDestination()',
      'buildVideoDestination()',
      'buildDownloadsDestination()',
      'buildGameDestination()',
      'buildLookupDestination()',
      'buildCardCreationDestination()',
      'buildProfilesDestination()',
      'buildSyncBackupDestination()',
      'buildInterconnectDestination()',
      'buildStorageDestination()',
      'buildSystemDestination()',
    ];

    int previous = -1;
    for (final String token in expectedOrder) {
      final int idx = body.indexOf(token);
      expect(idx, isNonNegative, reason: '_buildDestinations must call $token');
      expect(idx, greaterThan(previous),
          reason: '$token 必须排在前一个 destination 之后（顶层大类顺序被锁定）');
      previous = idx;
    }
  });
}
