/// `--json` 的 stdout 契约：进程 stdout 只有最终那一个 JSON 文档，可被 `jsonDecode`。
///
/// 回归来源：`audiobook align … --json` 的 stdout 混进
/// `[sentenceAudioHighlight] matcher …`——对齐匹配跑在 `Isolate.run` 的后台 isolate
/// 里，那里的 `fushiDebugPrint` 是 fushi_core 缺省的 `print`（根 isolate 的装配点带
/// 不过 isolate 边界），直接写 fd 1。进程内的 `CommandHarness` 只捕获 `CommandIo`，
/// 看不见 fd 1，所以这里必须起真进程。
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_server/src/commands/import_commands.dart';
import 'package:fushi_server/src/json_stdout_isolation.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'command_harness.dart';
import 'support/dart_executable.dart';

/// fd 级隔离只在 POSIX 上做（见 json_stdout_isolation.dart 库注释）。
final bool _posix = Platform.isLinux || Platform.isMacOS;

Object? _decodeWholeStdout(ProcessResult r) => jsonDecode(r.stdout as String);

void main() {
  test('commandChainWantsJson：任一层带 --json 都算', () {
    final ArgParser parser = ArgParser();
    parser.addCommand('audiobook').addCommand('align').addFlag('json');
    parser.addCommand('dict').addFlag('json');
    expect(commandChainWantsJson(parser.parse(<String>['audiobook', 'align', '--json'])), isTrue);
    expect(commandChainWantsJson(parser.parse(<String>['audiobook', 'align'])), isFalse);
    expect(commandChainWantsJson(parser.parse(<String>['dict', '--json', 'ls'])), isTrue);
  });

  test(
    '隔离下后台 isolate / 根 isolate 的 print 都改道 stderr，stdout 只剩 JSON',
    () async {
      final ProcessResult r = await Process.run(dartExecutable(), <String>[
        p.join('test', 'support', 'json_noise_cli.dart'),
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(_decodeWholeStdout(r), <String, Object?>{'ok': true}, reason: 'stdout=${r.stdout}');
      expect(r.stderr as String, contains('noise from background isolate'));
      expect(r.stderr as String, contains('noise from root isolate print'));
    },
    skip: _posix ? false : 'fd 级隔离只在 POSIX 上做',
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'audiobook align --json：真进程 stdout 可被 jsonDecode，匹配日志在 stderr',
    () async {
      final CommandHarness h = await CommandHarness.create();
      addTearDown(h.dispose);
      final String epub = p.join(h.tmp.path, 'book.epub');
      writeTestEpub(epub, 'Neko', body: '吾輩は猫である。名前はまだ無い。');
      expect(await h.run(ImportCommands(io: h.io), <String>['import', 'epub', epub]), 0, reason: '${h.err}');
      final FushiDatabase db = h.openDb();
      final String bookKey;
      try {
        bookKey = (await db.getAllEpubBooks()).single.bookKey;
      } finally {
        await db.close();
      }
      final Directory audio = Directory(p.join(h.tmp.path, 'audio'))..createSync(recursive: true);
      File(p.join(audio.path, '01.mp3')).writeAsStringSync('fake audio');
      File(p.join(audio.path, 'book.srt')).writeAsStringSync(
        '1\n00:00:00,000 --> 00:00:02,000\n吾輩は猫である。\n\n'
        '2\n00:00:02,000 --> 00:00:04,000\n名前はまだ無い。\n',
      );

      final ProcessResult r = await Process.run(dartExecutable(), <String>[
        'run',
        p.join('bin', 'fushi_server.dart'),
        '-c',
        h.configFile.path,
        'audiobook',
        'align',
        bookKey,
        '--audio',
        audio.path,
        '--json',
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final Object? json = _decodeWholeStdout(r);
      expect(json, isA<Map<String, Object?>>(), reason: 'stdout=${r.stdout}');
      expect((json! as Map<String, Object?>)['cueCount'], 2);
      // 证明诊断确实发生过、只是去了 stderr（而不是恰好没打印）。
      expect(r.stderr as String, contains('[sentenceAudioHighlight]'));
    },
    skip: _posix ? false : 'fd 级隔离只在 POSIX 上做',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
