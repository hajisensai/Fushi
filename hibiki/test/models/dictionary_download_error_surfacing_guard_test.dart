import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-447 source guards: the online "download recommended dictionaries" loop
/// must not swallow per-dictionary failures silently. TODO-892 regression had
/// two layers; the native zip.cpp ratio→absolute guard is verified by the C++
/// test (native/hoshidicts/tests/zip_high_ratio_bank_test.cpp). These Dart
/// guards pin the second layer: a failed download/import must be logged to
/// ErrorLogService (full diagnostic) AND surfaced to the user via a persistent
/// failure-summary toast — not stored as a string that disappears with the 2s
/// progress dialog. They also pin the per-import result-summary logging that
/// makes a "0 entries imported" (the native silent-empty symptom) diagnosable.
void main() {
  final dialog =
      File('lib/src/pages/implementations/dictionary_dialog_page.dart')
          .readAsStringSync();
  final manager =
      File('lib/src/models/dictionary_import_manager.dart').readAsStringSync();

  // Isolate the download method body so the guards target the right loop and
  // are not satisfied by an unrelated catch elsewhere in the file. Pure string
  // slicing (no expect()) so it is safe to evaluate at group-build time.
  String downloadMethod() {
    final int start = dialog.indexOf('_downloadSelectedDictionaries(');
    if (start < 0) return '';
    // Slice to the next member declaration ("_safChannel" const follows it).
    final int end = dialog.indexOf('static const _safChannel', start);
    return end > start ? dialog.substring(start, end) : '';
  }

  group('dictionary_dialog_page.dart download loop (BUG-447)', () {
    final String body = downloadMethod();

    test('the download method body was located', () {
      expect(body, isNotEmpty,
          reason: '_downloadSelectedDictionaries(...) up to _safChannel '
              'must be sliceable');
    });

    test('per-dictionary catch captures the stack (catch (e, st)), not bare e',
        () {
      expect(body.contains('catch (e, st)'), isTrue,
          reason:
              'the download catch must capture the stack so the failure can be '
              'fully logged, not stored as a bare string');
    });

    test('failures are logged to ErrorLogService with full diagnostic', () {
      expect(body.contains('ErrorLogService.instance.log('), isTrue,
          reason: 'a failed download/import must write a diagnostic log entry');
      expect(body.contains("'DictionaryDialog.download'"), isTrue,
          reason: 'logged under a stable, greppable source label');
      expect(body.contains('e.runtimeType'), isTrue,
          reason: 'the exception type + url must be in the diagnostic');
    });

    test('failures are collected and surfaced via a persistent summary toast',
        () {
      expect(body.contains('failedNames'), isTrue,
          reason: 'per-dictionary failures must be collected, not dropped');
      expect(
          body.contains('DictionaryImportManager.formatImportFailureSummary'),
          isTrue,
          reason:
              'failures must be shown via the shared summary formatter (same as '
              'the file-import path)');
      expect(body.contains('Toast.LENGTH_LONG'), isTrue,
          reason:
              'the failure summary must be persistent (LENGTH_LONG), not a 2s '
              'progress-dialog flash that vanishes on pop');
    });
  });

  group('dictionary_import_manager.dart result-summary logging (BUG-447)', () {
    test('every native import logs a result summary (title + counts)', () {
      expect(manager.contains('_logImportResultSummary'), isTrue,
          reason: 'each import must log a result summary to ErrorLogService');
      // Both call sites (file + directory import) must record it.
      final int count = '_logImportResultSummary('.allMatches(manager).length;
      expect(count, greaterThanOrEqualTo(3),
          reason:
              'helper definition + two call sites (file & directory import) '
              'must all reference it');
    });

    test('a 0-entry successful import is flagged as a warning', () {
      expect(manager.contains('0 entries imported'), isTrue,
          reason:
              'success with all counts == 0 (the native silent-empty symptom) '
              'must be explicitly flagged so it is grep-able in the log');
    });
  });
}
