// HBK-AUDIT-016：演出稿的保存修订、同卷并发保存与整稿序列化成本。
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/cast/cast_line_kind.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:test/test.dart';

MangaScriptLine _line(int page, int block, {String speaker = kTtsUnknown}) =>
    MangaScriptLine(
      page: page,
      blocks: <int>[block],
      speaker: speaker,
      kind: CastLineKind.spoken,
    );

MangaAudioScript _script(String speaker, {int pages = 3}) => MangaAudioScript(
  engineSignature: 'sig',
  lines: <MangaScriptLine>[
    for (int p = 0; p < pages; p++) ...<MangaScriptLine>[
      _line(p, 0, speaker: speaker),
      _line(p, 1),
    ],
  ],
);

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('manga_rev_'));
  tearDown(() async => dir.delete(recursive: true));

  group('保存修订', () {
    test('读盘后别处存过：saveIfCurrent 拒写，盘上保留别处的结果', () async {
      final MangaAudioScriptStore store = MangaAudioScriptStore(dir);
      await store.save('b', _script('A'));
      // 复核页的旧会话与标注任务的新会话各读一份。
      final MangaAudioScript stale = await store.load('b');
      final MangaAudioScript task = await MangaAudioScriptStore(dir).load('b');
      task.replaceLine('p0b1', (MangaScriptLine l) => l.copyWith(speaker: 'T'));
      await MangaAudioScriptStore(dir).save('b', task);

      stale.replaceLine(
        'p0b0',
        (MangaScriptLine l) =>
            l.copyWith(speaker: 'U', source: TtsCastSource.user),
      );
      expect(await store.saveIfCurrent('b', stale), isFalse);
      final MangaAudioScript disk = await store.load('b');
      expect(disk.lineById('p0b1')!.speaker, 'T');
      expect(disk.lineById('p0b0')!.speaker, 'A');

      // 重读后的新会话可以存，且存完修订跟着前进，连存第二次也行。
      disk.replaceLine('p0b0', (MangaScriptLine l) => l.copyWith(speaker: 'U'));
      expect(await store.saveIfCurrent('b', disk), isTrue);
      disk.replaceLine('p1b0', (MangaScriptLine l) => l.copyWith(speaker: 'V'));
      expect(await store.saveIfCurrent('b', disk), isTrue);
      final MangaAudioScript back = await store.load('b');
      expect(back.lineById('p0b0')!.speaker, 'U');
      expect(back.lineById('p0b1')!.speaker, 'T');
      expect(back.lineById('p1b0')!.speaker, 'V');
    });

    test('没从盘上读过的演出稿不能按修订存', () async {
      expect(
        await MangaAudioScriptStore(dir).saveIfCurrent('b', _script('A')),
        isFalse,
      );
      expect(MangaAudioScriptStore(dir).fileFor('b').existsSync(), isFalse);
    });
  });

  group('同卷并发保存', () {
    test('两个店实例同时存同一卷：都成功、按调用顺序落盘、不留临时文件', () async {
      final List<Future<void>> saves = <Future<void>>[
        for (int i = 0; i < 8; i++)
          MangaAudioScriptStore(dir).save('b', _script('S$i', pages: 200)),
      ];
      await Future.wait(saves);
      final MangaAudioScript back = await MangaAudioScriptStore(dir).load('b');
      expect(back.lineById('p0b0')!.speaker, 'S7');
      expect(
        dir.listSync().map((FileSystemEntity e) => e.uri.pathSegments.last),
        <String>[MangaAudioScriptStore(dir).fileFor('b').uri.pathSegments.last],
      );
    });

    test('存盘排队期间读盘看到的是已排在前面的写入', () async {
      final MangaAudioScriptStore store = MangaAudioScriptStore(dir);
      final Future<void> save = store.save('b', _script('A'));
      final MangaAudioScript read = await store.load('b');
      await save;
      expect(read.lineById('p0b0')!.speaker, 'A');
    });
  });

  group('序列化与查行', () {
    test('增量序列化与整稿 toJson 等价（改行、插行、删行之后）', () {
      final MangaAudioScript s = _script('A', pages: 5)
        ..audiobookSources.add('book');
      String encoded = s.encode();
      expect(jsonDecode(encoded), equals(jsonDecode(jsonEncode(s.toJson()))));
      s.replaceLine('p2b1', (MangaScriptLine l) => l.copyWith(speaker: 'Z'));
      s.lines.insert(0, _line(0, 9));
      s.lines.removeWhere((MangaScriptLine l) => l.page == 3);
      encoded = s.encode();
      expect(jsonDecode(encoded), equals(jsonDecode(jsonEncode(s.toJson()))));
      expect(
        MangaAudioScript.fromJson(
          jsonDecode(encoded),
        ).lineById('p2b1')!.speaker,
        'Z',
      );
    });

    test('lineById 在外部直接改 lines 之后仍然准确', () {
      final MangaAudioScript s = _script('A', pages: 4);
      expect(s.lineById('p3b1')!.page, 3);
      s.lines.insert(0, _line(0, 7));
      expect(s.lineById('p3b1')!.page, 3);
      expect(s.lineById('p0b7')!.blocks, <int>[7]);
      s.lines.removeWhere((MangaScriptLine l) => l.page == 3);
      expect(s.lineById('p3b1'), isNull);
      s.lines[0] = _line(0, 8);
      expect(s.lineById('p0b7'), isNull);
      expect(s.lineById('p0b8'), isNotNull);
      expect(s.replaceLine('p9b0', (MangaScriptLine l) => l), isFalse);
    });
  });
}
