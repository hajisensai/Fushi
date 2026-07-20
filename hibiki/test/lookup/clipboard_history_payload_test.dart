import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/lookup/clipboard_history_payload.dart';
import 'package:hibiki/src/models/clipboard_history_repository.dart';

void main() {
  // U+2028 (line separator) / U+2029 (paragraph separator) built from code
  // points so THIS source stays pure ASCII (no raw separators to trip an
  // editor / formatter, and no ambiguity with real spaces).
  final String ls = String.fromCharCode(0x2028);
  final String ps = String.fromCharCode(0x2029);

  group('buildClipboardHistoryPayloadJson', () {
    ClipboardHistoryEntry entry(String text, DateTime at) =>
        ClipboardHistoryEntry(text: text, copiedAt: at);

    test('reverses entries to newest-first and carries labels', () {
      final DateTime now = DateTime(2026, 7, 19, 12, 0);
      final String jsonStr = buildClipboardHistoryPayloadJson(
        entries: <ClipboardHistoryEntry>[
          entry('old', DateTime(2026, 7, 19, 10, 0)),
          entry('new', DateTime(2026, 7, 19, 11, 30)),
        ],
        title: 'T',
        clearLabel: 'C',
        emptyLabel: 'E',
        now: now,
      );
      final Map<String, Object?> decoded =
          jsonDecode(jsonStr) as Map<String, Object?>;
      expect(decoded['title'], 'T');
      expect(decoded['clearLabel'], 'C');
      expect(decoded['emptyLabel'], 'E');
      final List<Object?> rows = decoded['entries'] as List<Object?>;
      expect(rows.length, 2);
      // tail(=newest) first: the memory List has newest at the end, so the
      // payload lists it first.
      expect((rows[0] as Map<String, Object?>)['text'], 'new');
      expect((rows[1] as Map<String, Object?>)['text'], 'old');
    });

    test('escapes arbitrary clipboard text safely (quotes / newlines)', () {
      final String jsonStr = buildClipboardHistoryPayloadJson(
        entries: <ClipboardHistoryEntry>[
          entry('a"b\nc\\d', DateTime(2026, 7, 19, 12, 0)),
        ],
        title: 'T',
        clearLabel: 'C',
        emptyLabel: 'E',
        now: DateTime(2026, 7, 19, 12, 0),
      );
      // Round-trips through JSON without corruption.
      final Map<String, Object?> decoded =
          jsonDecode(jsonStr) as Map<String, Object?>;
      final List<Object?> rows = decoded['entries'] as List<Object?>;
      expect((rows[0] as Map<String, Object?>)['text'], 'a"b\nc\\d');
    });

    test('escapes U+2028 / U+2029 into JS-safe backslash-u sequences', () {
      final String raw = 'line${ls}sep${ps}end';
      final String jsonStr = buildClipboardHistoryPayloadJson(
        entries: <ClipboardHistoryEntry>[
          entry(raw, DateTime(2026, 7, 19, 12, 0)),
        ],
        title: 'T',
        clearLabel: 'C',
        emptyLabel: 'E',
        now: DateTime(2026, 7, 19, 12, 0),
      );
      // The raw separators must NOT survive verbatim (they would break the
      // injected JS string literal); they become their \u escape sequences.
      expect(jsonStr.contains(ls), isFalse);
      expect(jsonStr.contains(ps), isFalse);
      expect(jsonStr.contains('\\u2028'), isTrue);
      expect(jsonStr.contains('\\u2029'), isTrue);
      // Still valid JSON after the escape (the \u sequences decode back).
      final Map<String, Object?> decoded =
          jsonDecode(jsonStr) as Map<String, Object?>;
      final List<Object?> rows = decoded['entries'] as List<Object?>;
      expect((rows[0] as Map<String, Object?>)['text'], raw);
    });
  });

  group('formatClipboardHistoryTime', () {
    test('same-day shows HH:mm only', () {
      final String s = formatClipboardHistoryTime(
        DateTime(2026, 7, 19, 9, 5),
        DateTime(2026, 7, 19, 12, 0),
      );
      expect(s, '09:05');
    });

    test('cross-day prefixes MM-DD', () {
      final String s = formatClipboardHistoryTime(
        DateTime(2026, 7, 18, 23, 5),
        DateTime(2026, 7, 19, 12, 0),
      );
      expect(s, '07-18 23:05');
    });
  });
}
