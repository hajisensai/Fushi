// BUG-4387: the Flatpak pins GDK_BACKEND=x11, and on some machines Fushi's X11
// drawing crashes right after the first frame while Wayland works. The Flatpak
// entry point (tool/linux/flatpak/fushi_launcher.sh) falls back to Wayland
// then. These tests run the REAL launcher with bash against a stub app binary
// that records how it was started and crashes / exits on demand.
@TestOn('linux')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const String _stub = r'''#!/bin/bash
echo "$GDK_BACKEND $*" >> "$STUB_LOG"
mode_var="STUB_ON_$GDK_BACKEND"
case "${!mode_var:-ok}" in
  crash) ulimit -c 0; kill -SEGV $$ ;;
  term) kill -TERM $$ ;;
  wait)
    trap 'echo "got TERM" >> "$STUB_LOG"; exit 0' TERM
    echo ready >> "$STUB_LOG"
    while :; do sleep 0.1; done ;;
esac
exit 0
''';

class _Fixture {
  _Fixture._(this.root);

  final Directory root;

  String get launcher => p.join(
    Directory.current.parent.path,
    'tool',
    'linux',
    'flatpak',
    'fushi_launcher.sh',
  );
  File get log => File(p.join(root.path, 'stub.log'));
  File get state => File(p.join(root.path, 'config', 'fushi', 'x11-fallback'));
  File get info => File(p.join(root.path, 'flatpak-info'));

  static Future<_Fixture> create() async {
    final _Fixture fx = _Fixture._(
      await Directory.systemTemp.createTemp('fushi_launcher_'),
    );
    final File stub = File(p.join(fx.root.path, 'fushi'));
    await stub.writeAsString(_stub);
    await Process.run('chmod', <String>['+x', stub.path]);
    await fx.setCommit('aaa111');
    return fx;
  }

  Future<void> setCommit(String commit) => info.writeAsString(
    '[Application]\nname=app.fushi.reader\n\n'
    '[Instance]\napp-commit=$commit\n',
  );

  Map<String, String> env({
    String? gdkBackend = 'x11',
    String? waylandDisplay = 'wayland-0',
    Map<String, String> extra = const <String, String>{},
  }) => <String, String>{
    'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
    'HOME': root.path,
    'XDG_CONFIG_HOME': p.join(root.path, 'config'),
    'FUSHI_LAUNCHER_BINARY': p.join(root.path, 'fushi'),
    'FUSHI_LAUNCHER_FLATPAK_INFO': info.path,
    'STUB_LOG': log.path,
    if (gdkBackend != null) 'GDK_BACKEND': gdkBackend,
    if (waylandDisplay != null) 'WAYLAND_DISPLAY': waylandDisplay,
    ...extra,
  };

  Future<ProcessResult> launch(
    Map<String, String> environment, [
    List<String> args = const <String>['book.epub', '--flag'],
  ]) => Process.run(
    'bash',
    <String>[launcher, ...args],
    environment: environment,
    includeParentEnvironment: false,
  );

  Future<List<String>> runs() async => log.existsSync()
      ? (await log.readAsLines()).where((String l) => l.isNotEmpty).toList()
      : <String>[];

  Future<void> dispose() => root.delete(recursive: true);
}

void main() {
  late _Fixture fx;

  setUp(() async => fx = await _Fixture.create());
  tearDown(() => fx.dispose());

  test(
    'an X11 crash at start relaunches the same command on Wayland',
    () async {
      final ProcessResult r = await fx.launch(
        fx.env(extra: <String, String>{'STUB_ON_x11': 'crash'}),
      );
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      expect(await fx.runs(), <String>[
        'x11 book.epub --flag',
        'wayland book.epub --flag',
      ]);
      expect(fx.state.readAsStringSync().trim(), 'app-commit=aaa111');
      expect(r.stderr, contains('starting again on Wayland'));
    },
  );

  test('the same build then starts straight on Wayland', () async {
    await fx.launch(fx.env(extra: <String, String>{'STUB_ON_x11': 'crash'}));
    await fx.log.delete();

    final ProcessResult r = await fx.launch(fx.env(), <String>[]);
    expect(r.exitCode, 0);
    expect(await fx.runs(), <String>['wayland ']);
  });

  test('a new build tries X11 again and drops the old record', () async {
    await fx.launch(fx.env(extra: <String, String>{'STUB_ON_x11': 'crash'}));
    await fx.log.delete();
    await fx.setCommit('bbb222');

    final ProcessResult r = await fx.launch(fx.env(), <String>[]);
    expect(r.exitCode, 0);
    expect(await fx.runs(), <String>['x11 ']);
    expect(fx.state.existsSync(), isFalse);
  });

  test('a crash on Wayland too is not blamed on X11', () async {
    final ProcessResult r = await fx.launch(
      fx.env(
        extra: <String, String>{
          'STUB_ON_x11': 'crash',
          'STUB_ON_wayland': 'crash',
        },
      ),
    );
    expect(r.exitCode, 139);
    expect((await fx.runs()).length, 2);
    expect(fx.state.existsSync(), isFalse);
  });

  test('being terminated is not a crash: no fallback', () async {
    final ProcessResult r = await fx.launch(
      fx.env(extra: <String, String>{'STUB_ON_x11': 'term'}),
    );
    expect(r.exitCode, 143);
    expect(await fx.runs(), <String>['x11 book.epub --flag']);
    expect(fx.state.existsSync(), isFalse);
  });

  group('left alone (a single run, as started)', () {
    Future<void> expectSingleRun(
      Map<String, String> environment,
      String expectedBackend,
    ) async {
      final ProcessResult r = await fx.launch(environment);
      // -SIGSEGV, not 139: the launcher exec'd the app, so the process Dart
      // started is the one that crashed (no supervising shell in between).
      expect(r.exitCode, -11);
      expect(await fx.runs(), <String>['$expectedBackend book.epub --flag']);
      expect(fx.state.existsSync(), isFalse);
    }

    test('a user override of GDK_BACKEND', () async {
      await expectSingleRun(
        fx.env(
          gdkBackend: 'wayland',
          extra: <String, String>{'STUB_ON_wayland': 'crash'},
        ),
        'wayland',
      );
    });

    test('no Wayland display to fall back to', () async {
      await expectSingleRun(
        fx.env(
          waylandDisplay: null,
          extra: <String, String>{'STUB_ON_x11': 'crash'},
        ),
        'x11',
      );
    });

    test('Steam Deck Game Mode (must stay on X11)', () async {
      await expectSingleRun(
        fx.env(
          extra: <String, String>{
            'STUB_ON_x11': 'crash',
            'GAMESCOPE_WAYLAND_DISPLAY': 'gamescope-0',
          },
        ),
        'x11',
      );
    });
  });

  test('SIGTERM to the launcher reaches the app', () async {
    final Process launcher = await Process.start(
      'bash',
      <String>[fx.launcher],
      environment: fx.env(extra: <String, String>{'STUB_ON_x11': 'wait'}),
      includeParentEnvironment: false,
    );
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!(await fx.runs()).contains('ready')) {
      if (DateTime.now().isAfter(deadline)) fail('stub never started');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    launcher.kill(ProcessSignal.sigterm);
    final int code = await launcher.exitCode.timeout(
      const Duration(seconds: 10),
    );
    expect(await fx.runs(), contains('got TERM'));
    expect(code, 0);
    expect(fx.state.existsSync(), isFalse);
  });

  test('the Flatpak runs the launcher as `fushi` and ships it', () {
    final String flatpakDir = p.join(
      Directory.current.parent.path,
      'tool',
      'linux',
      'flatpak',
    );
    final String manifest = File(
      p.join(flatpakDir, 'app.fushi.reader.yml'),
    ).readAsStringSync();
    expect(manifest, contains('command: fushi\n'));
    expect(
      manifest,
      contains('install -Dm755 fushi_launcher.sh /app/bin/fushi'),
    );
    expect(manifest, contains('path: fushi_launcher.sh'));
    expect(manifest, isNot(contains('ln -s /app/fushi/fushi /app/bin/fushi')));
    // The fallback only touches the manifest's exact default.
    expect(manifest, contains('- --env=GDK_BACKEND=x11'));
    final String build = File(
      p.join(flatpakDir, 'flatpak_build.sh'),
    ).readAsStringSync();
    expect(build, contains(r'"$HERE/fushi_launcher.sh" "$work/"'));
    expect(build, contains(r'path: fushi_launcher\.sh$'));
  });
}
