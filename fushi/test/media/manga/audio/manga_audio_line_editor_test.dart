import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/tts/cast/cast_line_kind.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';

import 'package:fushi/src/media/audiobook/tts/studio/audio_production_host.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_line_editor.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_stores.dart';

/// 只给演出稿店用的数据目录；其余成员这里用不到。
class _DirHost implements AudioProductionHost {
  _DirHost(this.databaseDirectory);

  @override
  final Directory databaseDirectory;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MangaScriptLine _line(int page, List<int> blocks, String speaker) =>
    MangaScriptLine(
      page: page,
      blocks: blocks,
      speaker: speaker,
      kind: CastLineKind.values.first,
    );

void main() {
  group('mangaScriptLineForBlocks（阅读页气泡 → 演出稿那一句）', () {
    final MangaAudioScript script = MangaAudioScript(
      lines: <MangaScriptLine>[
        _line(0, <int>[0, 1], 'A'),
        _line(1, <int>[0], 'B'),
        _line(1, <int>[2, 3], 'C'),
      ],
    );

    test('按页与块找到那一句，跨块的一句任一块都能命中', () {
      expect(mangaScriptLineForBlocks(script, 1, <int>[3])?.speaker, 'C');
      expect(mangaScriptLineForBlocks(script, 1, <int>[2, 3])?.speaker, 'C');
      expect(mangaScriptLineForBlocks(script, 0, <int>[1])?.speaker, 'A');
    });

    test('同块号在别的页不算；没进演出稿的块返回 null', () {
      expect(mangaScriptLineForBlocks(script, 1, <int>[1]), isNull);
      expect(mangaScriptLineForBlocks(script, 2, <int>[0]), isNull);
      expect(mangaScriptLineForBlocks(script, 1, const <int>[]), isNull);
    });

    test('句子分组的首块没进稿时，用后面的块找', () {
      expect(mangaScriptLineForBlocks(script, 1, <int>[5, 0])?.speaker, 'B');
    });
  });

  test('只有改读法的动作才触发单句重生成', () {
    expect(
      <MangaLineEditAction>[
        for (final MangaLineEditAction a in MangaLineEditAction.values)
          if (a.changesVoice) a,
      ],
      <MangaLineEditAction>[
        MangaLineEditAction.speaker,
        MangaLineEditAction.kind,
        MangaLineEditAction.say,
        MangaLineEditAction.clearSay,
      ],
    );
  });

  group('mangaAudioHasLineAt（右键菜单列不列「编辑这句配音」）', () {
    late Directory dir;
    late AudioProductionHost host;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('manga_line_editor_test_');
      host = _DirHost(dir);
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('没有演出稿 → 不列', () async {
      expect(
        await mangaAudioHasLineAt(
          host,
          bookKey: 'book',
          page: 0,
          blocks: <int>[0],
        ),
        isFalse,
      );
    });

    test('有演出稿：命中进稿的气泡才列，空块不列', () async {
      await mangaAudioScriptStoreFor(host).save(
        'book',
        MangaAudioScript(
          lines: <MangaScriptLine>[
            _line(2, <int>[4, 5], 'A'),
          ],
        ),
      );
      Future<bool> at(int page, List<int> blocks) => mangaAudioHasLineAt(
        host,
        bookKey: 'book',
        page: page,
        blocks: blocks,
      );
      expect(await at(2, <int>[5]), isTrue);
      expect(await at(2, <int>[3]), isFalse);
      expect(await at(1, <int>[4]), isFalse);
      expect(await at(2, const <int>[]), isFalse);
      expect(
        await mangaAudioHasLineAt(
          host,
          bookKey: 'other',
          page: 2,
          blocks: <int>[4],
        ),
        isFalse,
      );
    });
  });
}
