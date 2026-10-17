/// `audiobook align` 的端到端契约：入库一本 EPUB，配字幕 + 音频对齐，核对有声书行。
library;

import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_server/src/commands/audiobook_commands.dart';
import 'package:fushi_server/src/commands/import_commands.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'command_harness.dart';

void main() {
  late CommandHarness h;
  late AudiobookCommands module;

  setUp(() async {
    h = await CommandHarness.create();
    module = AudiobookCommands(io: h.io);
  });

  tearDown(() => h.dispose());

  Future<String> importBook() async {
    final String epub = p.join(h.tmp.path, 'book.epub');
    writeTestEpub(epub, 'Neko', body: '吾輩は猫である。名前はまだ無い。');
    expect(await h.run(ImportCommands(io: h.io), <String>['import', 'epub', epub]), 0);
    final FushiDatabase db = h.openDb();
    try {
      return (await db.getAllEpubBooks()).single.bookKey;
    } finally {
      await db.close();
    }
  }

  Directory audioDir(Map<String, String> files) {
    final Directory dir = Directory(p.join(h.tmp.path, 'audio'))..createSync(recursive: true);
    files.forEach((String name, String content) => File(p.join(dir.path, name)).writeAsStringSync(content));
    return dir;
  }

  const String srt =
      '1\n00:00:00,000 --> 00:00:02,000\n吾輩は猫である。\n\n'
      '2\n00:00:02,000 --> 00:00:04,000\n名前はまだ無い。\n';

  test('collectAudiobookInputs：目录取一层音频（自然序）与字幕候选', () {
    final Directory dir = audioDir(<String, String>{'10.mp3': 'x', '2.mp3': 'x', 'a.srt': 'x', 'note.txt': 'x'});
    final ({List<String> audio, List<String> subtitles}) r = collectAudiobookInputs(<String>[dir.path]);
    expect(r.audio.map(p.basename), <String>['2.mp3', '10.mp3']);
    expect(r.subtitles.map(p.basename), <String>['a.srt']);
  });

  test('对齐落库：有声书行 + cue，--json 报 cueCount 与健康度', () async {
    final String bookKey = await importBook();
    final Directory dir = audioDir(<String, String>{'01.mp3': 'fake audio', 'book.srt': srt});
    final int code = await h.run(module, <String>['audiobook', 'align', bookKey, '--audio', dir.path, '--json']);
    expect(code, 0, reason: '${h.err}');
    final Map<String, Object?> json = h.json();
    expect(json['bookKey'], bookKey);
    expect(json['cueCount'], 2);
    expect(json['health'], 'ok');
    expect((json['audio']! as List<Object?>).single, endsWith('01.mp3'));
    final FushiDatabase db = h.openDb();
    try {
      final AudiobookRow? row = await db.getAudiobookByBookKey(bookKey);
      expect(row, isNotNull);
    } finally {
      await db.close();
    }
  });

  test('退出码：缺 --audio 64 / 输入不存在 66 / 目录无字幕 66 / 多份字幕 64 / 缺书 66', () async {
    expect(await h.run(module, <String>['audiobook']), 64);
    expect(await h.run(module, <String>['audiobook', 'align', 'k']), 64);
    expect(await h.run(module, <String>['audiobook', 'align', 'k', '--audio', p.join(h.tmp.path, 'nope')]), 66);
    final Directory noSub = audioDir(<String, String>{'01.mp3': 'x'});
    expect(await h.run(module, <String>['audiobook', 'align', 'k', '--audio', noSub.path]), 66);
    File(p.join(noSub.path, 'a.srt')).writeAsStringSync(srt);
    File(p.join(noSub.path, 'b.vtt')).writeAsStringSync('WEBVTT\n');
    expect(await h.run(module, <String>['audiobook', 'align', 'k', '--audio', noSub.path]), 64);
    expect(
      await h.run(module, <String>[
        'audiobook', 'align', 'no-such-book', '--audio', noSub.path, '--srt', p.join(noSub.path, 'a.srt'), //
      ]),
      66,
    );
    expect(h.err.toString(), contains('no-such-book'));
  });
}
