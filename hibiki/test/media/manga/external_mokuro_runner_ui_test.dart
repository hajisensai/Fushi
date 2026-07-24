import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/manga/external_mokuro_runner.dart';
import 'package:path/path.dart' as p;

/// 可编程 fake 子进程运行器：不真 spawn，按注入的脚本回放。
class _FakeRunner implements MokuroProcessRunner {
  _FakeRunner({
    this.onRunToCompletion,
    this.startLines = const <String>[],
    this.startExitCode = 0,
  });

  final Future<MokuroProcessResult> Function(String exe, List<String> args)?
      onRunToCompletion;
  final List<String> startLines;
  final int startExitCode;
  final bool throwOnStart = false;

  final List<List<String>> completionCalls = <List<String>>[];
  final List<String> completionExecutables = <String>[];
  bool killed = false;

  @override
  Future<MokuroProcessResult> runToCompletion(
    String executable,
    List<String> args, {
    Duration? timeout,
  }) async {
    completionExecutables.add(executable);
    completionCalls.add(args);
    if (onRunToCompletion != null) {
      return onRunToCompletion!(executable, args);
    }
    return const MokuroProcessResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<MokuroProcessHandle> start(
      String executable, List<String> args) async {
    if (throwOnStart) {
      throw const ProcessException('mokuro', <String>[], 'boom', 2);
    }
    final StreamController<String> controller = StreamController<String>();
    final Completer<int> exit = Completer<int>();
    scheduleMicrotask(() async {
      for (final String line in startLines) {
        if (!controller.isClosed) controller.add(line);
      }
      await controller.close();
      if (!exit.isCompleted) exit.complete(startExitCode);
    });
    return MokuroProcessHandle(
      lines: controller.stream,
      exitCode: exit.future,
      kill: () => killed = true,
    );
  }
}

void main() {
  group('parseProgressLine', () {
    test('parses tqdm N/M', () {
      final MokuroRunEvent? e = ExternalMokuroRunner.parseProgressLine(
          '  50%|█████     | 5/10 [00:03<00:03, 1.5it/s]');
      expect(e, isNotNull);
      expect(e!.done, 5);
      expect(e.total, 10);
      expect(e.finished, isFalse);
      expect(e.isRunning, isFalse);
    });

    test('returns null when no N/M present', () {
      expect(
          ExternalMokuroRunner.parseProgressLine('Loading model...'), isNull);
    });

    test('rejects done > total', () {
      expect(ExternalMokuroRunner.parseProgressLine('12/10'), isNull);
    });
  });

  group('resolveExecutable precedence', () {
    test('configured path wins over env and which', () async {
      final _FakeRunner runner = _FakeRunner();
      final ExternalMokuroRunner ext = ExternalMokuroRunner(
        configuredPath: '/opt/mokuro',
        processRunner: runner,
        environment: const <String, String>{'HIBIKI_MOKURO': '/env/mokuro'},
      );
      expect(await ext.resolveExecutable(), '/opt/mokuro');
      // 命中配置路径时不该去跑 where/which。
      expect(runner.completionCalls, isEmpty);
    });

    test('env used when no configured path', () async {
      final _FakeRunner runner = _FakeRunner();
      final ExternalMokuroRunner ext = ExternalMokuroRunner(
        processRunner: runner,
        environment: const <String, String>{'HIBIKI_MOKURO': '/env/mokuro'},
      );
      expect(await ext.resolveExecutable(), '/env/mokuro');
      expect(runner.completionCalls, isEmpty);
    });

    test('falls back to which/where on PATH', () async {
      final _FakeRunner runner = _FakeRunner(
        onRunToCompletion: (String exe, List<String> args) async =>
            const MokuroProcessResult(
          exitCode: 0,
          stdout: '/usr/local/bin/mokuro\n',
          stderr: '',
        ),
      );
      final ExternalMokuroRunner ext = ExternalMokuroRunner(
        processRunner: runner,
        environment: const <String, String>{},
      );
      expect(await ext.resolveExecutable(), '/usr/local/bin/mokuro');
      expect(runner.completionCalls.single, <String>['mokuro']);
    });
  });

  group('probe', () {
    test('returns first non-empty line of --version output', () async {
      final _FakeRunner runner = _FakeRunner(
        onRunToCompletion: (String exe, List<String> args) async =>
            const MokuroProcessResult(
          exitCode: 0,
          stdout: 'mokuro 0.2.1\n',
          stderr: '',
        ),
      );
      final ExternalMokuroRunner ext = ExternalMokuroRunner(
        configuredPath: 'mokuro',
        processRunner: runner,
      );
      expect(await ext.probe(), 'mokuro 0.2.1');
    });

    test('returns null on non-zero exit', () async {
      final _FakeRunner runner = _FakeRunner(
        onRunToCompletion: (String exe, List<String> args) async =>
            const MokuroProcessResult(exitCode: 1, stdout: '', stderr: 'nope'),
      );
      final ExternalMokuroRunner ext = ExternalMokuroRunner(
        configuredPath: 'mokuro',
        processRunner: runner,
      );
      expect(await ext.probe(), isNull);
    });
  });

  group('run', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('mokuro_run');
    });
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('emits running + progress then finished with located .mokuro',
        () async {
      // mokuro 惯例：<卷名>.mokuro 落在图片目录同级（此处即 tmp 内的同名文件）。
      final Directory imageDir = Directory(p.join(tmp.path, 'vol1'))
        ..createSync();
      File(p.join(imageDir.path, 'p001.jpg')).writeAsBytesSync(<int>[1]);
      final String mokuroPath = p.join(tmp.path, 'vol1.mokuro');
      File(mokuroPath).writeAsStringSync('{}');

      final _FakeRunner runner = _FakeRunner(
        startLines: <String>['Processing', '1/2', '2/2', 'done'],
        startExitCode: 0,
      );
      final ExternalMokuroRunner ext = ExternalMokuroRunner(
        configuredPath: 'mokuro',
        processRunner: runner,
      );

      final List<MokuroRunEvent> events = await ext.run(imageDir.path).toList();
      expect(events.first.isRunning, isTrue);
      final Iterable<MokuroRunEvent> progress =
          events.where((MokuroRunEvent e) => !e.isRunning && !e.finished);
      expect(progress.map((MokuroRunEvent e) => '${e.done}/${e.total}'),
          contains('2/2'));
      final MokuroRunEvent last = events.last;
      expect(last.finished, isTrue);
      expect(last.mokuroPath, mokuroPath);
    });

    test('errors on non-zero exit code', () async {
      final Directory imageDir = Directory(p.join(tmp.path, 'v'))..createSync();
      File(p.join(imageDir.path, 'p001.jpg')).writeAsBytesSync(<int>[1]);
      final _FakeRunner runner =
          _FakeRunner(startLines: <String>['boom'], startExitCode: 3);
      final ExternalMokuroRunner ext = ExternalMokuroRunner(
        configuredPath: 'mokuro',
        processRunner: runner,
      );
      await expectLater(
        ext.run(imageDir.path).toList(),
        throwsA(isA<MokuroRunnerException>()),
      );
    });

    test('errors when executable cannot be resolved', () async {
      final _FakeRunner runner = _FakeRunner(
        onRunToCompletion: (String exe, List<String> args) async =>
            const MokuroProcessResult(exitCode: 1, stdout: '', stderr: ''),
      );
      final ExternalMokuroRunner ext = ExternalMokuroRunner(
        processRunner: runner,
        environment: const <String, String>{},
      );
      await expectLater(
        ext.run(tmp.path).toList(),
        throwsA(isA<MokuroRunnerException>()),
      );
    });
  });
}
