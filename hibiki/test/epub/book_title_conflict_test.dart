import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/epub/book_title_conflict.dart';

void main() {
  group('resolveDuplicateTitle', () {
    test('no conflict returns proposed title and never calls callback',
        () async {
      var called = false;
      final String out = await resolveDuplicateTitle(
        existingTitles: const <String>['Rust'],
        proposedTitle: 'Go',
        policy: DuplicatePolicy.ask((_) async {
          called = true;
          return DuplicateChoice.cancel;
        }),
      );
      expect(out, 'Go');
      expect(called, isFalse);
    });

    test('conflict + addSuffix returns " (2)" suffixed title', () async {
      final String out = await resolveDuplicateTitle(
        existingTitles: const <String>['Rust'],
        proposedTitle: 'Rust',
        policy: DuplicatePolicy.ask((_) async => DuplicateChoice.suffix),
      );
      expect(out, 'Rust (2)');
    });

    test('addSuffix skips already-taken suffixes', () async {
      final String out = await resolveDuplicateTitle(
        existingTitles: const <String>['Rust', 'Rust (2)'],
        proposedTitle: 'Rust',
        policy: DuplicatePolicy.ask((_) async => DuplicateChoice.suffix),
      );
      expect(out, 'Rust (3)');
    });

    test('conflict + cancel throws DuplicateImportCancelledException',
        () async {
      expect(
        () => resolveDuplicateTitle(
          existingTitles: const <String>['Rust'],
          proposedTitle: 'Rust',
          policy: DuplicatePolicy.ask((_) async => DuplicateChoice.cancel),
        ),
        throwsA(isA<DuplicateImportCancelledException>()),
      );
    });

    test('no callback auto-suffixes (keeps invariant for programmatic callers)',
        () async {
      final String out = await resolveDuplicateTitle(
        existingTitles: const <String>['Rust'],
        proposedTitle: 'Rust',
      );
      expect(out, 'Rust (2)');
    });

    test('conflict is judged on the sync key sanitizeTtuFilename(title)',
        () async {
      // "a*" sanitizes to "a~ttu-star~"; a second "a*" must be detected as dup.
      final String out = await resolveDuplicateTitle(
        existingTitles: const <String>['a*'],
        proposedTitle: 'a*',
        policy: DuplicatePolicy.ask((_) async => DuplicateChoice.suffix),
      );
      expect(out, 'a* (2)');
    });
  });

  test('EpubImporter wires the conflict resolver into both import paths', () {
    final String src =
        File('lib/src/epub/epub_importer.dart').readAsStringSync();
    // 两条插库路径都必须在 insert 前过 resolveDuplicateTitle，且暴露回调。
    expect(
      'resolveDuplicateTitle'.allMatches(src).length,
      greaterThanOrEqualTo(2),
      reason: 'both import() and importFromPath() must resolve title conflicts',
    );
    // 策略参数必须透传到底（此前锁的是 `onDuplicateTitle` 这个旧参数名；三态收敛
    // 成单参 DuplicatePolicy 后，锁的对象换成它——守的仍是「调用方能左右冲突处置」）。
    expect(src.contains('DuplicatePolicy'), isTrue);
  });
}
