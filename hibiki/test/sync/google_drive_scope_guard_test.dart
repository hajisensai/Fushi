import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-836: sync data moved from the user-visible Drive (drive.file) into the
/// hidden, app-private appDataFolder space (drive.appdata), so the root-folder
/// name lookup is no longer a cross-app query that Google rejects with 403
/// insufficient_scope. These source-scan guards pin the migration:
///   - the app requests drive.appdata,
///   - it no longer requests the visible-Drive scope (no `auth/drive.file`),
///   - mobile and desktop request the SAME Drive scope (else云数据落不同空间).
void main() {
  final File authFile = File('lib/src/sync/google_drive_auth.dart');

  String source() {
    expect(authFile.existsSync(), isTrue,
        reason: 'run from the hibiki/ package root');
    return authFile.readAsStringSync();
  }

  test('requests the drive.appdata scope', () {
    expect(source().contains('https://www.googleapis.com/auth/drive.appdata'),
        isTrue,
        reason: 'sync root must live in the appDataFolder space (TODO-836)');
  });

  test('no longer requests the visible-Drive drive.file scope', () {
    expect(source().contains('auth/drive.file'), isFalse,
        reason:
            'drive.file forced the whole-Drive root lookup → 403 insufficient_scope; '
            'it must be fully removed, not left dangling (TODO-836)');
  });

  test(
      'mobile (scopes:) and desktop (auth URL scope:) request the same '
      'Drive scope — both drive.appdata', () {
    final String s = source();
    // Mobile: GoogleSignIn(scopes: [_driveAppdataScope])
    expect(RegExp(r'scopes:\s*\[_driveAppdataScope\]').hasMatch(s), isTrue,
        reason: 'mobile sign-in must request drive.appdata');
    // Desktop PKCE auth URL: scope: [_driveAppdataScope, _emailScope]
    expect(
        RegExp(r"'scope':\s*\[_driveAppdataScope,\s*_emailScope\]").hasMatch(s),
        isTrue,
        reason: 'desktop auth URL must request drive.appdata (+ email)');
    // The old visible-Drive scope symbol must be gone entirely.
    expect(s.contains('_driveFileScope'), isFalse,
        reason: 'the drive.file scope constant must be removed (TODO-836)');
  });
}
