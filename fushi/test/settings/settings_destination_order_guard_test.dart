import 'dart:io';

import 'package:test/test.dart';

/// 分类声明顺序与分组导航一致；平台隐藏后首个可见项仍是默认选择。
void main() {
  test('_buildDestinations keeps the grouped top-level destination order', () {
    final String src = File(
      'lib/src/settings/settings_schema.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final int fnStart = src.indexOf(
      'List<SettingsDestination> _buildDestinations',
    );
    expect(fnStart, isNonNegative, reason: '_buildDestinations must exist');
    final int fnEnd = src.indexOf('\n}', fnStart);
    expect(fnEnd, greaterThan(fnStart));
    final String body = src.substring(fnStart, fnEnd);

    // 完整的一级分类顺序：与 settings_navigation_groups 的分组次序一致
    // （通用 → 内容 → 学习 → AI 与模型 → 连接 → 数据 → 系统）。
    // 媒体记录受 kMediaTrackingEnabled 门控，但声明位置同样锁定。
    const List<String> expectedOrder = <String>[
      'buildGeneralDestination()',
      'buildAppearanceDestination()',
      'buildNavigationDestination()',
      'buildFloatingBallDestination()',
      'buildReadingDestination()',
      // 听书是独立分类，紧随阅读。
      'buildListeningDestination()',
      'buildMangaDestination()',
      'buildVideoDestination()',
      'buildMusicDestination()',
      'buildGameDestination()',
      'buildWebBrowserDestination()',
      'buildLookupDestination()',
      'buildCardCreationDestination()',
      // AI 与本机模型紧随制卡：它们服务于查词与制卡。
      'buildAiDestination()',
      'buildModelsDestination()',
      'buildDownloadsDestination()',
      'buildServicesDestination()',
      'buildMediaTrackingDestination()',
      'buildLocalServicesDestination()',
      'buildProfilesDestination()',
      'buildSyncBackupDestination()',
      'buildInterconnectDestination()',
      'buildStorageDestination()',
      'buildWidgetsDestination()',
      'buildSystemDestination()',
    ];

    int previous = -1;
    for (final String token in expectedOrder) {
      final int idx = body.indexOf(token);
      expect(idx, isNonNegative, reason: '_buildDestinations must call $token');
      expect(
        idx,
        greaterThan(previous),
        reason: '$token 必须排在前一个 destination 之后（顶层大类顺序被锁定）',
      );
      previous = idx;
    }
  });
}
