import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-808 source-scan guard: the connect/first-byte/per-attempt timeouts were
/// compressed so dead GFW mirrors fail fast and serial fallback does not pile up
/// into minutes. These constants are private / embedded so they cannot be read
/// at runtime; pin them at the source level to stop a regression silently
/// restoring the slow 30s / 15s values.
void main() {
  const String dir = 'lib/src/utils/misc';
  const String download = '$dir/update_checker_download.dart';
  const String release = '$dir/update_checker_release.dart';
  const String race = '$dir/update_checker_race.dart';

  String read(String path) => File(path).readAsStringSync();

  test('per-attempt body timeout is 8s, not the old 15s (TODO-808)', () {
    final String source = read(download);
    expect(source, contains('_kPerAttemptTimeout = Duration(seconds: 8)'),
        reason: 'per-attempt timeout must be compressed to 8s');
    expect(
        source, isNot(contains('_kPerAttemptTimeout = Duration(seconds: 15)')),
        reason: 'the slow 15s per-attempt timeout must not return');
  });

  test('HttpClient.connectionTimeout is 10s, not the old 30s (TODO-808)', () {
    final String source = read(release);
    expect(source, contains('connectionTimeout = const Duration(seconds: 10)'),
        reason: 'connect timeout must be compressed to 10s');
    expect(source,
        isNot(contains('connectionTimeout = const Duration(seconds: 30)')),
        reason: 'the slow 30s connect timeout must not return');
  });

  test('probe first-byte timeout stays 5s (fast dead-mirror detection)', () {
    final String source = read(race);
    expect(source, contains('_kFirstByteTimeout = Duration(seconds: 5)'),
        reason: 'first-byte probe timeout must stay 5s');
  });

  test('cancellation token exposes the in-flight abort hook (TODO-808)', () {
    final String source = read(race);
    // The abort plumbing is what makes cancel() instant; guard it stays wired.
    expect(source, contains('void registerAbort(void Function() abort)'),
        reason: 'cancellation must accept an in-flight abort callback');
    expect(source, contains('void clearAbort()'));
    expect(source, contains('_fireAbort()'),
        reason: 'cancel() must fire the abort callback');
  });

  test('download callsite force-closes the client on cancel (TODO-808)', () {
    final String source = read(release);
    expect(source, contains('cancellation.registerAbort('),
        reason: 'download must register an abort callback into the token');
    expect(source, contains('close(force: true)'),
        reason: 'abort must force-close the in-flight HttpClient');
    expect(source, contains('cancellation.clearAbort()'),
        reason:
            'finally must clear the abort to avoid closing a reused client');
  });
}
