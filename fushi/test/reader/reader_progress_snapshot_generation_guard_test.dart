import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String source = File(
    'lib/src/pages/implementations/reader_fushi/navigation.part.dart',
  ).readAsStringSync();

  for (final String method in <String>[
    '_refreshProgress',
    '_syncPositionFromWebViewProgress',
  ]) {
    test('$method rejects a snapshot completed after navigation or reload', () {
      final int start = source.indexOf('Future<void> $method() async {');
      expect(start, isNonNegative);
      final int parse = source.indexOf(
        'parseReaderStableProgressDetails(result)',
        start,
      );
      expect(parse, greaterThan(start));
      final String beforeParse = source.substring(start, parse);
      final int request = beforeParse.indexOf(
        'await controller.evaluateJavascript(',
      );
      expect(request, isNonNegative);
      expect(
        beforeParse.indexOf('final int chapter = _currentChapter;'),
        inInclusiveRange(0, request - 1),
      );
      expect(
        beforeParse.indexOf('final int generation = _navigateGeneration;'),
        inInclusiveRange(0, request - 1),
      );
      expect(
        beforeParse.indexOf(
          'final InAppWebViewController controller = _controller!;',
        ),
        inInclusiveRange(0, request - 1),
      );
      // These must be checked after the async request, before any parsing,
      // fallback UI, restore anchor, ledger or persistence writes.
      final String afterRequest = beforeParse.substring(request);
      for (final String condition in <String>[
        '!mounted',
        '_controller != controller',
        '_navigateGeneration != generation',
        '_currentChapter != chapter',
        '_restoreInFlight',
        '_lyricsMode',
      ]) {
        expect(afterRequest, contains(condition));
      }
      expect(afterRequest, contains('_lyricsMode) {\n      return;\n    }'));
    });
  }
}
