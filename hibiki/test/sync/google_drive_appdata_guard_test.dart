import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-836 HARD GUARD: after the sync root moved to the hidden appDataFolder
/// space, EVERY `api.files.list(...)` call MUST pass `spaces: 'appDataFolder'`.
/// Drive's files.list defaults to `spaces=drive` (the visible Drive); a subquery
/// with `'<folderId>' in parents` does NOT auto-follow the parent into the
/// appdata space — without an explicit spaces it returns an EMPTY result with NO
/// error (a silent data-loss regression worse than the original 403). Missing it
/// on even one call breaks that data link, so we assert per-block.
void main() {
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
            "spaces: 'appDataFolder' → would silently query the visible Drive "
            'and return empty in the appdata space (TODO-836)');
  });

  test('the sync root is created under the appDataFolder space alias', () {
    final String src = handler.readAsStringSync();
    expect(src.contains("..parents = ['appDataFolder']"), isTrue,
        reason: 'findOrCreateRootFolder must anchor the root in the App Data '
            'space (parents=[appDataFolder]) (TODO-836)');
  });
}
