import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String source = File(
    'lib/src/media/manga/reader/manga_fushi_page.dart',
  ).readAsStringSync();

  test('restore and live reset share the mode precedence resolver', () {
    expect('MangaFushiPage.resolveReaderMode('.allMatches(source).length, 2);
    final int start = source.indexOf(
      'Future<void> _reapplyReaderPreferences()',
    );
    final int end = source.indexOf('Future<void> _showPageJumpDialog()', start);
    final String body = source.substring(start, end);
    expect(body, contains('hasModeOverride: hasModeOverride'));
    expect(body, contains('legacyMode: row.mangaReadingMode'));
    expect(body, isNot(contains(': _mode;')));
  });

  test(
    'serialized step consumes the half page before panel or spread changes',
    () {
      final int start = source.indexOf(
        'Future<void> _applyMangaTurnStep(int delta)',
      );
      final int end = source.indexOf('// ── 换章', start);
      final String body = source.substring(start, end);
      final int probe = body.indexOf('window.__mangaTurnWithinPage(');
      final int consumed = body.indexOf(
        'if (MangaWindowGeneration.parse(consumed) == 1) return;',
      );
      final int panel = body.indexOf('await _tryPanelTurn(');
      final int advance = body.indexOf('_currentSpread = target;');
      expect(probe, greaterThanOrEqualTo(0));
      expect(consumed, greaterThan(probe));
      expect(panel, greaterThan(consumed));
      expect(advance, greaterThan(panel));
      expect(body, contains('!identical(session, _pageSession)'));
      expect(body, contains('!identical(controller, _controller)'));
    },
  );
}
