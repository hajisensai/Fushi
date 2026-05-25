import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Set<String> _flattenKeys(Map<String, dynamic> map, [String prefix = '']) {
  final keys = <String>{};
  for (final entry in map.entries) {
    final full = prefix.isEmpty ? entry.key : '$prefix.${entry.key}';
    if (entry.value is Map) {
      keys.addAll(_flattenKeys(entry.value as Map<String, dynamic>, full));
    } else {
      keys.add(full);
    }
  }
  return keys;
}

final _interpolationRe = RegExp(r'\$\{?\w+\}?');

Set<String> _extractInterpolations(String value) =>
    _interpolationRe.allMatches(value).map((m) => m.group(0)!).toSet();

dynamic _resolve(Map<String, dynamic> map, String dottedKey) {
  dynamic current = map;
  for (final segment in dottedKey.split('.')) {
    if (current is! Map<String, dynamic> || !current.containsKey(segment)) {
      return null;
    }
    current = current[segment];
  }
  return current;
}

void main() {
  group('i18n completeness', () {
    late Map<String, dynamic> baseStrings;
    late Set<String> baseKeys;
    late List<File> translationFiles;
    late String i18nDir;

    setUpAll(() {
      i18nDir = p.join(Directory.current.path, 'lib', 'i18n');
      final baseFile = File(p.join(i18nDir, 'strings.i18n.json'));
      if (!baseFile.existsSync()) {
        fail('Base i18n file not found at ${baseFile.path}');
      }
      baseStrings =
          jsonDecode(baseFile.readAsStringSync()) as Map<String, dynamic>;
      baseKeys = _flattenKeys(baseStrings);

      translationFiles =
          Directory(i18nDir).listSync().whereType<File>().where((f) {
        final name = p.basename(f.path);
        return name.endsWith('.i18n.json') && name != 'strings.i18n.json';
      }).toList()
            ..sort((a, b) => a.path.compareTo(b.path));
    });

    test('base strings file exists and is non-empty', () {
      expect(baseStrings, isNotEmpty);
    });

    test('at least one translation file exists', () {
      expect(translationFiles, isNotEmpty,
          reason: 'Expected at least one translation besides the base');
    });

    test('all translation files are valid JSON', () {
      for (final file in translationFiles) {
        expect(
          () => jsonDecode(file.readAsStringSync()),
          returnsNormally,
          reason: '${p.basename(file.path)} should be valid JSON',
        );
      }
    });

    test('base file leaf values are all strings', () {
      void checkKeys(Map<String, dynamic> map, String prefix) {
        for (final entry in map.entries) {
          if (entry.value is Map) {
            checkKeys(
              entry.value as Map<String, dynamic>,
              '$prefix.${entry.key}',
            );
          } else {
            expect(entry.value, isA<String>(),
                reason: 'Key $prefix.${entry.key} should be a string');
          }
        }
      }

      checkKeys(baseStrings, 'root');
    });

    test('every translation covers 100% of base keys', () {
      for (final file in translationFiles) {
        final name = p.basename(file.path);
        final translation =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        final translationKeys = _flattenKeys(translation);
        final missing = baseKeys.difference(translationKeys);

        expect(missing, isEmpty,
            reason: '$name is missing ${missing.length} key(s): '
                '${missing.take(10).join(", ")}'
                '${missing.length > 10 ? "..." : ""}');
      }
    });

    test('no translations have orphaned keys absent from base', () {
      for (final file in translationFiles) {
        final name = p.basename(file.path);
        final translation =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        final translationKeys = _flattenKeys(translation);
        final extra = translationKeys.difference(baseKeys);

        expect(extra, isEmpty,
            reason: '$name has ${extra.length} orphaned key(s): '
                '${extra.take(10).join(", ")}');
      }
    });

    test('interpolation variables match between base and translations', () {
      for (final file in translationFiles) {
        final name = p.basename(file.path);
        final translation =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

        for (final key in baseKeys) {
          final baseValue = _resolve(baseStrings, key);
          final transValue = _resolve(translation, key);
          if (baseValue is! String || transValue is! String) continue;

          final baseVars = _extractInterpolations(baseValue);
          final transVars = _extractInterpolations(transValue);
          if (baseVars.isEmpty) continue;

          final missingVars = baseVars.difference(transVars);
          expect(missingVars, isEmpty,
              reason:
                  '$name key "$key" is missing interpolation(s): $missingVars');
        }
      }
    });
  });
}
