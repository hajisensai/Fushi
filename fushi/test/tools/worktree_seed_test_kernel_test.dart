// Contract for fushi/tool/worktree_seed/test_kernel_seed.dart: the flutter
// test compile seed may only hold libraries that live outside every worktree,
// is keyed on everything that changes its meaning, and is copied (never
// linked) in only when the worktree has no compile cache of its own.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../tool/worktree_seed/test_kernel_seed.dart';

File _write(String path, String text) {
  final File f = File(path);
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(text);
  return f;
}

void main() {
  late Directory tmp;
  late String repo;
  late String pubCache;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('kernel_seed_');
    repo = p.join(tmp.path, 'repo');
    pubCache = p.join(tmp.path, 'pub');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  SeedPackage pkg(String name, String root) =>
      SeedPackage(name: name, root: root, libDir: p.join(root, 'lib'));

  test('readPackageConfig resolves relative and file: roots', () {
    final String cfg = p.join(repo, '.dart_tool', 'package_config.json');
    _write(
      cfg,
      jsonEncode(<String, Object?>{
        'configVersion': 2,
        'packages': <Object?>[
          <String, Object?>{
            'name': 'fushi',
            'rootUri': '../fushi',
            'packageUri': 'lib/',
          },
          <String, Object?>{
            'name': 'path',
            'rootUri': Uri.directory(p.join(pubCache, 'path-1.0.0')).toString(),
            'packageUri': 'lib/',
          },
        ],
        'flutterRoot': Uri.directory(p.join(tmp.path, 'flutter')).toString(),
      }),
    );
    final List<SeedPackage> pkgs = readPackageConfig(cfg);
    expect(pkgs.map((SeedPackage s) => s.name), <String>['fushi', 'path']);
    expect(p.equals(pkgs[0].root, p.join(repo, 'fushi')), isTrue);
    expect(
      p.equals(pkgs[1].libDir, p.join(pubCache, 'path-1.0.0', 'lib')),
      isTrue,
    );
    expect(
      p.equals(readFlutterRoot(cfg)!, p.join(tmp.path, 'flutter')),
      isTrue,
    );
  });

  test('pubspecDependencies reads only the dependencies section', () {
    const String pubspec = '''
name: marquee
dependencies:
  flutter:
    sdk: flutter
  fading_edge_scrollview: ^4.0.0
dev_dependencies:
  test: any
''';
    expect(pubspecDependencies(pubspec), <String>{
      'flutter',
      'fading_edge_scrollview',
    });
  });

  test('packages inside the repo, and their dependents, are not seedable', () {
    final List<SeedPackage> pkgs = <SeedPackage>[
      pkg('fushi', p.join(repo, 'fushi')),
      pkg('fading_edge_scrollview', p.join(repo, 'third_party', 'fes')),
      pkg('marquee', p.join(pubCache, 'marquee')),
      pkg('ticker_user', p.join(pubCache, 'ticker_user')),
      pkg('path', p.join(pubCache, 'path')),
    ];
    final Map<String, String> pubspecs = <String, String>{
      p.join(pubCache, 'marquee'):
          'dependencies:\n  fading_edge_scrollview: any\n',
      p.join(pubCache, 'ticker_user'): 'dependencies:\n  marquee: any\n',
      p.join(pubCache, 'path'): 'dependencies:\n  meta: any\n',
    };
    final Map<String, SeedPackage> seedable = seedablePackages(
      pkgs,
      repo,
      readPubspec: (String root) => pubspecs[root],
    );
    expect(seedable.keys, <String>['path']);
  });

  test('scanSeedLibraries keeps existing third-party imports only', () {
    final String pathPkg = p.join(pubCache, 'path');
    _write(p.join(pathPkg, 'lib', 'path.dart'), '');
    _write(p.join(pathPkg, 'lib', 'web.dart'), '');
    final Map<String, SeedPackage> seedable = <String, SeedPackage>{
      'path': pkg('path', pathPkg),
    };
    final String lib = p.join(repo, 'fushi', 'lib');
    _write(p.join(lib, 'a.dart'), '''
import 'package:path/path.dart' as p;
import 'package:path/missing.dart';
import 'package:fushi/src/x.dart';
import 'package:path/web.dart' if (dart.library.io) 'package:path/path.dart';
export "package:path/path.dart";
''');
    _write(p.join(lib, 'b_web.dart'), "import 'package:path/web.dart';\n");
    _write(
      p.join(lib, 'c.dart'),
      "import 'dart:js_interop';\nimport 'package:path/web.dart';\n",
    );
    expect(scanSeedLibraries(<String>[lib], seedable), <String>[
      'package:path/path.dart',
    ]);
  });

  test('renderSeedEntry imports every library and declares one test', () {
    final String entry = renderSeedEntry(<String>[
      'package:a/a.dart',
      'package:b/b.dart',
    ]);
    expect(entry, contains("import 'package:a/a.dart' as i0;"));
    expect(entry, contains("import 'package:b/b.dart' as i1;"));
    expect(entry, contains("import 'package:flutter_test/flutter_test.dart'"));
    expect(entry, isNot(contains('package:fushi/')));
    expect(RegExp(r'seed\.test\(').allMatches(entry).length, 1);
  });

  test('seedKey changes with every input', () {
    const SeedKeyInputs base = SeedKeyInputs(
      flutterRoot: 'D:/flutter',
      frameworkRevision: 'f',
      engineRevision: 'e',
      dartSdkVersion: '3.13.5',
      lockSha256: 'l',
      appVersion: '3.4.0+1369',
    );
    final String k = seedKey(base);
    expect(k, matches(RegExp(r'^[0-9a-f]{16}$')));
    expect(seedKey(base), k);
    final List<SeedKeyInputs> variants = <SeedKeyInputs>[
      const SeedKeyInputs(
        flutterRoot: 'E:/flutter',
        frameworkRevision: 'f',
        engineRevision: 'e',
        dartSdkVersion: '3.13.5',
        lockSha256: 'l',
        appVersion: '3.4.0+1369',
      ),
      const SeedKeyInputs(
        flutterRoot: 'D:/flutter',
        frameworkRevision: 'g',
        engineRevision: 'e',
        dartSdkVersion: '3.13.5',
        lockSha256: 'l',
        appVersion: '3.4.0+1369',
      ),
      const SeedKeyInputs(
        flutterRoot: 'D:/flutter',
        frameworkRevision: 'f',
        engineRevision: 'x',
        dartSdkVersion: '3.13.5',
        lockSha256: 'l',
        appVersion: '3.4.0+1369',
      ),
      const SeedKeyInputs(
        flutterRoot: 'D:/flutter',
        frameworkRevision: 'f',
        engineRevision: 'e',
        dartSdkVersion: '3.14.0',
        lockSha256: 'l',
        appVersion: '3.4.0+1369',
      ),
      const SeedKeyInputs(
        flutterRoot: 'D:/flutter',
        frameworkRevision: 'f',
        engineRevision: 'e',
        dartSdkVersion: '3.13.5',
        lockSha256: 'm',
        appVersion: '3.4.0+1369',
      ),
      const SeedKeyInputs(
        flutterRoot: 'D:/flutter',
        frameworkRevision: 'f',
        engineRevision: 'e',
        dartSdkVersion: '3.13.5',
        lockSha256: 'l',
        appVersion: '3.4.0+1370',
      ),
    ];
    for (final SeedKeyInputs v in variants) {
      expect(seedKey(v), isNot(k));
    }
  });

  test('readSeedKeyInputs reports what is missing', () {
    final List<String> why = <String>[];
    expect(readSeedKeyInputs(repo, why), isNull);
    expect(why.single, contains('package_config.json'));
  });

  group('cache', () {
    late String cacheDir;
    late String keyDir;
    late String testCache;
    const String name = 'abc.cache.dill.track.dill';

    setUp(() {
      cacheDir = p.join(tmp.path, 'cache', 'test-seed');
      keyDir = p.join(cacheDir, 'k1');
      testCache = p.join(repo, 'fushi', kTestCacheRel);
    });

    test('restore copies the seed into an empty compile cache', () {
      _write(p.join(keyDir, name), 'seed');
      expect(restoreSeed(keyDir, testCache), <String>[name]);
      final File copied = File(p.join(testCache, name));
      expect(copied.readAsStringSync(), 'seed');
      // A copy, not a link: flutter test rewrites it in place.
      copied.writeAsStringSync('rewritten by flutter test');
      expect(File(p.join(keyDir, name)).readAsStringSync(), 'seed');
      expect(
        Directory(testCache).listSync().map((FileSystemEntity e) => e.path),
        everyElement(isNot(contains('.seeding'))),
      );
    });

    test('restore never replaces a worktree compile cache', () {
      _write(p.join(keyDir, name), 'seed');
      _write(p.join(testCache, 'own.cache.dill.track.dill'), 'own');
      expect(restoreSeed(keyDir, testCache), isEmpty);
      expect(File(p.join(testCache, name)).existsSync(), isFalse);
    });

    test('restore ignores empty files and a missing key', () {
      _write(p.join(keyDir, name), '');
      expect(restoreSeed(keyDir, testCache), isEmpty);
      expect(restoreSeed(p.join(cacheDir, 'none'), testCache), isEmpty);
    });

    test('store keeps only the newest keys', () {
      for (int i = 0; i < 3; i++) {
        final String k = p.join(cacheDir, 'old$i');
        _write(p.join(k, name), 'x');
        _write(
          p.join(k, 'stored'),
          'x',
        ).setLastModifiedSync(DateTime.now().subtract(Duration(days: 10 - i)));
      }
      _write(p.join(testCache, name), 'fresh');
      expect(storeSeed(testCache, keyDir, keep: 2), <String>[name]);
      expect(File(p.join(keyDir, name)).readAsStringSync(), 'fresh');
      final List<String> left =
          Directory(cacheDir)
              .listSync()
              .whereType<Directory>()
              .map((Directory d) => p.basename(d.path))
              .toList()
            ..sort();
      expect(left, <String>['k1', 'old2']);
    });

    test('lock: second taker waits, stale lock is taken over', () {
      expect(takeSeedLock(keyDir), isTrue);
      expect(takeSeedLock(keyDir), isFalse);
      expect(
        takeSeedLock(keyDir, now: DateTime.now().add(const Duration(hours: 1))),
        isTrue,
      );
      releaseSeedLock(keyDir);
      expect(File('$keyDir.lock').existsSync(), isFalse);
      expect(takeSeedLock(keyDir), isTrue);
      releaseSeedLock(keyDir);
    });
  });

  test('worktreePathsInDill flags worktree libraries but not the entry', () {
    final String prefix = Uri.directory(repo).toString();
    final String dill = p.join(tmp.path, 'x.cache.dill.track.dill');
    File(dill).writeAsBytesSync(
      latin1.encode(
        '\x00${prefix}fushi/build/test_seed/seed_test.dart\x00'
        '$prefix.dart_tool/package_config.json\x00'
        'file:///C:/pub/cache/path/lib/path.dart\x00',
      ),
    );
    expect(worktreePathsInDill(dill, repo), isEmpty);
    File(dill).writeAsBytesSync(
      latin1.encode(
        '\x00${prefix}third_party/fes/lib/fes.dart\x00'
        '${prefix}fushi/lib/main.dart"',
      ),
      mode: FileMode.append,
    );
    expect(worktreePathsInDill(dill, repo), <String>[
      'fushi/lib/main.dart',
      'third_party/fes/lib/fes.dart',
    ]);
  });
}
