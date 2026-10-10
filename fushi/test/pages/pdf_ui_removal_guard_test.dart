import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('PDF-only leaderboard and settings components are removed', () {
    const List<String> removed = <String>[
      'lib/src/leaderboard/leaderboard_features.dart',
      'lib/src/leaderboard/leaderboard_reference_works.dart',
      'lib/src/leaderboard/leaderboard_reference_works_data.dart',
      'lib/src/leaderboard/leaderboard_watermelon_layout.dart',
      'lib/src/pages/implementations/leaderboard/leaderboard_watermelon_page.dart',
      'lib/src/pages/implementations/leaderboard/leaderboard_chars_summary.dart',
      'lib/src/pages/implementations/leaderboard/leaderboard_sync_panel.dart',
      'tool/leaderboard/fetch_jiten_reference_works.dart',
    ];
    for (final String path in removed) {
      expect(File(path).existsSync(), isFalse, reason: path);
    }
    final String resetDialog = File(
      'lib/src/pages/implementations/stat_day_reset_hour_dialog.dart',
    ).readAsStringSync();
    expect(resetDialog, contains('class StatDayResetHourDialog'));
    expect(resetDialog, isNot(contains('class StatSettingsDialog')));
    final Map<String, String> restored = <String, String>{
      'updates_center_page.dart': 't.updates_filter_all',
      'statistics_center_page.dart': 't.stat_center_day_reset_action',
    };
    for (final MapEntry<String, String> entry in restored.entries) {
      final String source = File(
        'lib/src/pages/implementations/${entry.key}',
      ).readAsStringSync();
      expect(source, contains(entry.value), reason: entry.key);
    }
  });
}
