import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// TODO-1106 / BUG-532: a preference deliberately set to Dart `null` (e.g.
/// clearing a book-title override) must round-trip back to `null`, not the
/// four-character literal string `"null"`.
///
/// Before the `z:` tag, [PrefCodec.encode] fell through `'s:$value'` and turned
/// a null into the string `'s:null'`; on reload [PrefCodec.decodeUntyped]
/// returned the payload `'null'` (a real 4-char string), which surfaced as the
/// literal text "null" in the media edit UI. These tests lock the null
/// round-trip and guard that the fix does not regress non-null values or the
/// legacy untagged compatibility path.
void main() {
  group('PrefCodec null round-trip (BUG-532)', () {
    test('encode(null) emits the explicit z: tag, never s:null', () {
      expect(PrefCodec.encode(null), 'z:');
      expect(PrefCodec.encode(null), isNot(contains('null')));
    });

    test('decodeUntyped round-trips null back to Dart null', () {
      final String encoded = PrefCodec.encode(null);
      final dynamic decoded = PrefCodec.decodeUntyped(encoded);
      expect(decoded, isNull);
      // The regression symptom: it must NOT come back as the literal "null".
      expect(decoded, isNot('null'));
    });

    test('decode<String?> round-trips null override back to null', () {
      // Mirrors MediaSource.setOverrideTitleFromMediaItem clearing a title:
      // setPreference<String?>(value: null) -> encode(null) -> stored 'z:'.
      final String stored = PrefCodec.encode(null);
      final String? readBack = PrefCodec.decode<String?>(stored, null);
      expect(readBack, isNull);
      expect(readBack, isNot('null'));
    });

    test('a genuine user title "null" is still preserved as the string "null"',
        () {
      // The user is allowed to name a book literally "null"; that must NOT be
      // conflated with a cleared (Dart null) override.
      final String stored = PrefCodec.encode('null');
      expect(stored, 's:null');
      expect(PrefCodec.decodeUntyped(stored), 'null');
      expect(PrefCodec.decode<String?>(stored, null), 'null');
    });

    test('decode<String> (non-nullable) falls back to default on stored null',
        () {
      // Non-nullable contract must never receive a null; it gets the default.
      final String stored = PrefCodec.encode(null);
      expect(PrefCodec.decode<String>(stored, 'fallback'), 'fallback');
    });
  });

  group('PrefCodec non-null round-trips still hold', () {
    test('bool', () {
      expect(PrefCodec.decode<bool>(PrefCodec.encode(true), false), true);
      expect(PrefCodec.decode<bool>(PrefCodec.encode(false), true), false);
      expect(PrefCodec.decodeUntyped(PrefCodec.encode(true)), true);
    });

    test('int', () {
      expect(PrefCodec.decode<int>(PrefCodec.encode(42), 0), 42);
      expect(PrefCodec.decodeUntyped(PrefCodec.encode(7)), 7);
    });

    test('double', () {
      expect(PrefCodec.decode<double>(PrefCodec.encode(3.5), 0.0), 3.5);
      expect(PrefCodec.decodeUntyped(PrefCodec.encode(1.25)), 1.25);
    });

    test('string', () {
      expect(PrefCodec.decode<String>(PrefCodec.encode('hi'), ''), 'hi');
      expect(PrefCodec.decodeUntyped(PrefCodec.encode('hi')), 'hi');
    });

    test('List<String>', () {
      final List<String> src = <String>['a', 'b'];
      expect(
        PrefCodec.decode<List<String>>(PrefCodec.encode(src), <String>[]),
        <String>['a', 'b'],
      );
      expect(
          PrefCodec.decodeUntyped(PrefCodec.encode(src)), <String>['a', 'b']);
    });
  });

  group('PrefCodec legacy untagged compatibility path', () {
    test('untagged legacy values still decode via heuristic', () {
      expect(PrefCodec.decode<int>('123', 0), 123);
      expect(PrefCodec.decode<bool>('true', false), true);
      expect(PrefCodec.decode<String>('plain', ''), 'plain');
      expect(PrefCodec.decodeUntyped('true'), true);
      expect(PrefCodec.decodeUntyped('456'), 456);
      expect(PrefCodec.decodeUntyped('hello'), 'hello');
    });

    test('legacy s:null (written before the fix) still reads as literal string',
        () {
      // Backward compatibility: pre-fix databases may hold 's:null'. We do not
      // migrate them here; they decode to the string 'null' exactly as before,
      // so behaviour for existing rows is unchanged (no data corruption). New
      // writes use 'z:' and never produce this again.
      expect(PrefCodec.decodeUntyped('s:null'), 'null');
    });

    test('unknown tag falls through to heuristic, not swallowed as null', () {
      // 'q:' is not a known tag; must be treated as untagged legacy raw.
      expect(PrefCodec.decodeUntyped('q:whatever'), 'q:whatever');
      expect(PrefCodec.decode<String>('q:whatever', ''), 'q:whatever');
    });
  });
}
