import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/dictionary_import_manager.dart';

void main() {
  group('DictionaryImportManager.formatImportFailureSummary (BUG-082)', () {
    test('single failure names the one dictionary', () {
      final String msg =
          DictionaryImportManager.formatImportFailureSummary(['辞書A']);
      expect(msg, contains('辞書A'));
      expect(msg, isNot(contains(',')),
          reason: 'single failure should not look like a list');
    });

    test('multiple failures list every failed dictionary in one message', () {
      final String msg = DictionaryImportManager.formatImportFailureSummary(
          ['辞書A', '辞書B', '辞書C']);
      expect(msg, contains('辞書A'));
      expect(msg, contains('辞書B'));
      expect(msg, contains('辞書C'));
      // names are joined into a single summary string, not shown one-by-one
      expect(msg, contains('辞書A, 辞書B, 辞書C'));
    });
  });

  group('DictionaryImportException (BUG-082)', () {
    test('carries the underlying cause and memory flag', () {
      final cause = Exception('empty dictionary');
      final ex = DictionaryImportException(cause, isMemoryError: true);
      expect(ex.cause, same(cause));
      expect(ex.isMemoryError, isTrue);
      expect(ex.toString(), contains('empty dictionary'));
    });

    test('defaults isMemoryError to false', () {
      final ex = DictionaryImportException(Exception('x'));
      expect(ex.isMemoryError, isFalse);
    });
  });
}
