// Contract of tool/dist_test/worker_cache.sh: what worker_prepare.sh makes is
// kept per content key, so two runs taking turns on one worker checkout batch
// by batch (worker_slot.sh `yield`) do not rebuild each other's native
// libraries on every turn. The script runs for real (bash) on a throwaway git
// checkout, with a fake build that counts how often it runs.

import 'dart:io';

import 'package:test/test.dart';

const String _cacheScript = 'tool/dist_test/worker_cache.sh';
const String _crate = 'fushi_demo';
const String _plat = 'macos';
final String _keyA = 'a' * 40;
final String _keyB = '${'b' * 40}+raw_sql';
final String _keyC = 'c' * 40;
final String _keyD = 'd' * 40;

/// Git Bash on Windows (never the WSL `bash.exe` System32 may put first),
/// `bash` elsewhere.
String _bash() {
  if (!Platform.isWindows) return 'bash';
  final String exec =
      '${Process.runSync('git', <String>['--exec-path']).stdout}'.trim();
  final String root = File(exec).parent.parent.parent.path;
  return '$root/bin/bash.exe';
}

void main() {
  late Directory home;
  late String bash;
  late String script;
  late String checkout;
  late String state;
  late File builds;

  /// A git checkout with the dist state directory, as a worker slot has.
  String makeCheckout(String name) {
    final String dir = '${home.path.replaceAll(r'\', '/')}/$name';
    Directory(dir).createSync();
    final ProcessResult init = Process.runSync('git', <String>[
      'init',
      '-q',
      dir,
    ]);
    expect(init.exitCode, 0, reason: '${init.stderr}');
    Directory('$dir/.git/fushi-dist').createSync(recursive: true);
    return dir;
  }

  setUp(() {
    bash = _bash();
    script = File(_cacheScript).absolute.path.replaceAll(r'\', '/');
    home = Directory.systemTemp.createTempSync('dist_cache_');
    checkout = makeCheckout('work');
    state = '.git/fushi-dist';
    builds = File('${home.path}/builds');
  });

  tearDown(() => home.deleteSync(recursive: true));

  /// The fake build: one line in [builds] per run, then the library set
  /// (one file holding the key it was built for) in prebuilt/<plat>.
  List<String> build(String key) => <String>[
    'bash',
    '-c',
    r'echo "$2" >> "$1" && mkdir -p "native/$3/prebuilt/$4" && '
        r'echo "$2" > "native/$3/prebuilt/$4/lib"',
    'build',
    builds.path.replaceAll(r'\', '/'),
    key,
    _crate,
    _plat,
  ];

  ProcessResult native(String key, {String peer = '', String? dir}) =>
      Process.runSync(bash, <String>[
        script,
        'native',
        state,
        _crate,
        key,
        _plat,
        peer,
        ...build(key),
      ], workingDirectory: dir ?? checkout);

  List<String> built() =>
      builds.existsSync() ? builds.readAsLinesSync() : <String>[];
  String inPlace([String? dir]) => File(
    '${dir ?? checkout}/native/$_crate/prebuilt/$_plat/lib',
  ).readAsStringSync().trim();
  String pointer() => File(
    '$checkout/.git/fushi-dist/native-$_crate.key',
  ).readAsStringSync().trim();

  void ok(ProcessResult r) =>
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');

  test('runs taking turns A, B, A build each key once', () {
    ok(native(_keyA));
    ok(native(_keyB));
    expect(inPlace(), _keyB);
    final ProcessResult back = native(_keyA);
    ok(back);
    expect(built(), <String>[_keyA, _keyB]);
    expect(inPlace(), _keyA);
    expect(pointer(), _keyA);
    expect('${back.stdout}', contains("from this checkout's cache"));
    ok(native(_keyB));
    expect(built(), <String>[_keyA, _keyB]);
    expect(inPlace(), _keyB);
  });

  test('the same key again leaves the library set alone', () {
    ok(native(_keyA));
    final ProcessResult again = native(_keyA);
    ok(again);
    expect(built(), <String>[_keyA]);
    expect('${again.stdout}', contains('unchanged'));
  });

  test('a set prepared before the cache existed is kept under its key', () {
    // A worker prepared by the single-stamp worker_prepare.sh: the library
    // set and its stamp, nothing cached.
    Directory(
      '$checkout/native/$_crate/prebuilt/$_plat',
    ).createSync(recursive: true);
    File(
      '$checkout/native/$_crate/prebuilt/$_plat/lib',
    ).writeAsStringSync(_keyA);
    File(
      '$checkout/.git/fushi-dist/native-$_crate.key',
    ).writeAsStringSync('$_keyA\n');
    ok(native(_keyA));
    ok(native(_keyB));
    ok(native(_keyA));
    expect(built(), <String>[_keyB]);
    expect(inPlace(), _keyA);
  });

  test('only the most recently used keys are kept', () {
    ok(native(_keyA));
    ok(native(_keyB));
    ok(native(_keyC));
    ok(native(_keyA)); // A used again: B is now the least recently used
    ok(native(_keyD));
    expect(built(), <String>[_keyA, _keyB, _keyC, _keyD]);
    final List<String> kept =
        Directory('$checkout/.git/fushi-dist/native/$_crate')
            .listSync()
            .map(
              (FileSystemEntity e) =>
                  e.uri.pathSegments.lastWhere((String s) => s.isNotEmpty),
            )
            .toList()
          ..sort();
    expect(kept, <String>[_keyA, _keyC, _keyD]);
    ok(native(_keyB));
    expect(built(), <String>[_keyA, _keyB, _keyC, _keyD, _keyB]);
  });

  test('a secondary slot copies the peer slot\'s set instead of building', () {
    final String peer = makeCheckout('peer');
    ok(native(_keyA, dir: peer));
    ok(native(_keyB, dir: peer)); // A now only in the peer's cache
    expect(built(), <String>[_keyA, _keyB]);
    final ProcessResult r = native(_keyA, peer: peer);
    ok(r);
    expect('${r.stdout}', contains('copy native/$_crate'));
    ok(native(_keyB, peer: peer));
    expect(built(), <String>[_keyA, _keyB]);
    expect(inPlace(), _keyB);
    // Seeded sets are kept here too: back to A needs no peer.
    ok(native(_keyA));
    expect(inPlace(), _keyA);
    expect(built(), <String>[_keyA, _keyB]);
  });

  test('a failed build leaves no pointer and nothing cached', () {
    ok(native(_keyA));
    final ProcessResult r = Process.runSync(bash, <String>[
      script,
      'native',
      state,
      _crate,
      _keyB,
      _plat,
      '',
      'bash',
      '-c',
      'exit 7',
    ], workingDirectory: checkout);
    expect(r.exitCode, 7);
    expect(
      File('$checkout/.git/fushi-dist/native-$_crate.key').existsSync(),
      isFalse,
    );
    expect(
      Directory('$checkout/.git/fushi-dist/native/$_crate/$_keyB').existsSync(),
      isFalse,
    );
    // A is still cached and comes back without a build.
    ok(native(_keyA));
    expect(built(), <String>[_keyA]);
  });

  test('native-restore says whether this checkout has the key', () {
    ProcessResult restore(String key) => Process.runSync(bash, <String>[
      script,
      'native-restore',
      state,
      _crate,
      key,
      _plat,
    ], workingDirectory: checkout);
    expect(restore(_keyA).exitCode, 1);
    ok(native(_keyA));
    ok(native(_keyB));
    ok(restore(_keyA));
    expect(inPlace(), _keyA);
    expect(pointer(), _keyA);
  });

  test('the dependency warm-up runs once per key, A, B, A', () {
    final File runs = File('${home.path}/warm');
    ProcessResult warm(String key) => Process.runSync(bash, <String>[
      script,
      'warm',
      state,
      key,
      'bash',
      '-c',
      r'echo "$2" >> "$1"',
      'warm',
      runs.path.replaceAll(r'\', '/'),
      key,
    ], workingDirectory: checkout);
    ok(warm(_keyA));
    ok(warm(_keyB));
    final ProcessResult back = warm(_keyA);
    ok(back);
    expect('${back.stdout}', contains('already warm'));
    expect(runs.readAsLinesSync(), <String>[_keyA, _keyB]);
  });

  test('a failed warm-up is not remembered', () {
    ProcessResult warm(String command) => Process.runSync(bash, <String>[
      script,
      'warm',
      state,
      _keyA,
      'bash',
      '-c',
      command,
    ], workingDirectory: checkout);
    expect(warm('exit 3').exitCode, 3);
    final ProcessResult again = warm('echo ran');
    ok(again);
    expect('${again.stdout}', contains('ran'));
  });

  test('keys and names are checked before anything is touched', () {
    for (final List<String> args in <List<String>>[
      <String>['native', state, _crate, '../x', _plat, '', 'true'],
      <String>['native', state, '../x', _keyA, _plat, '', 'true'],
      <String>['native', state, _crate, _keyA, 'a/b', '', 'true'],
      <String>['warm', state, 'nothex', 'true'],
      <String>['nope'],
    ]) {
      final ProcessResult r = Process.runSync(bash, <String>[
        script,
        ...args,
      ], workingDirectory: checkout);
      expect(r.exitCode, 2, reason: args.join(' '));
    }
    expect(Directory('$checkout/native').existsSync(), isFalse);
  });
}
