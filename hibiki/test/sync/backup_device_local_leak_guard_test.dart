import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-816 regression guard (source scan): the LAN pairing `token` and sync
/// baselines live in their OWN tables (`hibiki_paired_peers` / `sync_baselines`),
/// which the `preferences`-key credential sweeps cannot reach. A future refactor
/// that drops the table wipe from `_stripCredentials` would silently re-leak the
/// plaintext pairing token into every shared backup. Lock the invariant in
/// source: `_deviceLocalTables` must list both tables plus the Mihon runtime and
/// v71 durable-download state tables, and `_stripCredentials` must delete every
/// device-local table in FK-safe child-first order.
void main() {
  test('_stripCredentials wipes the device-local pairing/baseline tables', () {
    final File f = File('lib/src/sync/backup_service.dart');
    expect(f.existsSync(), isTrue, reason: 'run from the hibiki/ package root');
    final String s = f.readAsStringSync();

    // The device-local table registry names both tables.
    final int listStart =
        s.indexOf('static const List<String> _deviceLocalTables =');
    expect(listStart, greaterThan(-1),
        reason: '_deviceLocalTables constant must exist');
    final int listEnd = s.indexOf('];', listStart);
    expect(listEnd, greaterThan(listStart));
    final String listBody = s.substring(listStart, listEnd);
    expect(listBody.contains("'hibiki_paired_peers'"), isTrue,
        reason:
            'pairing table (holds the plaintext token) must be device-local');
    expect(listBody.contains("'sync_baselines'"), isTrue,
        reason: 'sync baselines must be device-local');
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
      expect(offset, greaterThan(previousOffset),
          reason: '$table must be deleted after its FK children');
      previousOffset = offset;
    }

    final int parentListStart = s.indexOf(
      'static const List<String> _deviceLocalTablesParentFirst =',
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
      expect(offset, greaterThan(previousOffset),
          reason: '$table must be restored after its FK parents');
      previousOffset = offset;
    }

    // _stripCredentials must iterate the device-local tables and DELETE them,
    // so the export copy carries neither the token nor the baselines.
    final int stripStart = s.indexOf('_stripCredentials(String dbDirectory)');
    expect(stripStart, greaterThan(-1), reason: '_stripCredentials must exist');
    // 命名统一后备份内部子步骤 restore* → reapply*/strip*：锚到下一个 static
    // 方法声明即可，不与具体后继方法名耦合。
    final int stripEnd =
        s.indexOf('static Future<void> _strip', stripStart + 1);
    expect(stripEnd, greaterThan(stripStart));
    final String stripBody = s.substring(stripStart, stripEnd);
    expect(
      stripBody.contains('_deviceLocalTables') &&
          stripBody.contains('DELETE FROM \$table'),
      isTrue,
      reason: '_stripCredentials must DELETE every _deviceLocalTables entry',
    );
  });
}
