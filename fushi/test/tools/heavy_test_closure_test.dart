import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/test_flow/heavy_test_closure.dart';

/// heavy.dart 按测试的 import 闭包预定内存（heavy_budget.dart testBookMb）；
/// 这里钉住闭包怎么数：跨包、相对路径、part、缓存只记工作区外的文件。
void main() {
  group('testTargetsOf', () {
    test('files only; flag values and line suffixes are not targets', () {
      expect(
        testTargetsOf(<String>[
          'flutter',
          'test',
          '--concurrency=4',
          '--plain-name',
          'x.dart',
          'test/a_test.dart',
          'test/b_test.dart:12',
          'test/c_test.dart?line=3',
          '--no-pub',
        ]),
        <String>['test/a_test.dart', 'test/b_test.dart', 'test/c_test.dart'],
      );
    });

    test('directories or no targets: null (book the ceiling)', () {
      expect(testTargetsOf(<String>['flutter', 'test']), isNull);
      expect(testTargetsOf(<String>['flutter', 'test', 'test/models']), isNull);
      expect(testTargetsOf(<String>['flutter', 'analyze']), isNull);
    });
  });

  group('testClosureFiles', () {
    late Directory root;
    late Directory external;

    void write(String path, String content) {
      File(path)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(content);
    }

    setUp(() {
      root = Directory.systemTemp.createTempSync('heavy_closure_ws_');
      external = Directory.systemTemp.createTempSync('heavy_closure_ext_');
      final String r = root.path.replaceAll(r'\', '/');
      final String e = external.path.replaceAll(r'\', '/');
      write(
        '$r/.dart_tool/package_config.json',
        jsonEncode(<String, Object>{
          'configVersion': 2,
          'packages': <Map<String, String>>[
            <String, String>{
              'name': 'app',
              'rootUri': '../app',
              'packageUri': 'lib/',
            },
            <String, String>{
              'name': 'ext',
              'rootUri': Uri.directory(e).toString(),
              'packageUri': 'lib/',
            },
          ],
        }),
      );
      write('$r/app/test/a_test.dart', "import 'package:app/a.dart';\n");
      write('$r/app/test/b_test.dart', "import 'package:ext/ext.dart';\n");
      write(
        '$r/app/lib/a.dart',
        "import 'dart:io';\nimport 'b.dart';\npart 'a_part.dart';\n"
            "import 'package:ext/ext.dart';\n",
      );
      write('$r/app/lib/a_part.dart', "part of 'a.dart';\n");
      write('$r/app/lib/b.dart', "export 'package:app/a.dart';\n");
      write('$e/lib/ext.dart', "import 'src/inner.dart';\n");
      write('$e/lib/src/inner.dart', 'class Inner {}\n');
    });

    tearDown(() {
      root.deleteSync(recursive: true);
      external.deleteSync(recursive: true);
    });

    test('follows package, relative, part and export edges; skips dart:', () {
      final String app = '${root.path}/app';
      // a_test, a, a_part, b, ext, inner
      expect(testClosureFiles(app, <String>['test/a_test.dart']), 6);
      // b_test, ext, inner
      expect(testClosureFiles(app, <String>['test/b_test.dart']), 3);
      // union
      expect(
        testClosureFiles(app, <String>['test/a_test.dart', 'test/b_test.dart']),
        7,
      );
    });

    test('a missing target: null', () {
      expect(
        testClosureFiles('${root.path}/app', <String>['test/nope_test.dart']),
        isNull,
      );
    });

    test('edge cache keeps files outside the workspace only', () {
      final File cache = File('${root.path}/cache/edges.json');
      final String app = '${root.path}/app';
      expect(
        testClosureFiles(app, <String>['test/a_test.dart'], edgeCache: cache),
        6,
      );
      final Map<String, Object?> json =
          jsonDecode(cache.readAsStringSync()) as Map<String, Object?>;
      final String ws = root.path.replaceAll(r'\', '/');
      expect(json.keys, isNotEmpty);
      expect(json.keys.where((String k) => k.startsWith(ws)), isEmpty);
      // Cached external edges answer without reading the file again.
      File('${external.path}/lib/ext.dart').writeAsStringSync('');
      expect(
        testClosureFiles(app, <String>['test/a_test.dart'], edgeCache: cache),
        6,
      );
      // Workspace files are always read fresh.
      File('$app/lib/b.dart').writeAsStringSync('');
      File('$app/lib/a.dart').writeAsStringSync("import 'b.dart';\n");
      expect(
        testClosureFiles(app, <String>['test/a_test.dart'], edgeCache: cache),
        3,
      );
    });
  });
}
