import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-082 source guards: batch dictionary import must not block ~3s per failed
/// dictionary, and failures must be surfaced to the caller (rethrown) so the
/// UI can collect them and show a single summary at the end.
void main() {
  final manager =
      File('lib/src/models/dictionary_import_manager.dart').readAsStringSync();
  final dialog =
      File('lib/src/pages/implementations/dictionary_dialog_page.dart')
          .readAsStringSync();

  group('dictionary_import_manager.dart', () {
    test('no per-failure 3-second blocking delay remains', () {
      expect(manager.contains('Duration(seconds: 3)'), isFalse,
          reason:
              'the 3s dwell on each failed import is the reported symptom and '
              'must be removed');
    });

    test('import failures are rethrown as a typed exception', () {
      expect(manager.contains('throw DictionaryImportException'), isTrue,
          reason:
              'importFromFile/importFromDirectory must rethrow so the batch '
              'caller can collect and summarize failures');
    });

    test('a shared summary formatter exists for batch reporting', () {
      expect(
          manager.contains('static String formatImportFailureSummary'), isTrue);
    });
  });

  group('dictionary_dialog_page.dart batch loop', () {
    test('collects failed names and shows one summary', () {
      expect(dialog.contains('failedNames'), isTrue,
          reason: 'the multi-file import loop must collect failures');
      expect(dialog.contains('formatImportFailureSummary'), isTrue,
          reason: 'and present them via the shared summary formatter');
    });

    test('no import path (including folder import) blocks 3 seconds', () {
      // W2: the single-folder import catch used to keep a 3s dwell even after
      // the manager dropped its delays. No dictionary import path may block 3s.
      expect(dialog.contains('Duration(seconds: 3)'), isFalse,
          reason:
              'folder import must surface failures via toast, not a 3s wait');
    });
  });
}
