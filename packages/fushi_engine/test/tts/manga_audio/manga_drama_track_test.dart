import 'dart:convert';
import 'dart:io';

import 'package:fushi_audio/fushi_audio_core.dart' show CueMatch, EpubSection;
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_timeline.dart';
import 'package:fushi_engine/tts/manga_audio/manga_drama_track.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 测试用归一化：只去掉标点与空白（真归一化走 FFI，单独一组测试覆盖）。
List<String> _strip(List<String> texts) => <String>[
  for (final String t in texts) t.replaceAll(RegExp(r'[\s、。！？!?「」…]'), ''),
];

MangaDramaUnit _unit(int page, int block, String text) =>
    MangaDramaUnit(page: page, blocks: <int>[block], text: text);

MangaDramaCue _cue(int start, int end, String text, {int file = 0}) =>
    MangaDramaCue(fileIndex: file, startMs: start, endMs: end, text: text);

CueMatch _hit(int section, int start, int end) => CueMatch(
  cueSentenceIndex: 0,
  sectionIndex: section,
  normCharStart: start,
  normCharEnd: end,
  score: 1,
);

MokuroBlock _block(String text) => MokuroBlock(
  rectangle: const MokuroRect.fromLTRB(0, 0, 10, 10),
  isVertical: true,
  fontSize: 12,
  zIndex: 0,
  lines: <String>[text],
);

MokuroImage _page(List<String> blocks) => MokuroImage(
  url: 'p.jpg',
  size: const MokuroSize(100, 100),
  blocks: <MokuroBlock>[for (final String b in blocks) _block(b)],
);

class _FakeCutter implements MangaDramaCutter {
  final List<({String source, int start, int? end})> calls =
      <({String source, int start, int? end})>[];

  @override
  Future<int> cut({
    required String sourcePath,
    required int startMs,
    required int? endMs,
    required String outputPath,
    required TtsRenderCancelToken cancel,
  }) async {
    calls.add((source: sourcePath, start: startMs, end: endMs));
    await File(outputPath).writeAsString('audio');
    // 源文件假定 60 秒长。
    return (endMs ?? 60000) - startMs;
  }
}

void main() {
  group('buildMangaDramaSections', () {
    test('一页一个 section，短单元不进正文，区间按归一化后的拼接坐标', () {
      final MangaDramaSections s = buildMangaDramaSections(
        units: <MangaDramaUnit>[
          _unit(0, 0, 'おはようございます。'),
          _unit(0, 1, 'うん。'),
          _unit(2, 0, '今日は天気がいいですね！'),
          _unit(2, 1, '散歩に行きましょう'),
        ],
        pageCount: 3,
        normalize: _strip,
      );
      expect(s.sections.map((EpubSection e) => e.href), <String>[
        'manga-page-0',
        'manga-page-1',
        'manga-page-2',
      ]);
      expect(s.sections[0].text, 'おはようございます');
      expect(s.sections[1].text, '');
      expect(s.sections[2].text, '今日は天気がいいですね散歩に行きましょう');
      expect(s.matchableUnits, 3);
      expect(s.shortUnits, 1);
      expect(
        s.spans[2].map((MangaDramaSpan e) => (e.unit, e.start, e.end)),
        <(int, int, int)>[(2, 0, 11), (3, 11, 20)],
      );
      expect(s.sectionStarts, <int>[0, 9, 9, 29]);
    });

    test('OCR 块当单元：每块一个，块内各行直接相连', () {
      final MokuroPayload payload = MokuroPayload(
        images: <MokuroImage>[
          _page(<String>['一', '二']),
          _page(<String>[]),
          _page(<String>['三']),
        ],
      );
      final List<MangaDramaUnit> units = mangaDramaUnitsFromOcr(payload);
      expect(
        units.map((MangaDramaUnit u) => (u.page, u.blocks.join(','), u.text)),
        <(int, String, String)>[(0, '0', '一'), (0, '1', '二'), (2, '0', '三')],
      );
    });

    test('演出稿当单元：只取会发声的行，文本走 resolveMangaLineText', () {
      final MokuroPayload payload = MokuroPayload(
        images: <MokuroImage>[
          _page(<String>['こんにちは', 'ドン']),
        ],
      );
      final MangaAudioScript script = MangaAudioScript(
        lines: <MangaScriptLine>[
          MangaScriptLine(
            page: 0,
            blocks: const <int>[0],
            speaker: 'A',
            kind: CastLineKind.spoken,
          ),
          MangaScriptLine(
            page: 0,
            blocks: const <int>[1],
            speaker: 'A',
            kind: CastLineKind.skip,
          ),
        ],
      );
      final List<MangaDramaUnit> units = mangaDramaUnitsFromScript(
        script,
        payload,
      );
      expect(units.single.text, 'こんにちは');
      expect(units.single.blocks, <int>[0]);
    });
  });

  group('buildMangaDramaTrack', () {
    final MangaDramaSections sections = buildMangaDramaSections(
      units: <MangaDramaUnit>[
        _unit(0, 0, 'おはようございます'), // p0 [0,9)
        _unit(1, 0, '今日は天気がいいですね'), // p1 [0,11)
        _unit(1, 1, '散歩に行きましょう'), // p1 [11,20)
        _unit(3, 2, 'さようなら また明日'), // p3 [0,9)
      ],
      pageCount: 4,
      normalize: _strip,
    );

    test('命中的 cue 高亮对应块；没命中的只播放挂在当前页；音频铺满音轨', () {
      final MangaDramaTrack track = buildMangaDramaTrack(
        sections: sections,
        cues: <MangaDramaCue>[
          _cue(1000, 3000, 'おはようございます'),
          _cue(4000, 6000, '（効果音）ガチャ ガチャ ガチャ'),
          _cue(7000, 9000, '今日は天気がいいですね'),
          _cue(9500, 12000, '散歩に行きましょう'),
          _cue(13000, 15000, 'さようならまた明日'),
        ],
        matches: <CueMatch>[
          _hit(0, 0, 9),
          CueMatch.unmatched,
          _hit(1, 0, 11),
          _hit(1, 11, 20),
          _hit(3, 0, 9),
        ],
        cueNormLengths: <int>[9, 12, 11, 9, 9],
      );
      expect(
        track.segments
            .map(
              (MangaDramaSegment s) =>
                  (s.startMs, s.endMs, s.page, s.blocks.join(',')),
            )
            .toList(),
        <(int, int?, int, String)>[
          (0, 4000, 0, '0'),
          (4000, 7000, 0, ''),
          (7000, 9500, 1, '0'),
          (9500, 13000, 1, '1'),
          (13000, null, 3, '2'),
        ],
      );
      expect(track.stats.matchedCues, 4);
      expect(track.stats.coveredUnits, 4);
      expect(track.stats.unitCoverage, 1);
      expect(track.stats.highlightedSegments, 4);
    });

    test('不足 6 字的 cue 即使匹配器给了位置也不高亮', () {
      final MangaDramaTrack track = buildMangaDramaTrack(
        sections: sections,
        cues: <MangaDramaCue>[_cue(0, 1000, 'おはよう')],
        matches: <CueMatch>[_hit(0, 0, 4)],
        cueNormLengths: <int>[4],
      );
      expect(track.segments.single.blocks, isEmpty);
      expect(track.stats.shortCues, 1);
      expect(track.stats.matchedCues, 0);
    });

    test('页只往后走：命中页比当前页靠前的 cue 作废', () {
      final MangaDramaTrack track = buildMangaDramaTrack(
        sections: sections,
        cues: <MangaDramaCue>[
          _cue(0, 1000, '今日は天気がいいですね'),
          _cue(1000, 2000, 'おはようございます'),
        ],
        matches: <CueMatch>[_hit(1, 0, 11), _hit(0, 0, 9)],
        cueNormLengths: <int>[11, 9],
      );
      expect(
        track.segments.map(
          (MangaDramaSegment s) => (s.page, s.blocks.join(',')),
        ),
        <(int, String)>[(1, '0'), (1, '')],
      );
      expect(track.stats.backwardCues, 1);
    });

    test('同页同块的相邻段合并（ASR 把一句切成两条）；文件之间各自铺满', () {
      final MangaDramaTrack track = buildMangaDramaTrack(
        sections: sections,
        cues: <MangaDramaCue>[
          _cue(500, 2000, '今日は天気が'),
          _cue(2000, 3000, 'いいですね'),
          _cue(800, 2000, 'さようならまた明日', file: 1),
        ],
        matches: <CueMatch>[_hit(1, 0, 6), _hit(1, 6, 11), _hit(3, 0, 9)],
        cueNormLengths: <int>[6, 6, 9],
      );
      expect(
        track.segments
            .map(
              (MangaDramaSegment s) =>
                  (s.fileIndex, s.startMs, s.endMs, s.page, s.text),
            )
            .toList(),
        <(int, int, int?, int, String)>[
          (0, 0, null, 1, '今日は天気がいいですね'),
          (1, 0, null, 3, 'さようならまた明日'),
        ],
      );
    });

    test('区间跨页尾时取覆盖多的那页，只高亮够格的单元', () {
      // 全卷区间 [26,37)：p1 的「散歩に行きましょう」只被盖住 3 字，p3 的单元被盖住 8 字。
      final MangaDramaTrack track = buildMangaDramaTrack(
        sections: sections,
        cues: <MangaDramaCue>[_cue(0, 1000, 'xx')],
        matches: <CueMatch>[_hit(1, 17, 28)],
        cueNormLengths: <int>[11],
      );
      expect(track.segments.single.page, 3);
      expect(track.segments.single.blocks, <int>[2]);
    });

    test('长度不一致是程序错误', () {
      expect(
        () => buildMangaDramaTrack(
          sections: sections,
          cues: <MangaDramaCue>[_cue(0, 1, 'a')],
          matches: const <CueMatch>[],
          cueNormLengths: <int>[1],
        ),
        throwsArgumentError,
      );
    });
  });

  group('真匹配器（有声书匹配器 + Rust 归一化）', () {
    test('转录有错字、有片头与效果音，仍按页对上', () {
      final MangaDramaSections s = buildMangaDramaSections(
        units: <MangaDramaUnit>[
          _unit(0, 0, '昨日の夜、駅前で不思議な男に会った。'),
          _unit(0, 1, 'その男は黒い傘を持っていた。'),
          _unit(1, 0, '雨なんて一滴も降っていなかったのに。'),
          _unit(2, 0, 'ねえ、あの人のこと覚えてる？'),
          _unit(2, 1, 'もちろん覚えているよ、忘れるわけがない。'),
        ],
        pageCount: 3,
      );
      final List<String> cueTexts = <String>[
        'このドラマはフィクションです',
        '昨日の夜駅前で不思議な男に会った',
        'その男は黒い傘を持っていた',
        '雨なんて一的も降っていなかったのに',
        'ねえあの人のこと覚えてる',
        'もちろん覚えているよ忘れるわけがない',
      ];
      final List<CueMatch> matches = matchMangaDramaSync(s.sections, cueTexts);
      final MangaDramaTrack track = buildMangaDramaTrack(
        sections: s,
        cues: <MangaDramaCue>[
          for (int i = 0; i < cueTexts.length; i++)
            _cue(i * 3000, i * 3000 + 2500, cueTexts[i]),
        ],
        matches: matches,
        cueNormLengths: <int>[for (final String t in cueTexts) t.length],
      );
      expect(
        track.segments.map(
          (MangaDramaSegment e) => (e.page, e.blocks.join(',')),
        ),
        <(int, String)>[
          (0, ''),
          (0, '0'),
          (0, '1'),
          (1, '0'),
          (2, '0'),
          (2, '1'),
        ],
      );
      expect(track.stats.coveredUnits, 5);
    });
  });

  group('runMangaDramaTrack', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('manga_drama_');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('假转录 → 匹配 → 按段剪 → 写连续清单，清掉旧段文件', () async {
      final File manifestFile = File(p.join(tmp.path, 'b', 'manifest.json'));
      await manifestFile.parent.create(recursive: true);
      final File stale = File(p.join(manifestFile.parent.path, 'old.m4a'));
      await stale.writeAsString('old');
      final _FakeCutter cutter = _FakeCutter();
      final List<(MangaDramaPhase, int, int)> progress =
          <(MangaDramaPhase, int, int)>[];
      final MangaDramaOutcome out = await runMangaDramaTrack(
        units: <MangaDramaUnit>[
          _unit(0, 0, 'おはようございます'),
          _unit(1, 0, '今日は天気がいいですね'),
        ],
        pageCount: 2,
        ocrSignature: 'sig',
        audioPaths: <String>['a.mp3', 'b.mp3'],
        transcribe: (String path, int file, TtsRenderCancelToken _) async =>
            path == 'a.mp3'
            ? <MangaDramaCue>[
                // 乱序给，流水线按时间排。
                _cue(5000, 8000, '今日は天気がいいですね'),
                _cue(1000, 3000, 'おはようございます'),
                _cue(3000, 3500, '   '),
              ]
            : <MangaDramaCue>[_cue(0, 2000, 'エンディングテーマ')],
        match: (List<EpubSection> sections, List<String> texts) async =>
            <CueMatch>[
              for (final String t in texts)
                t == 'おはようございます'
                    ? _hit(0, 0, 9)
                    : t == '今日は天気がいいですね'
                    ? _hit(1, 0, 11)
                    : CueMatch.unmatched,
            ],
        cutter: cutter,
        manifestFile: manifestFile,
        cancel: TtsRenderCancelToken(),
        normalize: _strip,
        onProgress: (MangaDramaPhase ph, int d, int t) =>
            progress.add((ph, d, t)),
      );
      expect(cutter.calls, <({String source, int start, int? end})>[
        (source: 'a.mp3', start: 0, end: 5000),
        (source: 'a.mp3', start: 5000, end: null),
        (source: 'b.mp3', start: 0, end: null),
      ]);
      final MangaRenderManifest m = out.manifest;
      expect(m.continuous, isTrue);
      expect(m.engineSignature, 'sig');
      expect(
        m.lines.map(
          (MangaRenderedLine l) => (l.page, l.blocks.join(','), l.file),
        ),
        <(int, String, String)>[
          (0, '0', 'drama_00000.m4a'),
          (1, '0', 'drama_00001.m4a'),
          (1, '', 'drama_00002.m4a'),
        ],
      );
      expect(await stale.exists(), isFalse);
      for (final MangaRenderedLine l in m.lines) {
        expect(
          await File(p.join(manifestFile.parent.path, l.file)).exists(),
          isTrue,
        );
      }
      // 落盘往返保留连续标记；连续清单的时间表不插任何停顿。
      final MangaRenderManifest? loaded = await MangaRenderManifest.load(
        manifestFile,
      );
      expect(loaded!.continuous, isTrue);
      final MangaTimeline tl = loaded.timeline();
      expect(tl.totalMs, 5000 + 55000 + 60000);
      expect(tl.lines.every((MangaLineTiming t) => t.gapAfterMs == 0), isTrue);
      expect(progress.last, (MangaDramaPhase.cutting, 3, 3));
      expect(
        jsonDecode(await manifestFile.readAsString()),
        containsPair('cont', true),
      );
    });

    test('转录全空抛 MangaDramaEmptyTranscript，不写清单', () async {
      final File manifestFile = File(p.join(tmp.path, 'c', 'manifest.json'));
      await expectLater(
        runMangaDramaTrack(
          units: const <MangaDramaUnit>[],
          pageCount: 1,
          ocrSignature: null,
          audioPaths: <String>['a.mp3'],
          transcribe: (String _, int _, TtsRenderCancelToken _) async =>
              <MangaDramaCue>[],
          cutter: _FakeCutter(),
          manifestFile: manifestFile,
          cancel: TtsRenderCancelToken(),
          normalize: _strip,
        ),
        throwsA(isA<MangaDramaEmptyTranscript>()),
      );
      expect(await manifestFile.exists(), isFalse);
    });

    test('取消在转录之前就生效', () async {
      final TtsRenderCancelToken cancel = TtsRenderCancelToken()..cancel();
      await expectLater(
        runMangaDramaTrack(
          units: const <MangaDramaUnit>[],
          pageCount: 1,
          ocrSignature: null,
          audioPaths: <String>['a.mp3'],
          transcribe: (String _, int _, TtsRenderCancelToken _) async =>
              throw StateError('should not transcribe'),
          cutter: _FakeCutter(),
          manifestFile: File(p.join(tmp.path, 'd', 'manifest.json')),
          cancel: cancel,
          normalize: _strip,
        ),
        throwsA(isA<TtsRenderCancelled>()),
      );
    });
  });

  test('非连续清单不受影响（不写 cont 键）', () {
    final MangaRenderManifest m = MangaRenderManifest(
      pageCount: 1,
      lines: <MangaRenderedLine>[],
    );
    expect(m.toJson().containsKey('cont'), isFalse);
    expect(MangaRenderManifest.fromJson(m.toJson())!.continuous, isFalse);
  });
}
