import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/storage/storage_usage_service.dart'
    show formatStorageBytes;
import 'package:fushi/src/sync/auto_backup/auto_backup_messages.dart';
import 'package:fushi/src/sync/auto_backup/auto_backup_settings.dart';
import 'package:fushi/src/sync/auto_backup/auto_backup_status.dart';
import 'package:fushi/src/sync/auto_backup/backup_folder_mirror.dart';
import 'package:fushi/src/sync/backup_service.dart' show BackupCategory;
import 'package:fushi/src/sync/sync_settings_schema.dart'
    show
        autoBackupIntervalLabel,
        autoBackupMirrorStatusLine,
        autoBackupStatusLine;

/// 设置 › 同步与备份 ›「自动备份」：缺省值（D1 默认开、每日、小集合；D2 复习媒体默认不带）、
/// 偏好往返、状态行文案。
void main() {
  test('空偏好：每日、不指定时间、默认小集合、不带复习媒体、默认目录', () {
    final AutoBackupSettings s = readAutoBackupSettings((String _) => null);
    expect(s.interval, AutoBackupInterval.daily);
    expect(s.enabled, isTrue);
    expect(s.preferredMinuteOfDay, isNull);
    // 整库 + 挑文件（用户 2026-11-25）：数据恒在，文件默认只带字体。
    expect(s.categories, <BackupCategory>{BackupCategory.fonts});
    expect(s.includeSrsMedia, isFalse);
    expect(s.customFolder, isNull);
    expect(s.effectiveFolder(supportsCustomFolder: true), isNull);
  });

  test('写入再读回：间隔、时间、类别、复习媒体、文件夹原样往返', () async {
    final Map<String, Object?> prefs = <String, Object?>{};
    const AutoBackupSettings written = AutoBackupSettings(
      interval: AutoBackupInterval.every3Days,
      preferredMinuteOfDay: 3 * 60 + 30,
      categories: <BackupCategory>{
        BackupCategory.books,
        BackupCategory.dictionary,
      },
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

  test('写入只落文件类别：数据类别不进偏好', () async {
    final Map<String, Object?> prefs = <String, Object?>{};
    await writeAutoBackupSettings(
      (Map<String, dynamic> values) async => prefs.addAll(values),
      const AutoBackupSettings(
        categories: <BackupCategory>{
          BackupCategory.fonts,
          BackupCategory.statistics,
        },
      ),
    );
    expect(
      readAutoBackupSettings((String key) => prefs[key]).categories,
      <BackupCategory>{BackupCategory.fonts},
    );
  });

  test('错误码换成本地化文案，其余原样', () {
    expect(
      autoBackupErrorText(kAutoBackupErrorInterrupted),
      t.auto_backup_error_interrupted,
    );
    expect(
      autoBackupErrorText(kAutoBackupErrorFolderUnavailable),
      t.auto_backup_error_folder_unavailable,
    );
    expect(autoBackupErrorText('disk full'), 'disk full');
    expect(autoBackupErrorText(null), '');
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

  test('用户文件夹（第三期）：句柄与显示名往返，只在支持的平台生效，停止复制清掉', () async {
    final Map<String, Object?> prefs = <String, Object?>{};
    const AutoBackupMirrorFolder folder = AutoBackupMirrorFolder(
      handle:
          'content://com.android.externalstorage.documents/tree/primary%3ABackups',
      label: 'Backups',
    );
    await writeAutoBackupSettings(
      (Map<String, dynamic> values) async => prefs.addAll(values),
      const AutoBackupSettings(mirrorFolder: folder),
    );
    final AutoBackupSettings read = readAutoBackupSettings(
      (String key) => prefs[key],
    );
    expect(read.mirrorFolder, folder);
    expect(read.effectiveMirrorFolder(supportsMirrorFolder: true), folder);
    expect(read.effectiveMirrorFolder(supportsMirrorFolder: false), isNull);
    // 换文件夹 = 设置不同（存设置后会补复制进新文件夹）。
    expect(
      read ==
          read.copyWith(
            mirrorFolder: () =>
                const AutoBackupMirrorFolder(handle: 'other', label: 'Backups'),
          ),
      isFalse,
    );
    await writeAutoBackupSettings(
      (Map<String, dynamic> values) async => prefs.addAll(values),
      read.copyWith(mirrorFolder: () => null),
    );
    expect(
      readAutoBackupSettings((String key) => prefs[key]).mirrorFolder,
      isNull,
    );
    // 不把书签 / URI 原文写进状态文件：只用短标识。
    expect(folder.key, hasLength(16));
    expect(folder.key, isNot(contains('content')));
  });

  test('用户文件夹状态行：没备份 → 不显示；已复制 / 待复制 / 失败', () {
    final DateTime now = DateTime(2026, 11, 25, 15);
    const AutoBackupMirrorFolder folder = AutoBackupMirrorFolder(
      handle: 'h',
      label: 'Backups',
    );
    expect(
      autoBackupMirrorStatusLine(
        status: const AutoBackupStatus(),
        folder: folder,
        now: now,
      ),
      isNull,
    );
    final AutoBackupStatus base = AutoBackupStatus(
      lastSuccessPointId: 'p1',
      lastSuccessMs: now.millisecondsSinceEpoch,
    );
    expect(
      autoBackupMirrorStatusLine(status: base, folder: folder, now: now)!.text,
      t.auto_backup_mirror_status_pending,
    );
    final AutoBackupStatus copied = base.withMirror(
      const AutoBackupMirrorStatus().succeeded(
        folderKey: folder.key,
        id: 'p1',
        atMs: now.subtract(const Duration(hours: 2)).millisecondsSinceEpoch,
      ),
    );
    final ({String text, bool failed}) done = autoBackupMirrorStatusLine(
      status: copied,
      folder: folder,
      now: now,
    )!;
    expect(done.failed, isFalse);
    expect(done.text, contains(t.activity_hours_ago(n: 2)));
    // 复制状态是另一个文件夹的：当作还没复制。
    expect(
      autoBackupMirrorStatusLine(
        status: copied,
        folder: const AutoBackupMirrorFolder(handle: 'x', label: 'X'),
        now: now,
      )!.text,
      t.auto_backup_mirror_status_pending,
    );
    final ({String text, bool failed}) failed = autoBackupMirrorStatusLine(
      status: copied.withMirror(
        copied.mirror.failed(
          folderKey: folder.key,
          error: kAutoBackupErrorFolderUnavailable,
          atMs: now.millisecondsSinceEpoch,
        ),
      ),
      folder: folder,
      now: now,
    )!;
    expect(failed.failed, isTrue);
    expect(
      failed.text,
      t.auto_backup_mirror_failed(
        reason: autoBackupErrorText(kAutoBackupErrorFolderUnavailable),
      ),
    );
    // 复制状态随状态文件往返，其它状态转换不丢它。
    final AutoBackupStatus roundTrip = AutoBackupStatus.fromJson(
      copied.toJson(),
    ).skipped(atMs: now.millisecondsSinceEpoch);
    expect(roundTrip.mirror.holds(folder.key, 'p1'), isTrue);
  });
}
