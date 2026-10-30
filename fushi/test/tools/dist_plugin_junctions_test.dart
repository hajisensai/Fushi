// Contract: on a Windows dist_test worker, worker_build.sh links the Windows
// plugins with junctions (tool/dist_test/plugin_junctions.dart) before
// `flutter build windows`: on wight-win no native program could follow the
// directory symlinks the Flutter tool makes, and CMake found no plugin.
// See docs/specs/2026-10-24-distributed-unit-tests.md.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// cmd's view of [path]: what CMake, a native program, would see.
Future<bool> _cmdSees(String path) async {
  final ProcessResult r = await Process.run('cmd.exe', <String>[
    '/c',
    // Unquoted: Dart escapes inner quotes as \" for CreateProcess, which cmd
    // does not undo. The temp paths here have no spaces.
    'if exist $path (exit 0) else (exit 1)',
  ]);
  return r.exitCode == 0;
}

/// cmd's `dir /AL` lines for the links in [dir].
Future<String> _links(String dir) async {
  final ProcessResult r = await Process.run('cmd.exe', <String>[
    '/c',
    'dir',
    '/AL',
    dir,
  ]);
  return '${r.stdout}';
}

/// plugin_junctions.dart as worker_build.sh runs it. runInShell: the SDK's
/// dart on PATH may be dart.bat, which CreateProcess cannot start.
Future<ProcessResult> _junctions(String app) => Process.run('dart', <String>[
  'tool/dist_test/plugin_junctions.dart',
  app,
], runInShell: true);

void main() {
  late Directory root;
  late String app;
  late String links;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dist_plugin_junctions_');
    app = '${root.path}\\app';
    links = '$app\\windows\\flutter\\ephemeral\\.plugin_symlinks';
    for (final String p in <String>['alpha', 'beta']) {
      Directory('${root.path}\\cache\\$p\\windows').createSync(recursive: true);
    }
    Directory(links).createSync(recursive: true);
    File('$app\\.flutter-plugins-dependencies').writeAsStringSync(
      jsonEncode(<String, Object?>{
        'plugins': <String, Object?>{
          'windows': <Object?>[
            for (final String p in <String>['alpha', 'beta'])
              <String, Object?>{
                'name': p,
                // As pub writes it: a trailing separator.
                'path': '${root.path}\\cache\\$p\\',
                'native_build': true,
                'dependencies': <Object?>[],
              },
          ],
        },
      }),
    );
  });

  tearDown(() async {
    // Links first, with rmdir: a recursive delete must never reach through
    // one into what it points to.
    if (Directory(links).existsSync()) {
      for (final FileSystemEntity e in Directory(
        links,
      ).listSync(followLinks: false)) {
        await Process.run('cmd.exe', <String>['/c', 'rmdir', e.path]);
      }
    }
    root.deleteSync(recursive: true);
  });

  test(
    'links every Windows plugin with a junction, replacing a stale link',
    () async {
      // A link an earlier pub get left, pointing at a directory that must
      // survive its removal.
      Directory('${root.path}\\stale\\windows').createSync(recursive: true);
      File('${root.path}\\stale\\keep').writeAsStringSync('keep');
      final ProcessResult mk = await Process.run('cmd.exe', <String>[
        '/c',
        'mklink',
        '/J',
        '$links\\alpha',
        '${root.path}\\stale',
      ]);
      expect(mk.exitCode, 0, reason: '${mk.stdout}${mk.stderr}');

      final ProcessResult r = await _junctions(app);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');

      final String dir = await _links(links);
      expect(RegExp('<JUNCTION>').allMatches(dir).length, 2, reason: dir);
      expect(dir, contains('${root.path}\\cache\\alpha]'));
      expect(dir, isNot(contains('stale')));
      for (final String p in <String>['alpha', 'beta']) {
        expect(await _cmdSees('$links\\$p\\windows'), isTrue, reason: p);
      }
      expect(File('${root.path}\\stale\\keep').readAsStringSync(), 'keep');
    },
    skip: Platform.isWindows ? false : 'junctions are Windows only',
  );

  test('refuses a plugin name that is not a plain identifier', () async {
    File('$app\\.flutter-plugins-dependencies').writeAsStringSync(
      jsonEncode(<String, Object?>{
        'plugins': <String, Object?>{
          'windows': <Object?>[
            <String, Object?>{
              'name': r'..\escape',
              'path': '${root.path}\\cache\\alpha\\',
            },
          ],
        },
      }),
    );
    final ProcessResult r = await _junctions(app);
    expect(r.exitCode, 1);
    expect('${r.stderr}', contains('bad plugin name'));
    expect(Directory(links).listSync(), isEmpty);
  }, skip: Platform.isWindows ? false : 'junctions are Windows only');
}
