import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/settings/database_check_action.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_storage.dart';
import 'package:fushi_core/fushi_core.dart';

/// 反馈 s2fdTTmLyh：设置 → 存储 →「检查数据库」的入口与结果文案。
void main() {
  // LocaleSettings.setLocale 经 slang_flutter 碰 WidgetsBinding.instance。
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  test('存储页有「检查数据库」动作，控制通道需 --yes 确认', () {
    final SettingsActionItem item = buildStorageDestination().sections
        .expand((SettingsSection s) => s.items)
        .whereType<SettingsActionItem>()
        .singleWhere((SettingsActionItem i) => i.id == 'storage.db_check');
    expect(item.title, t.storage_db_check_title);
    expect(item.cli, isNotNull);
    expect(item.cli!.run, isNotNull);
    expect(item.cli!.confirm, isTrue);
  });

  test('完好 + 修了乱码行：报告逐行说清完整性、修复数、大小与备份', () {
    const DatabaseCheckReport report = DatabaseCheckReport(
      problemsFound: <String>[],
      problemsRemaining: <String>[],
      sizeBeforeBytes: 1024 * 1024 * 1024,
      sizeAfterBytes: 20 * 1024 * 1024,
      repairedReadingStatRows: 40,
      repairedLookupCounterRows: 4,
      backupPath: '/data/fushi.db.check-bak-1.db',
      backupBytes: 1024 * 1024 * 1024,
    );
    final List<String> lines = databaseCheckReportLines(report);
    expect(lines.first, t.storage_db_check_integrity_ok);
    expect(lines, contains(t.storage_db_check_repaired_rows(n: 44)));
    expect(
      lines.any((String l) => l.contains('/data/fushi.db.check-bak-1.db')),
      isTrue,
    );
    expect(lines, isNot(contains(t.storage_db_check_rolled_back)));
  });

  test('失败回滚：报告带失败阶段、原因与回滚说明', () {
    const DatabaseCheckReport report = DatabaseCheckReport(
      problemsFound: <String>[],
      problemsRemaining: <String>[],
      sizeBeforeBytes: 10,
      sizeAfterBytes: 10,
      rolledBack: true,
      failedPhase: DatabaseCheckPhase.verify,
      failure: 'boom',
      backupPath: '/data/fushi.db.check-bak-2.db',
      backupBytes: 10,
    );
    final List<String> lines = databaseCheckReportLines(report);
    expect(
      lines,
      contains(
        t.storage_db_check_failed(
          phase: t.storage_db_check_phase_verify,
          reason: 'boom',
        ),
      ),
    );
    expect(lines, contains(t.storage_db_check_rolled_back));
    expect(report.healthy, isFalse);
  });

  test('就地修不好的结构问题：提示从备份恢复并列出问题原文', () {
    const DatabaseCheckReport report = DatabaseCheckReport(
      problemsFound: <String>['page 3 corrupt'],
      problemsRemaining: <String>['page 3 corrupt'],
      sizeBeforeBytes: 10,
      sizeAfterBytes: 10,
      reindexed: true,
    );
    final List<String> lines = databaseCheckReportLines(report);
    expect(lines.first, t.storage_db_check_integrity_bad(n: 1));
    expect(lines, contains('· page 3 corrupt'));
    expect(lines, isNot(contains(t.storage_db_check_no_repairs)));
  });
}
