import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audiobook_match.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/audio/manga_audiobook_source.dart';
import 'package:fushi/src/media/manga/audio/manga_audiobook_source_page.dart';

/// 设计 §9：漫画关联书库里的有声书、看命中统计、按策略写进演出稿。
MokuroBlock _block(String text) => MokuroBlock(
  rectangle: const MokuroRect.fromLTRB(0, 0, 10, 10),
  isVertical: true,
  fontSize: 24,
  zIndex: 0,
  lines: <String>[text],
);

MangaScriptLine _line(int block, {MangaLineAudioSource? audio}) =>
    MangaScriptLine(
      page: 0,
      blocks: <int>[block],
      speaker: 'A',
      kind: CastLineKind.spoken,
      audio: audio ?? const MangaSynthesized(),
    );

/// 内存里的后端：演出稿、OCR 与语料都是固定数据；匹配用真匹配器，归一化换成恒等
/// （不加载原生库，语料文本已是归一化形态）。
class _FakeBackend implements MangaAudiobookSourceBackend {
  _FakeBackend({required this.script, this.payload, this.volumes = const []});

  MangaAudioScript script;
  final MokuroPayload? payload;
  final List<String> volumes;
  final Map<String, MangaAudioScript> otherScripts =
      <String, MangaAudioScript>{};
  int saves = 0;

  static const Map<String, List<String>> corpora = <String, List<String>>{
    'novel-1': <String>['関係のない地の文です', 'お前はここで待っていろ', '別の文章が続いていく'],
    'novel-2': <String>[],
  };

  @override
  Future<MangaAudioScript> loadScript(String bookKey) async =>
      MangaAudioScript.fromJson(script.toJson());

  @override
  Future<void> saveScript(String bookKey, MangaAudioScript s) async {
    saves++;
    script = MangaAudioScript.fromJson(s.toJson());
  }

  @override
  Future<List<MangaAudiobookCandidate>> candidates(String bookKey) async =>
      const <MangaAudiobookCandidate>[
        MangaAudiobookCandidate(bookKey: 'novel-1', title: 'Novel One'),
        MangaAudiobookCandidate(bookKey: 'novel-2', title: 'Novel Two'),
      ];

  @override
  Future<MokuroPayload?> loadPayload(String bookKey) async => payload;

  @override
  Future<MangaAudiobookCorpus> loadCorpus(List<String> bookKeys) async {
    final List<MangaAudiobookCue> cues = <MangaAudiobookCue>[];
    final Map<String, int> counts = <String, int>{};
    for (final String key in bookKeys) {
      final List<String> texts = corpora[key] ?? const <String>[];
      counts[key] = texts.length;
      for (int i = 0; i < texts.length; i++) {
        cues.add(
          MangaAudiobookCue(
            bookKey: key,
            fileIndex: 0,
            startMs: i * 1000,
            endMs: i * 1000 + 800,
            text: texts[i],
          ),
        );
      }
    }
    return MangaAudiobookCorpus(
      cues: cues,
      cueCounts: counts,
      withTokenTiming: const <String>{},
    );
  }

  @override
  Future<MangaAudiobookMatchResult> match(
    List<MangaAudiobookQueryLine> lines,
    List<MangaAudiobookCue> corpus,
  ) async => matchMangaLinesToAudiobook(
    lines: lines,
    corpus: corpus,
    normalize: (List<String> texts) => texts,
  );

  @override
  Future<List<String>> seriesVolumes(String bookKey) async => volumes;

  @override
  Future<int> linkSourcesTo(List<String> vols, List<String> sources) async {
    for (final String v in vols) {
      otherScripts[v] = MangaAudioScript(audiobookSources: sources);
    }
    return vols.length;
  }
}

Widget _wrap(_FakeBackend backend) => TranslationProvider(
  child: MaterialApp(
    home: Scaffold(
      body: MangaAudiobookSourcePanel(bookKey: 'manga-1', backend: backend),
    ),
  ),
);

MokuroPayload _payload() => MokuroPayload(
  images: <MokuroImage>[
    MokuroImage(
      url: 'p0.jpg',
      size: const MokuroSize(100, 100),
      blocks: <MokuroBlock>[
        _block('お前はここで待っていろ'), // 命中
        _block('漫画だけの独自の台詞です'), // 没命中
        _block('え？'), // 太短
      ],
    ),
  ],
);

void main() {
  group('mangaAudiobookQueryLines', () {
    test('只取会发声的行，文本按 OCR 块 / 手填解析，页越界的行跳过', () {
      final MangaAudioScript script = MangaAudioScript(
        lines: <MangaScriptLine>[
          _line(0),
          MangaScriptLine(
            page: 0,
            blocks: const <int>[1],
            speaker: 'A',
            kind: CastLineKind.skip,
          ),
          _line(2).copyWith(say: '手で書いた台詞'),
          MangaScriptLine(
            page: 5,
            blocks: const <int>[0],
            speaker: 'A',
            kind: CastLineKind.spoken,
          ),
        ],
      );
      final List<MangaAudiobookQueryLine> lines = mangaAudiobookQueryLines(
        script,
        _payload(),
      );
      expect(lines.map((MangaAudiobookQueryLine l) => l.text), <String>[
        'お前はここで待っていろ',
        '手で書いた台詞',
      ]);
      expect(lines.first.lineId, 'p0b0');
    });
  });

  group('attachTokenTimingIfAligned', () {
    AudioCue cue(int start, int end, {CueTokenTiming? timing}) => AudioCue()
      ..bookKey = 'b'
      ..chapterHref = 'c'
      ..sentenceIndex = 0
      ..textFragmentId = ''
      ..text = 'x'
      ..startMs = start
      ..endMs = end
      ..audioFileIndex = 0
      ..tokenTiming = timing;
    CueTokenTiming timing() =>
        CueTokenTiming(tokens: <String>['x'], offsetsMs: <int>[0]);

    test('一一对应才挂', () {
      final List<AudioCue> stored = <AudioCue>[cue(0, 10), cue(10, 20)];
      final bool ok = attachTokenTimingIfAligned(stored, <AudioCue>[
        cue(0, 10, timing: timing()),
        cue(10, 20, timing: timing()),
      ]);
      expect(ok, true);
      expect(stored.every((AudioCue c) => c.tokenTiming != null), true);
    });

    test('库里的 cue 重切过（条数或起止不同）就一条都不挂', () {
      final List<AudioCue> stored = <AudioCue>[cue(0, 10), cue(10, 20)];
      expect(
        attachTokenTimingIfAligned(stored, <AudioCue>[
          cue(0, 10, timing: timing()),
        ]),
        false,
      );
      expect(
        attachTokenTimingIfAligned(stored, <AudioCue>[
          cue(0, 10, timing: timing()),
          cue(12, 20, timing: timing()),
        ]),
        false,
      );
      expect(stored.every((AudioCue c) => c.tokenTiming == null), true);
    });
  });

  group('MangaAudiobookSourcePanel', () {
    testWidgets('关联有声书 → 统计命中 → 写入演出稿；用户定的音源不动', (WidgetTester tester) async {
      final _FakeBackend backend = _FakeBackend(
        script: MangaAudioScript(
          lines: <MangaScriptLine>[
            _line(0),
            _line(1),
            _line(2),
            // 用户钉过的行：命中与否都不动。
            MangaScriptLine(
              page: 0,
              blocks: const <int>[3],
              speaker: 'A',
              kind: CastLineKind.spoken,
              audio: const MangaSynthesized(byUser: true),
            ),
          ],
        ),
        payload: _payload(),
      );
      await tester.pumpWidget(_wrap(backend));
      await tester.pumpAndSettle();
      expect(find.text(t.manga_audio_source_linked_empty), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('manga_audio_source_add')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Novel One'));
      await tester.pumpAndSettle();
      expect(backend.script.audiobookSources, <String>['novel-1']);
      expect(
        find.byKey(const ValueKey<String>('manga_audio_source_item_novel-1')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('manga_audio_source_analyze')),
      );
      await tester.pumpAndSettle();
      Finder stat(String key) =>
          find.byKey(ValueKey<String>('manga_audio_source_stat_$key'));
      expect(
        find.descendant(of: stat('hits'), matching: find.text('1')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: stat('short'), matching: find.text('2')),
        findsOneWidget,
      );
      // 太短 2 句：「え？」与块 3（OCR 里没有这块，拼出空串）；第 2 行没命中。
      expect(
        find.descendant(of: stat('misses'), matching: find.text('1')),
        findsOneWidget,
      );
      // 语料没有逐 token 时间：明确告知半句命中不可用。
      expect(
        find.byKey(
          const ValueKey<String>('manga_audio_source_no_token_timing'),
        ),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('manga_audio_source_apply')),
      );
      await tester.pumpAndSettle();
      final MangaAudioScript saved = backend.script;
      expect(
        saved.lines[0].audio,
        const MangaAudiobookClip(
          bookKey: 'novel-1',
          fileIndex: 0,
          startMs: 1000,
          endMs: 1800,
        ),
      );
      expect(saved.lines[1].audio, const MangaSynthesized());
      expect(saved.lines[3].audio, const MangaSynthesized(byUser: true));
      expect(
        saved.audioPlanFor(saved.lines[0]),
        MangaLineAudioPlan.audiobookClip,
      );
    });

    testWidgets('没读到 cue 的关联书单独提示；改策略立即落稿', (WidgetTester tester) async {
      final _FakeBackend backend = _FakeBackend(
        script: MangaAudioScript(
          audiobookSources: <String>['novel-2'],
          lines: <MangaScriptLine>[_line(0)],
        ),
        payload: _payload(),
      );
      await tester.pumpWidget(_wrap(backend));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_audio_source_analyze')),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(t.manga_audio_source_no_cues(title: 'Novel Two')),
        findsOneWidget,
      );

      // 选项长，MD3 下是「当前值 + 点整行弹菜单」。
      await tester.tap(find.text(t.manga_audio_source_policy));
      await tester.pumpAndSettle();
      await tester.tap(
        find.text(t.manga_audio_source_policy_audiobook_only).last,
      );
      await tester.pumpAndSettle();
      expect(backend.script.sourcePolicy, MangaAudioSourcePolicy.audiobookOnly);
      expect(
        find.textContaining(t.manga_audio_source_policy_hint_only),
        findsOneWidget,
      );
    });

    testWidgets('演出稿还没有台词时不跑匹配，提示先标注', (WidgetTester tester) async {
      final _FakeBackend backend = _FakeBackend(
        script: MangaAudioScript(audiobookSources: <String>['novel-1']),
        payload: _payload(),
      );
      await tester.pumpWidget(_wrap(backend));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_audio_source_analyze')),
      );
      await tester.pumpAndSettle();
      expect(find.text(t.manga_audio_source_no_script), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('manga_audio_source_apply')),
        findsNothing,
      );
    });

    testWidgets('整个系列都用这些：书单写进同系列其它卷', (WidgetTester tester) async {
      final _FakeBackend backend = _FakeBackend(
        script: MangaAudioScript(audiobookSources: <String>['novel-1']),
        volumes: const <String>['manga-2', 'manga-3'],
      );
      await tester.pumpWidget(_wrap(backend));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_audio_source_apply_series')),
      );
      await tester.pumpAndSettle();
      expect(backend.otherScripts.keys, <String>['manga-2', 'manga-3']);
      expect(backend.otherScripts['manga-3']!.audiobookSources, <String>[
        'novel-1',
      ]);
    });
  });

  test('formatMangaClipDuration', () {
    expect(formatMangaClipDuration(0), '0:00');
    expect(formatMangaClipDuration(65400), '1:05');
    expect(formatMangaClipDuration(3723000), '1:02:03');
  });
}
