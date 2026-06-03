import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/epub/book_title_conflict.dart';

void main() {
  group('resolveBookTitleConflict', () {
    test('no conflict returns proposed title and never calls callback',
        () async {
      var called = false;
      final String out = await resolveBookTitleConflict(
        existingTitles: const <String>['Rust'],
        proposedTitle: 'Go',
        onDuplicateTitle: (_) async {
          called = true;
          return DuplicateTitleResolution.cancel;
        },
      );
      expect(out, 'Go');
      expect(called, isFalse);
    });

    test('conflict + addSuffix returns " (2)" suffixed title', () async {
      final String out = await resolveBookTitleConflict(
        existingTitles: const <String>['Rust'],
        proposedTitle: 'Rust',
        onDuplicateTitle: (_) async => DuplicateTitleResolution.addSuffix,
      );
      expect(out, 'Rust (2)');
    });

    test('addSuffix skips already-taken suffixes', () async {
      final String out = await resolveBookTitleConflict(
        existingTitles: const <String>['Rust', 'Rust (2)'],
        proposedTitle: 'Rust',
        onDuplicateTitle: (_) async => DuplicateTitleResolution.addSuffix,
      );
      expect(out, 'Rust (3)');
    });

    test('conflict + cancel throws DuplicateImportCancelledException',
        () async {
      expect(
        () => resolveBookTitleConflict(
          existingTitles: const <String>['Rust'],
          proposedTitle: 'Rust',
          onDuplicateTitle: (_) async => DuplicateTitleResolution.cancel,
        ),
        throwsA(isA<DuplicateImportCancelledException>()),
      );
    });

    test('no callback auto-suffixes (keeps invariant for programmatic callers)',
        () async {
      final String out = await resolveBookTitleConflict(
        existingTitles: const <String>['Rust'],
        proposedTitle: 'Rust',
      );
      expect(out, 'Rust (2)');
    });

    test('conflict is judged on the sync key sanitizeTtuFilename(title)',
        () async {
      // "a*" sanitizes to "a~ttu-star~"; a second "a*" must be detected as dup.
      final String out = await resolveBookTitleConflict(
        existingTitles: const <String>['a*'],
        proposedTitle: 'a*',
        onDuplicateTitle: (_) async => DuplicateTitleResolution.addSuffix,
      );
      expect(out, 'a* (2)');
    });
  });

  test('EpubImporter wires the conflict resolver into both import paths', () {
    final String src =
        File('lib/src/epub/epub_importer.dart').readAsStringSync();
    // 两条插库路径都必须在 insert 前过 resolveBookTitleConflict，且暴露回调。
    expect(
      'resolveBookTitleConflict'.allMatches(src).length,
      greaterThanOrEqualTo(2),
      reason: 'both import() and importFromPath() must resolve title conflicts',
    );
    expect(src.contains('onDuplicateTitle'), isTrue);
  });
}
