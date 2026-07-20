import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-836 Google Drive source-scan guards（合并自
/// google_drive_appdata_guard_test.dart + google_drive_scope_guard_test.dart；
/// 断言逐字搬运，每条保持独立 test()）。
void main() {
  /// TODO-836 HARD GUARD: after the sync root moved to the hidden appDataFolder
  /// space, EVERY `api.files.list(...)` call MUST pass `spaces: 'appDataFolder'`.
  /// Drive's files.list defaults to `spaces=drive` (the visible Drive); a subquery
  /// with `'<folderId>' in parents` does NOT auto-follow the parent into the
  /// appdata space — without an explicit spaces it returns an EMPTY result with NO
  /// error (a silent data-loss regression worse than the original 403). Missing it
  /// on even one call breaks that data link, so we assert per-block.
  group('appDataFolder space pins (google_drive_handler.dart)', () {
    final File handler = File('lib/src/sync/google_drive_handler.dart');

    test('every api.files.list( call passes spaces: \'appDataFolder\'', () {
      expect(handler.existsSync(), isTrue,
          reason: 'run from the hibiki/ package root');
      final String src = handler.readAsStringSync();

      // Split the source into each files.list( ... ); call block by bracket
      // matching from the '(' that follows 'api.files.list'.
      final List<String> blocks = <String>[];
      final RegExp listCall = RegExp(r'api\.files\.list\(');
      for (final RegExpMatch m in listCall.allMatches(src)) {
        int depth = 0;
        int i = m.end - 1; // position at the '('
        final StringBuffer buf = StringBuffer();
        for (; i < src.length; i++) {
          final String c = src[i];
          buf.write(c);
          if (c == '(') {
            depth++;
          } else if (c == ')') {
            depth--;
            if (depth == 0) break;
          }
        }
        blocks.add(buf.toString());
      }

      expect(blocks.length, 7,
          reason: 'expected exactly 7 files.list calls in the handler; if this '
              'changed, audit each new call for spaces: appDataFolder');

      final List<int> missing = <int>[];
      for (int b = 0; b < blocks.length; b++) {
        if (!blocks[b].contains("spaces: 'appDataFolder'")) missing.add(b);
      }
      expect(missing, isEmpty,
          reason: 'files.list block(s) at index $missing lack '
              "spaces: 'appDataFolder' → would silently query the visible "
              'Drive and return empty in the appdata space (TODO-836)');
    });

    test('the sync root is created under the appDataFolder space alias', () {
      final String src = handler.readAsStringSync();
      expect(src.contains("..parents = ['appDataFolder']"), isTrue,
          reason: 'findOrCreateRootFolder must anchor the root in the App Data '
              'space (parents=[appDataFolder]) (TODO-836)');
    });
  });

  /// TODO-836: sync data moved from the user-visible Drive (drive.file) into the
  /// hidden, app-private appDataFolder space (drive.appdata), so the root-folder
  /// name lookup is no longer a cross-app query that Google rejects with 403
  /// insufficient_scope. These source-scan guards pin the migration:
  ///   - the app requests drive.appdata,
  ///   - it no longer requests the visible-Drive scope (no `auth/drive.file`),
  ///   - mobile and desktop request the SAME Drive scope (else云数据落不同空间).
  group('drive.appdata scope pins (google_drive_auth.dart)', () {
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
          RegExp(r"'scope':\s*\[_driveAppdataScope,\s*_emailScope\]")
              .hasMatch(s),
          isTrue,
          reason: 'desktop auth URL must request drive.appdata (+ email)');
      // The old visible-Drive scope symbol must be gone entirely.
      expect(s.contains('_driveFileScope'), isFalse,
          reason: 'the drive.file scope constant must be removed (TODO-836)');
    });
  });
}
