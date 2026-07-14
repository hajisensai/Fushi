import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-816 regression guard (source scan): the LAN pairing `token` and sync
/// baselines live in their OWN tables (`hibiki_paired_peers` / `sync_baselines`),
/// which the `preferences`-key credential sweeps cannot reach. A future refactor
/// that drops the table wipe from `_stripCredentials` would silently re-leak the
/// plaintext pairing token into every shared backup. Lock the invariant in
/// source: `_deviceLocalTables` must list both tables AND `_stripCredentials`
/// must delete every device-local table.
void main() {
  test('_stripCredentials wipes the device-local pairing/baseline tables', () {
    final File f = File('lib/src/sync/backup_service.dart');
    expect(f.existsSync(), isTrue, reason: 'run from the hibiki/ package root');
    final String s = f.readAsStringSync();

    // The device-local table registry names both tables.
    final int listStart = s.indexOf('_deviceLocalTables');
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

    // _stripCredentials must iterate the device-local tables and DELETE them,
    // so the export copy carries neither the token nor the baselines.
    final int stripStart = s.indexOf('_stripCredentials(String dbDirectory)');
    expect(stripStart, greaterThan(-1), reason: '_stripCredentials must exist');
    final int stripEnd = s.indexOf('static Future<void> _restore', stripStart);
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
