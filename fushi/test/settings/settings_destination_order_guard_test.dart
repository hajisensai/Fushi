import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 分类声明顺序与分组导航一致；平台隐藏后首个可见项仍是默认选择。
void main() {
  test(
    '_buildDestinations keeps the six-group top-level destination order',
    () {
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

      const List<String> expectedOrder = <String>[
        'buildAppearanceDestination()',
        // 听书 2026-08-24 并入阅读（buildListeningSections），不再是独立分类。
        'buildReadingDestination()',
        'buildMangaDestination()',
        'buildVideoDestination()',
        'buildGameDestination()',
        'buildMediaTrackingDestination()',
        'buildLookupDestination()',
        'buildCardCreationDestination()',
        'buildDownloadsDestination()',
        'buildServicesDestination()',
        'buildProfilesDestination()',
        'buildSyncBackupDestination()',
        'buildInterconnectDestination()',
        'buildStorageDestination()',
        'buildSystemDestination()',
      ];

      int previous = -1;
      for (final String token in expectedOrder) {
        final int idx = body.indexOf(token);
        expect(
          idx,
          isNonNegative,
          reason: '_buildDestinations must call $token',
        );
        expect(
          idx,
          greaterThan(previous),
          reason: '$token 必须排在前一个 destination 之后（顶层大类顺序被锁定）',
        );
        previous = idx;
      }
    },
  );
}
