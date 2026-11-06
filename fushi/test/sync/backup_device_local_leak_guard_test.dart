import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_merge_engine.dart';

/// BUG-816 regression guard (source scan): the LAN pairing `token` and sync
/// baselines live in their OWN tables (`fushi_paired_peers` / `sync_baselines`),
/// which the `preferences`-key credential sweeps cannot reach. A future refactor
/// that drops the table wipe from `_stripCredentials` would silently re-leak the
/// plaintext pairing token into every shared backup. Lock the invariant in
/// source: `_deviceLocalTables` must list both tables plus the Mihon runtime and
/// v78 durable-download state tables, and `_stripCredentials` must delete every
/// device-local table in FK-safe child-first order.
void main() {
  test('_stripCredentials wipes the device-local pairing/baseline tables', () {
    final File f = File('lib/src/sync/backup_service.dart');
    expect(f.existsSync(), isTrue, reason: 'run from the fushi/ package root');
    final String s = f.readAsStringSync();

    // The device-local table registry names both tables. B1 分家后它是导出侧与
    // 恢复侧共用的库级顶层常量（不再是 BackupService 的 static 成员）。
    final int listStart = s.indexOf('const List<String> _deviceLocalTables =');
    expect(
      listStart,
      greaterThan(-1),
      reason: '_deviceLocalTables constant must exist',
    );
    final int listEnd = s.indexOf('];', listStart);
    expect(listEnd, greaterThan(listStart));
    final String listBody = s.substring(listStart, listEnd);
    expect(
      listBody.contains("'fushi_paired_peers'"),
      isTrue,
      reason: 'pairing table (holds the plaintext token) must be device-local',
    );
    expect(
      listBody.contains("'sync_baselines'"),
      isTrue,
      reason: 'sync baselines must be device-local',
    );
    for (final String table in <String>[
      'manga_extension_stores',
      'manga_extensions',
      'manga_online_sources',
      'manga_source_preferences',
      'manga_trusted_signers',
    ]) {
      expect(
        listBody.contains("'$table'"),
        isTrue,
        reason: '$table must not leave the device in a shared backup',
      );
    }
    const List<String> videoTablesChildFirst = <String>[
      'video_download_subscription_items',
      'video_download_job_subtitles',
      'video_download_job_files',
      'video_download_subscriptions',
      'video_download_jobs',
    ];
    int previousOffset = -1;
    for (final String table in videoTablesChildFirst) {
      final int offset = listBody.indexOf("'$table'");
      expect(
        offset,
        greaterThan(previousOffset),
        reason: '$table must be deleted after its FK children',
      );
      previousOffset = offset;
    }

    final int parentListStart = s.indexOf(
      'const List<String> _deviceLocalTablesParentFirst =',
    );
    expect(parentListStart, greaterThan(-1));
    final int parentListEnd = s.indexOf('];', parentListStart);
    final String parentListBody = s.substring(parentListStart, parentListEnd);
    const List<String> videoTablesParentFirst = <String>[
      'video_download_jobs',
      'video_download_subscriptions',
      'video_download_job_files',
      'video_download_job_subtitles',
      'video_download_subscription_items',
    ];
    previousOffset = -1;
    for (final String table in videoTablesParentFirst) {
      final int offset = parentListBody.indexOf("'$table'");
      expect(
        offset,
        greaterThan(previousOffset),
        reason: '$table must be restored after its FK parents',
      );
      previousOffset = offset;
    }

    // _stripCredentials must iterate the device-local tables and DELETE them,
    // so the export copy carries neither the token nor the baselines.
    final int stripStart = s.indexOf('_stripCredentials(String dbDirectory)');
    expect(stripStart, greaterThan(-1), reason: '_stripCredentials must exist');
    // 命名统一后备份内部子步骤 restore* → reapply*/strip*：锚到下一个 static
    // 方法声明即可，不与具体后继方法名耦合。
    final int stripEnd = s.indexOf(
      'static Future<void> _strip',
      stripStart + 1,
    );
    expect(stripEnd, greaterThan(stripStart));
    final String stripBody = s.substring(stripStart, stripEnd);
    expect(
      stripBody.contains('_deviceLocalTables') &&
          stripBody.contains('DELETE FROM \$table'),
      isTrue,
      reason: '_stripCredentials must DELETE every _deviceLocalTables entry',
    );
  });
  // SRS（2026-10-23 起归 Rust 的 srs.db）：本机状态 / 缓存五表不离开本机、覆盖恢复后清空而不
  // 回灌；数据本体四表随「复习」类别以 srs.db 快照走。主库里只剩老形态（还没搬迁的库 / 老备份）
  // 的残表，由 backup_srs_tables.dart 统一处置。
  const List<String> srsLocal = <String>[
    'srs_event_local',
    'srs_local_state',
    'srs_notes_cache',
    'srs_cards_cache',
    'srs_sent_batches',
  ];
  const List<String> srsData = <String>[
    'srs_entities',
    'srs_field_edits',
    'srs_review_logs',
    'srs_unknown_events',
  ];

  test('SRS device-local tables are stripped on export and discarded on '
      'restore', () {
    final String tables = File(
      'lib/src/sync/backup_srs_tables.dart',
    ).readAsStringSync();
    final int listStart = tables.indexOf(
      'const List<String> kSrsDeviceLocalTableNames =',
    );
    expect(listStart, greaterThan(-1));
    final String listBody = tables.substring(
      listStart,
      tables.indexOf('];', listStart),
    );
    for (final String table in srsLocal) {
      expect(listBody, contains("'$table'"));
    }
    for (final String table in srsData) {
      expect(
        listBody,
        isNot(contains("'$table'")),
        reason: '$table 是 SRS 数据本体，必须随备份走',
      );
    }

    final String s = File(
      'lib/src/sync/backup_service.dart',
    ).readAsStringSync();
    // 数据本体与本机状态都不得进「从 bak 回灌」的设备本地表（那会把恢复的数据
    // 换回本机旧的 / 让旧本机状态套在新数据上）。
    final int devStart = s.indexOf('const List<String> _deviceLocalTables =');
    final String devBody = s.substring(devStart, s.indexOf('];', devStart));
    for (final String table in <String>[...srsLocal, ...srsData]) {
      expect(
        devBody,
        isNot(contains("'$table'")),
        reason: '$table 不得从 pre-restore.bak 回灌',
      );
    }

    final int stripStart = s.indexOf('_stripCredentials(String dbDirectory)');
    final String stripBody = s.substring(
      stripStart,
      s.indexOf('static Future<void> _strip', stripStart + 1),
    );
    expect(
      stripBody,
      contains('clearLegacySrsDeviceLocalTables'),
      reason: '_stripCredentials 必须清空老形态主库里的 SRS 本机状态 / 缓存',
    );
    // 新形态：srs.db 快照由 Rust 清空设备本地表。
    expect(s, contains('snapshotInto(path, stripDeviceLocal: true)'));

    final String restore = File(
      'lib/src/sync/backup_service/restore.part.dart',
    ).readAsStringSync();
    final int reapplyStart = restore.indexOf(
      'static Future<bool> _reapplyDeviceLocalTablesFromBak(',
    );
    expect(reapplyStart, greaterThan(-1));
    final String reapplyBody = restore.substring(
      reapplyStart,
      restore.indexOf('static Future<bool> _hasSqliteHeader'),
    );
    expect(
      reapplyBody,
      contains('clearLegacySrsDeviceLocalTables'),
      reason: '覆盖恢复后必须清空 SRS 本机状态，让引擎换新化身',
    );
  });

  test('merge import never touches SRS tables on the generic path', () {
    // SRS 表不在主库 schema 里，通用路径的跳过清单也不再列它们；老形态备份里的残表只由
    // SRS 专用步骤（BackupMergeEngine._mergeSrs）读。
    final List<String> skipped = mergeSkippedDeviceLocalTableNames();
    for (final String table in <String>[...srsLocal, ...srsData]) {
      expect(skipped, isNot(contains(table)));
    }
    final String engine = File(
      'lib/src/sync/backup_merge_engine.dart',
    ).readAsStringSync();
    for (final String table in <String>[...srsLocal, ...srsData]) {
      expect(engine, isNot(contains(table)), reason: table);
    }
  });
}
