import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

void main() {
  group('PrefCodec.encode', () {
    test('encodes bool with b: prefix', () {
      expect(PrefCodec.encode(true), 'b:true');
      expect(PrefCodec.encode(false), 'b:false');
    });

    test('encodes int with i: prefix', () {
      expect(PrefCodec.encode(42), 'i:42');
      expect(PrefCodec.encode(-1), 'i:-1');
      expect(PrefCodec.encode(0), 'i:0');
    });

    test('encodes double with d: prefix', () {
      expect(PrefCodec.encode(3.14), 'd:3.14');
      expect(PrefCodec.encode(1.0), 'd:1.0');
    });

    test('encodes string with s: prefix', () {
      expect(PrefCodec.encode('hello'), 's:hello');
      expect(PrefCodec.encode(''), 's:');
      expect(PrefCodec.encode('123'), 's:123');
      expect(PrefCodec.encode('true'), 's:true');
    });

    test('encodes list with j: prefix', () {
      expect(PrefCodec.encode(['a', 'b']), 'j:["a","b"]');
      expect(PrefCodec.encode(<String>[]), 'j:[]');
    });
  });

  group('PrefCodec.decode (tagged)', () {
    test('decodes tagged bool', () {
      expect(PrefCodec.decode<bool>('b:true', false), true);
      expect(PrefCodec.decode<bool>('b:false', true), false);
    });

    test('decodes tagged int', () {
      expect(PrefCodec.decode<int>('i:42', 0), 42);
      expect(PrefCodec.decode<int>('i:-1', 0), -1);
    });

    test('decodes tagged double', () {
      expect(PrefCodec.decode<double>('d:3.14', 0.0), 3.14);
      expect(PrefCodec.decode<double>('d:1.0', 0.0), 1.0);
    });

    test('decodes tagged string', () {
      expect(PrefCodec.decode<String>('s:hello', ''), 'hello');
      expect(PrefCodec.decode<String>('s:123', ''), '123');
      expect(PrefCodec.decode<String>('s:true', ''), 'true');
    });

    test('decodes tagged list', () {
      expect(
        PrefCodec.decode<List<String>>('j:["a","b"]', <String>[]),
        ['a', 'b'],
      );
    });

    test('string "123" stays string when tagged', () {
      final dynamic result = PrefCodec.decode<String>('s:123', '');
      expect(result, '123');
      expect(result is String, true);
    });

    test('string "true" stays string when tagged', () {
      final dynamic result = PrefCodec.decode<String>('s:true', '');
      expect(result, 'true');
      expect(result is String, true);
    });
  });

  group('PrefCodec.decode (legacy heuristic)', () {
    test('parses legacy int via defaultValue type hint', () {
      expect(PrefCodec.decode<int>('42', 0), 42);
    });

    test('parses legacy double via defaultValue type hint', () {
      expect(PrefCodec.decode<double>('3.14', 0.0), 3.14);
    });

    test('parses legacy bool via defaultValue type hint', () {
      expect(PrefCodec.decode<bool>('true', false), true);
      expect(PrefCodec.decode<bool>('false', true), false);
    });

    test('returns raw string for unrecognized legacy value', () {
      expect(PrefCodec.decode<String>('hello', ''), 'hello');
    });
  });

  group('PrefCodec.decodeUntyped', () {
    test('decodes tagged values', () {
      expect(PrefCodec.decodeUntyped('b:true'), true);
      expect(PrefCodec.decodeUntyped('i:42'), 42);
      expect(PrefCodec.decodeUntyped('d:3.14'), 3.14);
      expect(PrefCodec.decodeUntyped('s:hello'), 'hello');
    });

    test('falls back to heuristic for untagged values', () {
      expect(PrefCodec.decodeUntyped('true'), true);
      expect(PrefCodec.decodeUntyped('false'), false);
      expect(PrefCodec.decodeUntyped('42'), 42);
      expect(PrefCodec.decodeUntyped('3.14'), 3.14);
      expect(PrefCodec.decodeUntyped('hello'), 'hello');
    });

    test('tagged string "123" stays string', () {
      final dynamic result = PrefCodec.decodeUntyped('s:123');
      expect(result, '123');
      expect(result is String, true);
    });
  });

  group('round-trip', () {
    test('bool round-trips correctly', () {
      expect(PrefCodec.decode<bool>(PrefCodec.encode(true), false), true);
      expect(PrefCodec.decode<bool>(PrefCodec.encode(false), true), false);
    });

    test('int round-trips correctly', () {
      expect(PrefCodec.decode<int>(PrefCodec.encode(42), 0), 42);
    });

    test('double round-trips correctly', () {
      expect(PrefCodec.decode<double>(PrefCodec.encode(1.0), 0.0), 1.0);
    });

    test('string round-trips correctly', () {
      expect(PrefCodec.decode<String>(PrefCodec.encode('ja'), ''), 'ja');
    });

    test('string that looks like int round-trips as string', () {
      final String encoded = PrefCodec.encode('123');
      expect(PrefCodec.decode<String>(encoded, ''), '123');
      expect(PrefCodec.decodeUntyped(encoded) is String, true);
    });
  });
}
