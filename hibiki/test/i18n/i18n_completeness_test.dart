import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('i18n completeness', () {
    late Map<String, dynamic> baseStrings;
    late List<File> translationFiles;
    late String i18nDir;

    setUpAll(() {
      i18nDir = p.join(
        Directory.current.path,
        'lib',
        'i18n',
      );
      final baseFile = File(p.join(i18nDir, 'strings.i18n.json'));
      if (!baseFile.existsSync()) {
        fail('Base i18n file not found at ${baseFile.path}');
      }
      baseStrings =
          jsonDecode(baseFile.readAsStringSync()) as Map<String, dynamic>;

      translationFiles =
          Directory(i18nDir).listSync().whereType<File>().where((f) {
        final name = p.basename(f.path);
        return name.endsWith('.i18n.json') && name != 'strings.i18n.json';
      }).toList();
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

    test('base file keys are all strings (not null)', () {
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

    test('translations cover at least 50% of base top-level keys', () {
      final baseKeys = baseStrings.keys.toSet();

      for (final file in translationFiles) {
        final name = p.basename(file.path);
        final translation =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        final translationKeys = translation.keys.toSet();
        final covered = baseKeys.intersection(translationKeys).length;
        final coverage = covered / baseKeys.length;

        expect(coverage, greaterThan(0.5),
            reason:
                '$name has only ${(coverage * 100).toStringAsFixed(0)}% coverage');
      }
    });
  });
}
