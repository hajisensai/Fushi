import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/storage/storage_usage_service.dart'
    show formatStorageBytes;
import 'package:fushi/src/sync/auto_backup/auto_backup_settings.dart';
import 'package:fushi/src/sync/auto_backup/auto_backup_status.dart';
import 'package:fushi/src/sync/backup_service.dart' show BackupCategory;
import 'package:fushi/src/sync/sync_settings_schema.dart'
    show autoBackupIntervalLabel, autoBackupStatusLine;

/// 设置 › 同步与备份 ›「自动备份」：缺省值（D1 默认开、每日、小集合；D2 复习媒体默认不带）、
/// 偏好往返、状态行文案。
void main() {
  test('空偏好：每日、不指定时间、默认小集合、不带复习媒体、默认目录', () {
    final AutoBackupSettings s = readAutoBackupSettings((String _) => null);
    expect(s.interval, AutoBackupInterval.daily);
    expect(s.enabled, isTrue);
    expect(s.preferredMinuteOfDay, isNull);
    expect(s.categories, <BackupCategory>{
      BackupCategory.settings,
      BackupCategory.profiles,
      BackupCategory.progress,
      BackupCategory.statistics,
      BackupCategory.music,
      BackupCategory.srs,
      BackupCategory.fonts,
    });
    expect(s.includeSrsMedia, isFalse);
    expect(s.customFolder, isNull);
    expect(s.effectiveFolder(supportsCustomFolder: true), isNull);
  });

  test('写入再读回：间隔、时间、类别、复习媒体、文件夹原样往返', () async {
    final Map<String, Object?> prefs = <String, Object?>{};
    const AutoBackupSettings written = AutoBackupSettings(
      interval: AutoBackupInterval.every3Days,
      preferredMinuteOfDay: 3 * 60 + 30,
      categories: <BackupCategory>{BackupCategory.books, BackupCategory.srs},
      includeSrsMedia: true,
      customFolder: '/backups/fushi',
    );
    await writeAutoBackupSettings(
      (Map<String, dynamic> values) async => prefs.addAll(values),
      written,
    );
    final AutoBackupSettings read = readAutoBackupSettings(
      (String key) => prefs[key],
    );
    expect(read, written);
    expect(read.categories, written.categories);
    expect(read.includeSrsMedia, isTrue);
    expect(read.effectiveFolder(supportsCustomFolder: false), isNull);

    // 清掉时间与文件夹（「任意时间」/「改回默认」）也能往返。
    await writeAutoBackupSettings(
      (Map<String, dynamic> values) async => prefs.addAll(values),
      read.copyWith(
        interval: AutoBackupInterval.off,
        preferredMinuteOfDay: () => null,
        customFolder: () => null,
      ),
    );
    final AutoBackupSettings cleared = readAutoBackupSettings(
      (String key) => prefs[key],
    );
    expect(cleared.interval, AutoBackupInterval.off);
    expect(cleared.enabled, isFalse);
    expect(cleared.preferredMinuteOfDay, isNull);
    expect(cleared.customFolder, isNull);
  });

  test('每个间隔都有自己的文案', () {
    final Set<String> labels = <String>{
      for (final AutoBackupInterval v in AutoBackupInterval.values)
        autoBackupIntervalLabel(v),
    };
    expect(labels, hasLength(AutoBackupInterval.values.length));
  });

  test('状态行：没备份过 →「还没有备份」；有 → 时间 · 大小 · 保留份数', () {
    final DateTime now = DateTime(2026, 11, 25, 15);
    expect(
      autoBackupStatusLine(
        status: const AutoBackupStatus(),
        keptCount: 0,
        now: now,
      ),
      t.auto_backup_status_none,
    );
    final String line = autoBackupStatusLine(
      status: AutoBackupStatus(
        lastSuccessMs: now
            .subtract(const Duration(hours: 3))
            .millisecondsSinceEpoch,
        lastSuccessBytes: 412 * 1024 * 1024,
      ),
      keptCount: 14,
      now: now,
    );
    expect(line, contains(formatStorageBytes(412 * 1024 * 1024)));
    expect(line, contains('14'));
    expect(line, contains(t.activity_hours_ago(n: 3)));
  });
}
