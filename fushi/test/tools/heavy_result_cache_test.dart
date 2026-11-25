// tool/test_flow/heavy_result_cache.dart: green test / analyze results
// remembered by content, answered without queueing.

import 'dart:io';

import 'package:test/test.dart';

import '../../tool/test_flow/heavy_budget.dart';
import '../../tool/test_flow/heavy_result_cache.dart';

bool _cacheable(
  List<String> argv, {
  HeavyKind kind = HeavyKind.test,
  List<String> own = const <String>[],
  Map<String, String> env = const <String, String>{},
  String? skip,
}) => heavyResultCacheable(
  kind: kind,
  argv: argv,
  own: own,
  environment: env,
  leaseSkipReason: skip,
);

HeavyCachedResult _result(DateTime at) => HeavyCachedResult(
  at: at,
  label: 'flutter test test/a_test.dart',
  ranS: 42,
  where: 'here',
  checkout: 'D:/wt/a',
  tail: '00:12 +7: All tests passed!',
);

Future<String> _git(Directory repo, List<String> args) async {
  final ProcessResult r = await Process.run('git', <String>[
    '-C',
    repo.path,
    ...args,
  ]);
  expect(r.exitCode, 0, reason: '${r.stderr}');
  return (r.stdout as String).trim();
}

void main() {
  group('heavyResultCacheable', () {
    test('test and analyze runs are cacheable', () {
      expect(_cacheable(<String>['flutter', 'test', 'a_test.dart']), isTrue);
      expect(
        _cacheable(<String>['flutter', 'analyze'], kind: HeavyKind.analyze),
        isTrue,
      );
    });

    test('builds and other commands are not', () {
      expect(
        _cacheable(<String>['flutter', 'build', 'apk'], kind: HeavyKind.build),
        isFalse,
      );
      expect(_cacheable(<String>['x'], kind: HeavyKind.other), isFalse);
    });

    test('runs that write files the caller wants are not', () {
      expect(_cacheable(<String>['flutter', 'test', '--coverage']), isFalse);
      expect(
        _cacheable(<String>['flutter', 'test', '--update-goldens']),
        isFalse,
      );
      expect(
        _cacheable(<String>['flutter', 'test', '--coverage=out']),
        isFalse,
      );
    });

    test(
      'runs whose report the caller reads from a file or as JSON are not',
      () {
        // A hit only repeats a text tail: the json file would be missing / stale
        // and stdout would not be JSON.
        for (final List<String> extra in <List<String>>[
          <String>['--file-reporter', 'json:out.json'],
          <String>['--file-reporter=json:out.json'],
          <String>['-r', 'json'],
          <String>['--reporter', 'json'],
          <String>['--reporter=json'],
          <String>['-rjson'],
          <String>['--machine'],
        ]) {
          expect(
            _cacheable(<String>['flutter', 'test', ...extra, 'a_test.dart']),
            isFalse,
            reason: extra.join(' '),
          );
        }
        expect(
          _cacheable(<String>['flutter', 'test', '-r', 'expanded']),
          isTrue,
        );
        expect(
          _cacheable(<String>[
            'flutter',
            'analyze',
            '--write=issues.txt',
          ], kind: HeavyKind.analyze),
          isFalse,
        );
      },
    );

    test(
      'runs a project variable tells to write vectors / previews are not',
      () {
        final List<String> argv = <String>['flutter', 'test', 'a_test.dart'];
        for (final String name in <String>[
          'SRS_STUDY_VECTORS_WRITE',
          'FUSHI_SRS_PREVIEW_OUT',
          'FUSHI_PREVIEW',
          'FUSHI_DESIGN_PREVIEW_OUT',
          'FUSHI_SRS_HTML_SHOTS_OUT',
          'FUSHI_VECTORS_OUT',
        ]) {
          expect(
            _cacheable(argv, env: <String, String>{name: '1'}),
            isFalse,
            reason: name,
          );
        }
        // Switched off explicitly / an unrelated variable: still cacheable.
        expect(
          _cacheable(
            argv,
            env: <String, String>{'SRS_STUDY_VECTORS_WRITE': '0'},
          ),
          isTrue,
        );
        expect(
          _cacheable(argv, env: <String, String>{'OTHER_OUT': '1'}),
          isTrue,
        );
      },
    );

    test('--no-cache, FUSHI_HEAVY_CACHE=off, CI, FUSHI_HEAVY=off opt out', () {
      final List<String> argv = <String>['flutter', 'test'];
      expect(_cacheable(argv, own: <String>['--no-cache']), isFalse);
      expect(
        _cacheable(argv, env: <String, String>{'FUSHI_HEAVY_CACHE': 'OFF'}),
        isFalse,
      );
      expect(_cacheable(argv, skip: 'CI'), isFalse);
      expect(_cacheable(argv, skip: 'FUSHI_HEAVY=off'), isFalse);
    });
  });

  group('heavyResultKey', () {
    test('differs by tree, argv and directory; stable otherwise', () {
      String key({
        String tree = 'aaa',
        List<String> argv = const <String>['flutter', 'test'],
        String cwd = 'fushi',
      }) => heavyResultKey(tree: tree, argv: argv, cwdInCheckout: cwd);

      expect(key(), key());
      expect(key(tree: 'bbb'), isNot(key()));
      expect(
        key(argv: <String>['flutter', 'test', 'x_test.dart']),
        isNot(key()),
      );
      expect(key(cwd: 'packages/fushi_core'), isNot(key()));
    });

    test(
      'a variable that gates tests splits the key; tooling knobs do not',
      () {
        String key(Map<String, String> env) => heavyResultKey(
          tree: 'aaa',
          argv: const <String>['flutter', 'test'],
          cwdInCheckout: 'fushi',
          environment: env,
        );

        final String bare = key(const <String, String>{});
        // A green run with the ffmpeg / real-DB / id_audit tests skipped says
        // nothing about a run that turns them on.
        for (final String gate in <String>[
          'FUSHI_TEST_FFMPEG',
          'FUSHI_SRS_REAL_DB',
          'FUSHI_FSRS_ID_AUDIT',
          'FUSHI_FLUTTER',
        ]) {
          expect(key(<String, String>{gate: '1'}), isNot(bare), reason: gate);
        }
        expect(
          key(<String, String>{'FUSHI_TEST_FFMPEG': 'a'}),
          isNot(key(<String, String>{'FUSHI_TEST_FFMPEG': 'b'})),
        );
        // How heavy / dist / bug tooling runs, and non-project variables, do
        // not change the conclusion.
        expect(
          key(<String, String>{
            'FUSHI_HEAVY_OFFLOAD': 'off',
            'FUSHI_HEAVY_SLOTS': '3',
            'FUSHI_DIST_CONFIG': 'x.json',
            'FUSHI_BUG_BASE': 'origin/develop',
            'PATH': '/bin',
            'TEMP': 'C:/t',
          }),
          bare,
        );
        // Order-independent.
        expect(
          key(<String, String>{'FUSHI_A': '1', 'SRS_B': '2'}),
          key(<String, String>{'SRS_B': '2', 'FUSHI_A': '1'}),
        );
      },
    );
  });

  group('heavyCwdInCheckout', () {
    test('relative path inside, null outside', () {
      expect(heavyCwdInCheckout('/r/wt', '/r/wt'), '');
      expect(heavyCwdInCheckout('/r/wt/fushi', '/r/wt'), 'fushi');
      expect(heavyCwdInCheckout('/r/wt/fushi/', '/r/wt/'), 'fushi');
      expect(heavyCwdInCheckout('/r/wtx/fushi', '/r/wt'), isNull);
      expect(heavyCwdInCheckout('/elsewhere', '/r/wt'), isNull);
    });

    test('Windows separators', () {
      expect(heavyCwdInCheckout(r'D:\r\wt\fushi', 'D:/r/wt'), 'fushi');
    }, testOn: 'windows');
  });

  group('result files', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('heavy_result_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('a written result is read back', () {
      final DateTime now = DateTime.utc(2026, 11, 22, 12);
      writeHeavyResult(dir, 'k1', _result(now), now: now);
      final HeavyCachedResult? r = readHeavyResult(
        dir,
        'k1',
        now: now.add(const Duration(minutes: 5)),
      );
      expect(r, isNotNull);
      expect(r!.ranS, 42);
      expect(r.tail, contains('All tests passed'));
      final String said = r.describe(now.add(const Duration(minutes: 5)));
      expect(said, contains('CACHED PASS'));
      expect(said, contains('5 min ago'));
      expect(said, contains('--no-cache'));
    });

    test('unknown key and expired result read as null', () {
      final DateTime now = DateTime.utc(2026, 11, 22, 12);
      expect(readHeavyResult(dir, 'nope', now: now), isNull);
      writeHeavyResult(dir, 'k2', _result(now), now: now);
      expect(
        readHeavyResult(
          dir,
          'k2',
          now: now.add(kHeavyResultTtl + const Duration(minutes: 1)),
        ),
        isNull,
      );
    });

    test('a corrupt file reads as null', () {
      Directory('${dir.path}/$kHeavyResultDir').createSync(recursive: true);
      File('${dir.path}/$kHeavyResultDir/bad.json').writeAsStringSync('{x');
      expect(readHeavyResult(dir, 'bad', now: DateTime.now()), isNull);
    });
  });

  test('HeavyOutputTail keeps the last lines without ANSI codes', () {
    final HeavyOutputTail t = HeavyOutputTail();
    for (int i = 0; i < 40; i++) {
      t.add('line $i\n'.codeUnits);
    }
    t.add('\x1B[32m00:03 +40: All tests passed!\x1B[0m\n'.codeUnits);
    final List<String> lines = t.text.split('\n');
    expect(lines.length, kHeavyResultTailLines);
    expect(lines.last, '00:03 +40: All tests passed!');
  });

  group('heavyWorkingTree', () {
    late Directory repo;
    late Directory scratch;

    setUp(() async {
      repo = Directory.systemTemp.createTempSync('heavy_tree_repo_');
      scratch = Directory.systemTemp.createTempSync('heavy_tree_scratch_');
      await _git(repo, <String>['init', '-q']);
      await _git(repo, <String>['config', 'user.email', 't@example.com']);
      await _git(repo, <String>['config', 'user.name', 't']);
      File('${repo.path}/.gitignore').writeAsStringSync('build/\n');
      File('${repo.path}/a.dart').writeAsStringSync('a');
      await _git(repo, <String>['add', '-A']);
      await _git(repo, <String>['commit', '-qm', 'init']);
    });
    tearDown(() {
      repo.deleteSync(recursive: true);
      scratch.deleteSync(recursive: true);
    });

    test('follows edits and untracked files, ignores ignored ones, '
        'leaves the index alone', () async {
      final String? clean = await heavyWorkingTree(repo.path, scratch: scratch);
      expect(clean, await _git(repo, <String>['rev-parse', 'HEAD^{tree}']));

      Directory('${repo.path}/build').createSync();
      File('${repo.path}/build/out.bin').writeAsStringSync('x');
      expect(await heavyWorkingTree(repo.path, scratch: scratch), clean);

      File('${repo.path}/a.dart').writeAsStringSync('b');
      final String? edited = await heavyWorkingTree(
        repo.path,
        scratch: scratch,
      );
      expect(edited, isNot(clean));

      File('${repo.path}/new.dart').writeAsStringSync('n');
      final String? untracked = await heavyWorkingTree(
        repo.path,
        scratch: scratch,
      );
      expect(untracked, isNot(edited));

      // The real index still has nothing staged.
      expect(await _git(repo, <String>['diff', '--cached', '--name-only']), '');
      expect(scratch.listSync(), isEmpty);
    });

    // A same-size edit landing in the same second as the commit that wrote the
    // index is only caught by git's racy-entry check, which compares entries
    // with the index file's mtime. Pinned here with explicit timestamps (and
    // ctime out of the picture), so it does not depend on scheduling: the copy
    // the tree is computed from must keep the index's mtime.
    test('sees a same-size edit within the index\'s own second', () async {
      await _git(repo, <String>['config', 'core.trustctime', 'false']);
      final DateTime second = DateTime.fromMillisecondsSinceEpoch(
        (DateTime.now().millisecondsSinceEpoch ~/ 1000 - 100) * 1000,
      );
      final File a = File('${repo.path}/a.dart');
      final File index = File('${repo.path}/.git/index');
      a.setLastModifiedSync(second);
      await _git(repo, <String>['add', '-A']);
      await _git(repo, <String>['commit', '-qm', 'stamp', '--allow-empty']);
      index.setLastModifiedSync(second);
      final String? clean = await heavyWorkingTree(repo.path, scratch: scratch);
      expect(clean, await _git(repo, <String>['rev-parse', 'HEAD^{tree}']));

      a.writeAsStringSync('b');
      a.setLastModifiedSync(second);
      index.setLastModifiedSync(second);
      expect(await heavyWorkingTree(repo.path, scratch: scratch), isNot(clean));
    });

    test('null outside a repository', () async {
      final Directory plain = Directory.systemTemp.createTempSync('heavy_np_');
      try {
        expect(await heavyWorkingTree(plain.path, scratch: scratch), isNull);
      } finally {
        plain.deleteSync(recursive: true);
      }
    });
  });
}
