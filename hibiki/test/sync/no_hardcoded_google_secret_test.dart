import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Anti-recurrence guard. A Google OAuth client secret (`GOCSPX-...`) was once
/// hardcoded in `google_drive_auth.dart` and leaked to a public mirror, where
/// GitGuardian flagged it. Google treats the desktop client secret as
/// non-confidential (it ships in the binary), but committing the value lets
/// scanners re-flag it on every push and keeps a rotated value public.
///
/// The real value now lives only in `lib/src/sync/google_oauth_secret.dart`,
/// which is gitignored; the committed `.example.dart` template carries a
/// non-`GOCSPX-` placeholder. This guard fails if a `GOCSPX-` secret reappears
/// in any committed Dart source under lib/.
void main() {
  test('no hardcoded GOCSPX- Google OAuth secret in committed lib/ sources',
      () {
    final Directory dir = Directory('lib');
    expect(dir.existsSync(), isTrue,
        reason: 'run from the hibiki/ package root');

    // The gitignored file legitimately holds the real secret and is never
    // committed, so it is excluded from the committed-surface scan.
    const String ignoredBasename = 'google_oauth_secret.dart';
    final RegExp googleSecret = RegExp(r'GOCSPX-[\w-]+');
    final List<String> offenders = <String>[];

    for (final FileSystemEntity entity in dir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.uri.pathSegments.last == ignoredBasename) continue;
      final String content = entity.readAsStringSync();
      for (final RegExpMatch m in googleSecret.allMatches(content)) {
        final int line =
            '\n'.allMatches(content.substring(0, m.start)).length + 1;
        offenders.add('${entity.path}:$line');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'A Google OAuth client secret (GOCSPX-...) is hardcoded in '
          'committed source. Move the value to the gitignored '
          'lib/src/sync/google_oauth_secret.dart (copy from its .example.dart) '
          'and reference kGoogleOAuthClientSecret instead. Offenders:\n'
          '${offenders.join('\n')}',
    );
  });
}
