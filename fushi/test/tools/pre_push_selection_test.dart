import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/test_flow/pre_push_selection.dart';

void main() {
  group('parseEnumerationGuards', () {
    test('reads only the "### 清单" table, up to the next heading', () {
      const String md = '''
intro | `test/not_this_test.dart` |
### 清单（51 条）

| 测试 | 扫描根 | 守什么 |
|---|---|---|
| `test/a/one_test.dart` | lib | x |
| `test/b/two_test.dart` | test | y |
| `test/a/one_test.dart` | dup | z |

## 另一半
| `test/c/later_test.dart` | nope |
''';
      expect(parseEnumerationGuards(md),
          <String>['test/a/one_test.dart', 'test/b/two_test.dart']);
    });

    test('the real fast-workflow.md still parses to the ~50-entry batch', () {
      final String md =
          File('../docs/agent/fast-workflow.md').readAsStringSync();
      final List<String> guards = parseEnumerationGuards(md);
      expect(guards.length, greaterThanOrEqualTo(40));
      for (final String g in guards) {
        expect(File(g).existsSync(), isTrue, reason: '$g listed but missing');
      }
    });
  });

  group('importKeysForChange', () {
    const Map<String, String> names = <String, String>{
      'fushi_core': 'fushi_core'
    };

    test('app and package libraries map to their package: URI', () {
      expect(importKeysForChange('fushi/lib/src/a/b.dart', packageNames: names),
          <String>{'package:fushi/src/a/b.dart'});
      expect(
          importKeysForChange('packages/fushi_core/lib/src/db.dart',
              packageNames: names),
          <String>{'package:fushi_core/src/db.dart'});
      expect(importKeysForChange('native/x.cpp', packageNames: names), isEmpty);
    });

    test('a part maps to the library that owns it', () {
      expect(
          importKeysForChange(
              'fushi/lib/src/pages/implementations/reader_fushi/chrome.part.dart',
              packageNames: names,
              partOwner: '../reader_fushi_page.dart'),
          <String>{
            'package:fushi/src/pages/implementations/reader_fushi_page.dart'
          });
    });

    test('partOfTarget reads the part-of URI', () {
      expect(partOfTarget("// x\npart of '../owner.dart';\n"), '../owner.dart');
      expect(partOfTarget("library x;\nimport 'a.dart';\n"), isNull);
    });
  });

  group('directImpactTests', () {
    final Map<String, String> sources = <String, String>{
      'fushi/test/a/imports_b_test.dart': "import 'package:fushi/src/b.dart';",
      'fushi/test/a/unrelated_test.dart': "import 'package:fushi/src/z.dart';",
      'fushi/test/a/uses_helper_test.dart': "import '../helpers/fake_x.dart';",
      'fushi/test/c/widget_test.dart': '',
      'fushi/test/d/b_test.dart': '',
    };

    test('importers, changed tests, helper users and same-name tests', () {
      final Set<String> out = directImpactTests(
        changed: <String>[
          'fushi/lib/src/b.dart',
          'fushi/test/c/widget_test.dart',
          'fushi/test/helpers/fake_x.dart',
        ],
        testSources: sources,
        importKeys: <String>{'package:fushi/src/b.dart'},
      );
      expect(out, <String>{
        'fushi/test/a/imports_b_test.dart',
        'fushi/test/c/widget_test.dart',
        'fushi/test/a/uses_helper_test.dart',
        'fushi/test/d/b_test.dart',
      });
    });

    test('a deleted test file is not selected', () {
      expect(
          directImpactTests(
            changed: <String>['fushi/test/gone_test.dart'],
            testSources: sources,
            importKeys: <String>{},
          ),
          isEmpty);
    });
  });

  test('changedTestablePackages mirrors the CI package-loop skip list', () {
    expect(
        changedTestablePackages(<String>[
          'packages/fushi_core/lib/a.dart',
          'packages/fushi_torrent/lib/b.dart',
          'packages/gamepads_windows/c.cc',
          'fushi/lib/x.dart',
        ]),
        <String>{'fushi_core'});
  });

  test('touchesJsSuites', () {
    expect(touchesJsSuites(<String>['fushi/lib/a.dart']), isFalse);
    expect(touchesJsSuites(<String>['fushi/assets/popup/popup.js']), isTrue);
    expect(touchesJsSuites(<String>['tools/browser-extension/content.js']),
        isTrue);
  });

  test('chunkByCommandLength keeps every path, each batch under the limit', () {
    final List<String> paths = <String>[
      for (int i = 0; i < 300; i++) 'test/some/dir/file_number_${i}_test.dart'
    ];
    final List<List<String>> batches =
        chunkByCommandLength(paths, maxChars: 1000);
    expect(batches.expand((List<String> b) => b).toList(), paths);
    for (final List<String> b in batches) {
      expect(b.join(' ').length, lessThanOrEqualTo(1000));
    }
  });

  group('budgetTrigger (default selection)', () {
    bool isDir(String p) => !p.endsWith('.dart');
    int files(String p) => p == 'native/small' ? 12 : 900;

    bool hit(String changed, String ref) => budgetTrigger(changed, ref,
        isDirectory: isDir, dirFileCount: files, maxDirFiles: 60);

    test('exact file reference triggers', () {
      expect(hit('fushi/lib/src/a.dart', 'fushi/lib/src/a.dart'), isTrue);
    });

    test('a sibling in the same directory does NOT trigger (wide mode only)',
        () {
      expect(hit('fushi/lib/src/b.dart', 'fushi/lib/src/a.dart'), isFalse);
    });

    test('a small directory reference triggers, a large one does not', () {
      expect(hit('native/small/x.cpp', 'native/small'), isTrue);
      expect(hit('fushi/lib/src/pages/p.dart', 'fushi/lib/src'), isFalse);
      expect(hit('native/smallish/x.cpp', 'native/small'), isFalse);
    });
  });

  test('splitHubImportKeys keeps rare imports and drops hubs', () {
    final Map<String, String> sources = <String, String>{
      for (int i = 0; i < 50; i++)
        't$i': "import 'package:fushi/hub.dart';"
            "${i == 0 ? "import 'package:fushi/rare.dart';" : ''}",
    };
    final ({Set<String> kept, Set<String> hubs}) r = splitHubImportKeys(
        <String>{'package:fushi/hub.dart', 'package:fushi/rare.dart'}, sources,
        hubLimit: 40);
    expect(r.kept, <String>{'package:fushi/rare.dart'});
    expect(r.hubs, <String>{'package:fushi/hub.dart'});
  });
}
