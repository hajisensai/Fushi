import 'dart:io';

import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/cast/cast_line_voicing.dart';
import 'package:fushi_engine/tts/cast/cast_text_substitution.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_narrator.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render_plan.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_renderer.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:fushi_engine/tts/tts_direction.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

MokuroBlock _block(String text) => MokuroBlock(
  rectangle: const MokuroRect.fromLTRB(0, 0, 10, 10),
  isVertical: true,
  fontSize: 12,
  zIndex: 0,
  lines: <String>[text],
);

/// 3 页：第 0 页两块、第 1 页无台词、第 2 页一块。
List<List<MokuroBlock>> _pages() => <List<MokuroBlock>>[
  <MokuroBlock>[_block('おはよう。'), _block('元気？')],
  <MokuroBlock>[],
  <MokuroBlock>[_block('またね')],
];

MangaScriptLine _line(
  int page,
  List<int> blocks, {
  String speaker = 'A',
  CastLineKind kind = CastLineKind.spoken,
  MangaLineAudioSource audio = const MangaSynthesized(),
  String? voice,
  String? say,
  int? seed,
}) => MangaScriptLine(
  page: page,
  blocks: blocks,
  speaker: speaker,
  kind: kind,
  audio: audio,
  voice: voice,
  say: say,
  seed: seed,
);

class _FakeBackend implements MangaRenderBackend {
  final Set<String> failVoices = <String>{};

  /// 克隆旁白：能不能克隆、准备成不成功、每次准备收到的声音 id。
  @override
  bool canCloneNarrator = false;
  bool narratorReady = true;
  final List<String> narratorPrepared = <String>[];

  @override
  Future<bool> prepareNarrator({
    required MangaNarratorVoice narrator,
    required TtsRenderCancelToken cancel,
  }) async {
    narratorPrepared.add(narrator.id);
    return narratorReady;
  }

  final List<String> synthCalls = <String>[];
  int clipCalls = 0;

  /// 每次合成开头收到要念的整句文字（测试在这里中途取消）。
  void Function(String text)? onSynthesize;

  /// 每次 [prepare] 收到的行身份。
  final List<List<String>> prepared = <List<String>>[];

  @override
  Future<void> prepare({
    required List<MangaRenderItem> items,
    required TtsRenderCancelToken cancel,
  }) async {
    prepared.add(<String>[for (final MangaRenderItem i in items) i.lineId]);
  }

  @override
  int parallelism = 1;

  /// 整形版本（裁静音 / 淡变 / 响度参数的指纹）；测试里改它模拟「整形参数升级」。
  @override
  String shapeVersion = 'shape-a';

  @override
  Future<int> synthesizeLine({
    required String voice,
    required int seed,
    required List<String> segments,
    required String outputPath,
    required TtsRenderCancelToken cancel,
  }) async {
    onSynthesize?.call(segments.join());
    cancel.throwIfCancelled();
    synthCalls.add('$voice|$seed|${segments.join('/')}');
    if (failVoices.contains(voice)) {
      throw const TtsFailure(TtsFailureCode.rejected, 'HTTP 422');
    }
    await File(outputPath).writeAsString('$voice|$seed|${segments.join()}');
    return 1000 + segments.join().length;
  }

  @override
  Future<int> cutClip({
    required MangaAudiobookClip clip,
    required String outputPath,
    required TtsRenderCancelToken cancel,
  }) async {
    clipCalls++;
    await File(outputPath).writeAsString('clip');
    return clip.durationMs;
  }

  @override
  Future<int> writeSilence({
    required int ms,
    required String outputPath,
  }) async {
    await File(outputPath).writeAsString('silence $ms');
    return ms;
  }

  /// 每次整形本地音频收到的源文件名；源文件内容是 `bad` 时整形失败。
  final List<String> localCalls = <String>[];

  @override
  Future<int> shapeLocalAudio({
    required String sourcePath,
    required String outputPath,
    required TtsRenderCancelToken cancel,
  }) async {
    localCalls.add(p.basename(sourcePath));
    if (await File(sourcePath).readAsString() == 'bad') {
      throw const MangaLineFailure('encode_failed');
    }
    await File(outputPath).writeAsString('local ${p.basename(sourcePath)}');
    return 2000 + localCalls.length;
  }
}

void main() {
  group('生成计划', () {
    test('不读类型不进计划；文字取 OCR，手填优先；声音逐级回落到当前朗读声音', () {
      final MangaAudioScript script = MangaAudioScript(
        defaultSeed: 7,
        voices: CastVoiceAssignment(byCharacter: <String, String>{'B': 'vb'}),
        lines: <MangaScriptLine>[
          _line(0, <int>[0]),
          _line(0, <int>[1], speaker: 'B', say: '手で書いた'),
          _line(2, <int>[0], kind: CastLineKind.skip),
          _line(2, <int>[0], voice: 'solo', seed: 3),
        ],
      )..series = CastVoiceAssignment(defaultVoice: 'series-default');
      final MangaRenderPlan plan = planMangaRender(
        script: script,
        pageBlocks: _pages(),
        defaultVoice: 'reading',
      );
      expect(plan.items.map((MangaRenderItem i) => i.lineId), <String>[
        'p0b0',
        'p0b1',
        'p2b0',
      ]);
      expect(plan.items[0].text, 'おはよう。');
      expect(plan.items[0].voiceTag, 'series-default');
      expect(plan.items[0].seed, 7);
      expect(plan.items[1].text, '手で書いた');
      expect(plan.items[1].voiceTag, 'vb');
      expect(plan.items[2].voiceTag, 'solo');
      expect(plan.items[2].seed, 3);

      final MangaRenderPlan bare = planMangaRender(
        script: MangaAudioScript(
          lines: <MangaScriptLine>[
            _line(0, <int>[0]),
          ],
        ),
        pageBlocks: _pages(),
        defaultVoice: 'reading',
      );
      expect(bare.items.single.voiceTag, 'reading');
    });

    test('音源策略：有声书片段需要关联有声书；只用有声书时没命中的句子不读', () {
      const MangaAudiobookClip clip = MangaAudiobookClip(
        fileIndex: 1,
        startMs: 100,
        endMs: 900,
      );
      MangaRenderPlan planWith(MangaAudioSourcePolicy policy, String? book) =>
          planMangaRender(
            script: MangaAudioScript(
              sourcePolicy: policy,
              audiobookSources: <String>[?book],
              lines: <MangaScriptLine>[
                _line(0, <int>[0], audio: clip),
                _line(0, <int>[1]),
              ],
            ),
            pageBlocks: _pages(),
            defaultVoice: 'reading',
          );

      final MangaRenderPlan first = planWith(
        MangaAudioSourcePolicy.audiobookFirst,
        'novel-1',
      );
      expect(first.items[0].source, isA<MangaRenderClip>());
      expect(first.items[0].voiceTag, 'audiobook:novel-1#1:100-900');
      expect(first.items[0].assignedVoice, isNull);
      expect(first.items[1].source, isA<MangaRenderSynth>());

      final MangaRenderPlan only = planWith(
        MangaAudioSourcePolicy.audiobookOnly,
        'novel-1',
      );
      expect(only.items.single.lineId, 'p0b0');
      expect(only.notRead, <String>['p0b1']);

      final MangaRenderPlan synth = planWith(
        MangaAudioSourcePolicy.synthOnly,
        'novel-1',
      );
      expect(
        synth.items.every((MangaRenderItem i) => i.source is MangaRenderSynth),
        isTrue,
      );

      final MangaRenderPlan unlinked = planWith(
        MangaAudioSourcePolicy.audiobookFirst,
        null,
      );
      expect(unlinked.items[0].source, isA<MangaRenderSynth>());
    });

    test('长台词按句末切成 ≤70 字的片段；页码越界的行单独列出', () {
      final String long = '${'あ' * 50}。${'い' * 50}。';
      final MangaRenderPlan plan = planMangaRender(
        script: MangaAudioScript(
          lines: <MangaScriptLine>[
            _line(0, <int>[0], say: long),
            _line(9, <int>[0]),
          ],
        ),
        pageBlocks: _pages(),
        defaultVoice: 'v',
      );
      final MangaRenderSynth synth =
          plan.items.single.source as MangaRenderSynth;
      expect(synth.segments, <String>['${'あ' * 50}。', '${'い' * 50}。']);
      expect(
        synth.segments.every((String s) => s.length <= kMangaSegmentMaxChars),
        isTrue,
      );
      expect(plan.outOfRange, <String>['p9b0']);
    });

    test('文件名按行身份', () {
      expect(mangaLineFileName('p3b1.2'), 'p3b1.2.m4a');
      expect(mangaPlaceholderFileName('p3b1.2'), 'p3b1.2.ph.wav');
      expect(mangaCandidateFileName('p3b1.2', 42), 'p3b1.2.s42.m4a');
    });
  });

  group('整卷生成', () {
    late Directory tmp;
    late _FakeBackend backend;
    late MangaAudioRenderer renderer;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('manga_renderer_test_');
      backend = _FakeBackend();
      renderer = MangaAudioRenderer(
        backend: backend,
        manifestFile: MangaRenderManifest.fileFor(tmp, 'vol-1'),
        now: () => DateTime.fromMillisecondsSinceEpoch(1000),
      );
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    MangaAudioScript script0() => MangaAudioScript(
      defaultSeed: 5,
      voices: CastVoiceAssignment(
        byCharacter: <String, String>{'B': 'bad'},
        retryVoices: <String>['bad', 'alt1', 'alt2'],
      ),
      lines: <MangaScriptLine>[
        _line(0, <int>[0]),
        _line(0, <int>[1], speaker: 'B'),
        _line(2, <int>[0]),
      ],
    );

    Future<MangaRenderOutcome> run(
      MangaAudioScript script,
      CastVoicingLedger ledger, {
      MangaRenderManifest? previous,
      TtsRenderCancelToken? cancel,
    }) => renderer.render(
      script: script,
      pageBlocks: _pages(),
      defaultVoice: 'reading',
      previous: previous,
      ledger: ledger,
      onProgress: (int done, int total) {},
      cancel: cancel ?? TtsRenderCancelToken(),
    );

    test('一句合成失败：写占位静音、记账，整卷照常完成，清单可读回', () async {
      backend.failVoices.add('bad');
      final CastVoicingLedger ledger = CastVoicingLedger();
      final MangaRenderOutcome out = await run(script0(), ledger);

      expect(out.produced, 2);
      expect(out.placeholders, <String>['p0b1']);
      final MangaRenderedLine ph = out.manifest.lines[1];
      expect(ph.placeholder, isTrue);
      expect(ph.file, 'p0b1.ph.wav');
      expect(ph.durationMs, estimatePlaceholderMs('元気？'));
      expect(
        File(p.join(renderer.directory.path, ph.file)).existsSync(),
        isTrue,
      );
      expect(out.manifest.lines[0].file, 'p0b0.m4a');
      expect(out.manifest.lines[0].voice, 'reading');
      expect(out.manifest.lines[0].seed, 5);

      final CastVoicingEntry entry = ledger.entries['p0b1']!;
      expect(entry.attempts.single.voice, 'bad');
      expect(entry.attempts.single.code, 'tts_rejected');
      expect(entry.attempts.single.detail, 'HTTP 422');

      final MangaRenderManifest? loaded = await MangaRenderManifest.load(
        renderer.manifestFile,
      );
      expect(loaded!.lines.length, 3);
      expect(loaded.placeholderCount, 1);
      expect(loaded.pageCount, 3);
    });

    test('没有可念文字的句子记成未配音（可手动填写补回）', () async {
      final CastVoicingLedger ledger = CastVoicingLedger();
      final MangaRenderOutcome out = await run(
        MangaAudioScript(
          lines: <MangaScriptLine>[
            _line(1, <int>[0]),
          ],
        ),
        ledger,
      );
      expect(out.placeholders, <String>['p1b0']);
      expect(ledger.entries['p1b0']!.lastAttempt!.code, 'empty_text');
      expect(backend.synthCalls, isEmpty);
    });

    test('纯标点气泡（「……」「！」）出一段停顿：不送引擎、不算未配音，重跑沿用', () async {
      final List<List<MokuroBlock>> pages = <List<MokuroBlock>>[
        <MokuroBlock>[_block('……'), _block('！'), _block('……はい')],
      ];
      final MangaAudioScript script = MangaAudioScript(
        lines: <MangaScriptLine>[
          _line(0, <int>[0]),
          _line(0, <int>[1]),
          _line(0, <int>[2]),
        ],
      );
      final CastVoicingLedger ledger = CastVoicingLedger();
      Future<MangaRenderOutcome> go(MangaRenderManifest? previous) =>
          renderer.render(
            script: script,
            pageBlocks: pages,
            defaultVoice: 'reading',
            previous: previous,
            ledger: ledger,
            onProgress: (int done, int total) {},
            cancel: TtsRenderCancelToken(),
          );

      final MangaRenderOutcome out = await go(null);
      // 只有带可念文字的那句进引擎。
      expect(backend.synthCalls, <String>['reading|0|……はい']);
      expect(out.placeholders, isEmpty);
      expect(ledger.entries, isEmpty);
      final MangaRenderedLine dots = out.manifest.lines[0];
      expect(dots.placeholder, isFalse);
      expect(dots.file, 'p0b0.wav');
      expect(dots.durationMs, estimatePlaceholderMs('……'));
      expect(
        File(p.join(renderer.directory.path, dots.file)).readAsStringSync(),
        'silence ${estimatePlaceholderMs('……')}',
      );
      expect(out.manifest.lines[1].file, 'p0b1.wav');
      expect(out.manifest.lines[2].file, 'p0b2.m4a');

      final MangaRenderOutcome again = await go(out.manifest);
      expect(again.reused, 3);
      expect(again.produced, 0);
      expect(backend.synthCalls, hasLength(1));
    });

    test('重跑：没变的句子沿用；改了文字的重录；占位句再试一次，成功后出账', () async {
      backend.failVoices.add('bad');
      final CastVoicingLedger ledger = CastVoicingLedger();
      final MangaRenderOutcome first = await run(script0(), ledger);
      backend.synthCalls.clear();
      backend.failVoices.clear();

      final MangaAudioScript changed = script0();
      changed.replaceLine('p2b0', (MangaScriptLine l) => l.copyWith(say: '改'));
      changed.replaceLine(
        'p0b0',
        (MangaScriptLine l) => l.copyWith(speaker: 'C'),
      );
      final MangaRenderOutcome second = await run(
        changed,
        ledger,
        previous: first.manifest,
      );
      expect(second.reused, 1);
      expect(second.produced, 2);
      // 整批交给后端的只有要新出的两句（沿用的 p0b0 不进批）。
      expect(backend.prepared.last, <String>['p0b1', 'p2b0']);
      expect(backend.synthCalls, <String>['bad|5|元気？', 'reading|5|改']);
      expect(second.manifest.lines[0].speaker, 'C');
      expect(second.placeholders, isEmpty);
      expect(ledger.isEmpty, isTrue);
      // 被取代的占位文件被清掉。
      expect(
        File(p.join(renderer.directory.path, 'p0b1.ph.wav')).existsSync(),
        isFalse,
      );
    });

    group('整形版本（HBK-AUDIT-038）', () {
      // 第 0 页第一句剪有声书（真人片段），第 2 页那句合成：存量演出重生成时两种音源都
      // 必须跟着整形版本走，不能旧片段原样保留、新合成句却用新处理。
      MangaAudioScript mixed() => MangaAudioScript(
        audiobookSources: <String>['novel'],
        lines: <MangaScriptLine>[
          _line(
            0,
            <int>[0],
            audio: const MangaAudiobookClip(
              fileIndex: 0,
              startMs: 0,
              endMs: 1500,
            ),
          ),
          _line(2, <int>[0]),
        ],
      );

      test('清单行记整形版本并随 JSON 往返；占位静音不记', () async {
        backend.failVoices.add('reading');
        final MangaRenderOutcome out = await run(mixed(), CastVoicingLedger());
        expect(out.manifest.lines[0].shape, 'shape-a');
        expect(out.manifest.lines[1].placeholder, isTrue);
        expect(out.manifest.lines[1].shape, isNull);
        final MangaRenderManifest back = (await MangaRenderManifest.load(
          renderer.manifestFile,
        ))!;
        expect(back.lines[0].shape, 'shape-a');
        expect(back.lines[1].shape, isNull);
      });

      test('历史清单（行里没有整形版本）：有声书片段与合成句都按版本不符重出', () async {
        final MangaRenderOutcome first = await run(
          mixed(),
          CastVoicingLedger(),
        );
        // 把清单降成整形版本出现之前的样子：行里没有 `shape`。
        final Map<String, Object?> json = first.manifest.toJson();
        for (final Object? l in json['lines']! as List<Object?>) {
          (l! as Map<String, Object?>).remove('shape');
        }
        final MangaRenderManifest legacy = MangaRenderManifest.fromJson(json)!;
        expect(legacy.lines.map((MangaRenderedLine l) => l.shape), <Object?>[
          null,
          null,
        ]);
        backend.synthCalls.clear();
        backend.clipCalls = 0;

        final MangaRenderOutcome second = await run(
          mixed(),
          CastVoicingLedger(),
          previous: legacy,
        );
        expect(second.reused, 0);
        expect(second.produced, 2);
        expect(backend.clipCalls, 1);
        expect(backend.synthCalls, <String>['reading|0|またね']);
        expect(backend.prepared.last, <String>['p0b0', 'p2b0']);
        expect(
          second.manifest.lines.map((MangaRenderedLine l) => l.shape),
          <String>['shape-a', 'shape-a'],
        );
      });

      test('现代清单：整形版本相同就沿用；版本变了两种音源都重出并记新版本', () async {
        final MangaRenderOutcome first = await run(
          mixed(),
          CastVoicingLedger(),
        );
        backend.synthCalls.clear();
        backend.clipCalls = 0;

        final MangaRenderOutcome same = await run(
          mixed(),
          CastVoicingLedger(),
          previous: first.manifest,
        );
        expect(same.reused, 2);
        expect(same.produced, 0);
        expect(backend.clipCalls, 0);
        expect(backend.synthCalls, isEmpty);

        backend.shapeVersion = 'shape-b';
        final MangaRenderOutcome upgraded = await run(
          mixed(),
          CastVoicingLedger(),
          previous: same.manifest,
        );
        expect(upgraded.reused, 0);
        expect(upgraded.produced, 2);
        expect(backend.clipCalls, 1);
        expect(backend.synthCalls, <String>['reading|0|またね']);
        expect(
          upgraded.manifest.lines.map((MangaRenderedLine l) => l.shape),
          <String>['shape-b', 'shape-b'],
        );
      });

      test('补回与保留候选写进当时的整形版本', () async {
        backend.failVoices.add('reading');
        final CastVoicingLedger ledger = CastVoicingLedger();
        final MangaAudioScript script = mixed();
        final MangaRenderOutcome out = await run(script, ledger);
        backend.failVoices.clear();
        backend.shapeVersion = 'shape-b';
        await renderer.backfill(
          script: script,
          pageBlocks: _pages(),
          defaultVoice: 'reading',
          manifest: out.manifest,
          ledger: ledger,
          requests: const <MangaBackfillRequest>[
            MangaBackfillRequest(lineId: 'p2b0'),
          ],
          onProgress: (int done, int total) {},
          cancel: TtsRenderCancelToken(),
        );
        expect(out.manifest.lines[1].shape, 'shape-b');

        backend.shapeVersion = 'shape-c';
        final MangaRegenerateCandidate c = await renderer.regenerate(
          script: script,
          pageBlocks: _pages(),
          defaultVoice: 'reading',
          lineId: 'p2b0',
          seed: 42,
          cancel: TtsRenderCancelToken(),
        );
        expect(c.shape, 'shape-c');
        await renderer.keepCandidate(
          script: script,
          manifest: out.manifest,
          ledger: ledger,
          candidate: c,
        );
        expect(out.manifest.lines[1].shape, 'shape-c');
      });
    });

    test('有声书片段走剪辑；关联的有声书剪不出来时这句占位', () async {
      final MangaAudioScript script = MangaAudioScript(
        audiobookSources: <String>['novel'],
        lines: <MangaScriptLine>[
          _line(
            0,
            <int>[0],
            audio: const MangaAudiobookClip(
              fileIndex: 0,
              startMs: 0,
              endMs: 1500,
            ),
          ),
        ],
      );
      final MangaRenderOutcome out = await run(script, CastVoicingLedger());
      expect(backend.clipCalls, 1);
      expect(backend.synthCalls, isEmpty);
      expect(out.manifest.lines.single.durationMs, 1500);
      expect(out.manifest.lines.single.voice, 'audiobook:novel#0:0-1500');
    });

    group('克隆旁白', () {
      // 第 0 页第一句剪有声书（4 s，够当参考），第二句（B）合成，第 2 页那句单句指定声音。
      MangaAudioScript mixed() => MangaAudioScript(
        voices: CastVoiceAssignment(byCharacter: <String, String>{'B': 'vb'}),
        audiobookSources: <String>['novel'],
        lines: <MangaScriptLine>[
          _line(
            0,
            <int>[0],
            audio: const MangaAudiobookClip(
              bookKey: 'novel',
              fileIndex: 0,
              startMs: 1000,
              endMs: 5000,
            ),
          ),
          _line(0, <int>[1], speaker: 'B'),
          _line(2, <int>[0], voice: 'solo'),
        ],
      );

      String narratorId(MangaAudioScript s) =>
          mangaNarratorFor(script: s, pageCount: _pages().length)!.id;

      test('能克隆：没单句指定声音的合成句改用旁白，单句指定的不改，清单记旁白 id', () async {
        backend.canCloneNarrator = true;
        final MangaAudioScript script = mixed();
        final String id = narratorId(script);
        final MangaRenderOutcome out = await run(script, CastVoicingLedger());
        expect(backend.narratorPrepared, <String>[id]);
        expect(backend.clipCalls, 1);
        expect(backend.synthCalls, <String>['$id|0|元気？', 'solo|0|またね']);
        expect(out.manifest.lines[1].voice, id);
      });

      test('参考音频准备失败 / 后端不能克隆：合成句照旧用各自指派的声音', () async {
        backend.canCloneNarrator = true;
        backend.narratorReady = false;
        await run(mixed(), CastVoicingLedger());
        expect(backend.synthCalls.first, startsWith('vb|'));

        final _FakeBackend plain = _FakeBackend();
        await MangaAudioRenderer(
          backend: plain,
          manifestFile: MangaRenderManifest.fileFor(tmp, 'vol-2'),
        ).render(
          script: mixed(),
          pageBlocks: _pages(),
          defaultVoice: 'reading',
          previous: null,
          ledger: CastVoicingLedger(),
          onProgress: (int done, int total) {},
          cancel: TtsRenderCancelToken(),
        );
        expect(plain.narratorPrepared, isEmpty);
        expect(plain.synthCalls.first, startsWith('vb|'));
      });

      test('换种子重生成与补回都用旁白，补回不把旁白 id 写进演出稿', () async {
        backend.canCloneNarrator = true;
        final MangaAudioScript script = mixed();
        final String id = narratorId(script);
        backend.failVoices.add(id);
        final CastVoicingLedger ledger = CastVoicingLedger();
        final MangaRenderOutcome out = await run(script, ledger);
        expect(out.manifest.lines[1].placeholder, isTrue);

        backend.failVoices.clear();
        final MangaRegenerateCandidate c = await renderer.regenerate(
          script: script,
          pageBlocks: _pages(),
          defaultVoice: 'reading',
          lineId: 'p0b1',
          seed: 9,
          cancel: TtsRenderCancelToken(),
        );
        expect(c.voice, id);
        await renderer.discardCandidate(c);

        final Map<String, MangaBackfillStatus> r = await renderer.backfill(
          script: script,
          pageBlocks: _pages(),
          defaultVoice: 'reading',
          manifest: out.manifest,
          ledger: ledger,
          requests: const <MangaBackfillRequest>[
            MangaBackfillRequest(lineId: 'p0b1'),
          ],
          onProgress: (int d, int t) {},
          cancel: TtsRenderCancelToken(),
        );
        expect(r['p0b1'], MangaBackfillStatus.voiced);
        expect(out.manifest.lines[1].voice, id);
        expect(script.lineById('p0b1')!.voice, isNull);
      });
    });

    test('系列用词替换表：改念的文字与清单文本；手填念法不替换；改表后受影响的句子重做', () async {
      MangaAudioScript scriptWith(List<CastTextSubstitution> table) =>
          MangaAudioScript(
            lines: <MangaScriptLine>[
              _line(0, <int>[0]),
              _line(0, <int>[1], say: '元気？'),
              _line(2, <int>[0]),
            ],
          )..substitutions = table;
      const CastTextSubstitution rule = CastTextSubstitution(
        source: '元気',
        replacement: 'げんき',
      );
      const CastTextSubstitution morning = CastTextSubstitution(
        source: 'おはよう',
        replacement: 'お早う',
      );
      final CastVoicingLedger ledger = CastVoicingLedger();
      final MangaRenderOutcome first = await run(
        scriptWith(const <CastTextSubstitution>[rule, morning]),
        ledger,
      );
      // OCR 文字过表；用户手填的「元気？」原样念。
      expect(first.manifest.lines[0].text, 'お早う。');
      expect(first.manifest.lines[1].text, '元気？');
      expect(backend.synthCalls, <String>[
        'reading|0|お早う。',
        'reading|0|元気？',
        'reading|0|またね',
      ]);

      // 停用一条：只有文字变了的那句重做，其余沿用。
      backend.synthCalls.clear();
      final MangaRenderOutcome second = await run(
        scriptWith(const <CastTextSubstitution>[
          rule,
          CastTextSubstitution(
            source: 'おはよう',
            replacement: 'お早う',
            enabled: false,
          ),
        ]),
        ledger,
        previous: first.manifest,
      );
      expect(second.reused, 2);
      expect(backend.synthCalls, <String>['reading|0|おはよう。']);
      expect(second.manifest.lines[0].text, 'おはよう。');
    });

    test('人名读法只改合成文字：清单文本不变、读法改了的句子能定位并补回（TW9ete_FHX）', () async {
      MangaAudioScript scriptWith(List<CastTextSubstitution> table) =>
          MangaAudioScript(
            lines: <MangaScriptLine>[
              _line(0, <int>[0]),
              _line(0, <int>[1], say: 'おはよう'),
              _line(2, <int>[0]),
            ],
          )..substitutions = table;
      const CastTextSubstitution name = CastTextSubstitution.name(
        written: 'おはよう',
        reading: 'オハヨウ',
      );
      final CastVoicingLedger ledger = CastVoicingLedger();
      final MangaRenderOutcome first = await run(
        scriptWith(const <CastTextSubstitution>[]),
        ledger,
      );

      // 加了人名读法：之前出的音频按旧文字念 → 定位出来（手填念法那句不算）。
      final MangaAudioScript script = scriptWith(const <CastTextSubstitution>[
        name,
      ]);
      final List<MangaSpokenTextChange> changes = mangaSpokenTextChanges(
        script: script,
        pageBlocks: _pages(),
        manifest: first.manifest,
      );
      expect(
        <String>[
          for (final MangaSpokenTextChange c in changes) c.rendered.lineId,
        ],
        <String>['p0b0'],
      );
      expect(changes.single.spoken, 'オハヨウ。');

      backend.synthCalls.clear();
      final Map<String, MangaBackfillStatus> r = await renderer.backfill(
        script: script,
        pageBlocks: _pages(),
        defaultVoice: 'reading',
        manifest: first.manifest,
        ledger: ledger,
        requests: const <MangaBackfillRequest>[
          MangaBackfillRequest(lineId: 'p0b0'),
        ],
        onProgress: (int d, int t) {},
        cancel: TtsRenderCancelToken(),
      );
      expect(r['p0b0'], MangaBackfillStatus.voiced);
      expect(backend.synthCalls, <String>['reading|0|オハヨウ。']);
      // 显示文字（cue / 制卡）仍是原文，念的文字落进清单供下次比对。
      final MangaRenderedLine line0 = first.manifest.lines[0];
      expect(line0.text, 'おはよう。');
      expect(line0.spokenText, 'オハヨウ。');
      final MangaRenderManifest reloaded = (await MangaRenderManifest.load(
        renderer.manifestFile,
      ))!;
      expect(reloaded.lines[0].spokenText, 'オハヨウ。');
      expect(reloaded.lines[2].spoken, isNull);
      expect(
        mangaSpokenTextChanges(
          script: script,
          pageBlocks: _pages(),
          manifest: reloaded,
        ),
        isEmpty,
      );

      // 整卷重跑沿用全部（念的文字没变）；删掉读法后那句再重做。
      backend.synthCalls.clear();
      final MangaRenderOutcome again = await run(
        script,
        ledger,
        previous: reloaded,
      );
      expect(again.reused, 3);
      expect(backend.synthCalls, isEmpty);
      final MangaRenderOutcome reverted = await run(
        scriptWith(const <CastTextSubstitution>[]),
        ledger,
        previous: again.manifest,
      );
      expect(reverted.reused, 2);
      expect(backend.synthCalls, <String>['reading|0|おはよう。']);
    });

    test('取消原样抛出，不写清单', () async {
      final TtsRenderCancelToken cancel = TtsRenderCancelToken()..cancel();
      await expectLater(
        run(script0(), CastVoicingLedger(), cancel: cancel),
        throwsA(isA<TtsRenderCancelled>()),
      );
      expect(renderer.manifestFile.existsSync(), isFalse);
    });

    test('补回：切配置重试跳过失败过的声音，成功后声音写回演出稿、清单换真音频、出账', () async {
      backend.failVoices.addAll(<String>['bad', 'alt1']);
      final CastVoicingLedger ledger = CastVoicingLedger();
      final MangaAudioScript script = script0();
      final MangaRenderOutcome out = await run(script, ledger);

      // 第一次「切配置重试」：候选 bad（已失败）→ alt1（又失败）。
      Map<String, MangaBackfillStatus> r = await renderer.backfill(
        script: script,
        pageBlocks: _pages(),
        defaultVoice: 'reading',
        manifest: out.manifest,
        ledger: ledger,
        requests: const <MangaBackfillRequest>[
          MangaBackfillRequest(lineId: 'p0b1', nextRetryVoice: true),
        ],
        onProgress: (int d, int t) {},
        cancel: TtsRenderCancelToken(),
      );
      expect(r['p0b1'], MangaBackfillStatus.failed);
      expect(ledger.entries['p0b1']!.failedVoices, <String?>{'bad', 'alt1'});
      expect(script.lineById('p0b1')!.voice, isNull);

      // 第二次：alt2 成功。
      r = await renderer.backfill(
        script: script,
        pageBlocks: _pages(),
        defaultVoice: 'reading',
        manifest: out.manifest,
        ledger: ledger,
        requests: const <MangaBackfillRequest>[
          MangaBackfillRequest(lineId: 'p0b1', nextRetryVoice: true),
        ],
        onProgress: (int d, int t) {},
        cancel: TtsRenderCancelToken(),
      );
      expect(r['p0b1'], MangaBackfillStatus.voiced);
      expect(script.lineById('p0b1')!.voice, 'alt2');
      expect(ledger.isEmpty, isTrue);
      final MangaRenderedLine line = out.manifest.lines[1];
      expect(line.placeholder, isFalse);
      expect(line.file, 'p0b1.m4a');
      expect(line.voice, 'alt2');
      final MangaRenderManifest? saved = await MangaRenderManifest.load(
        renderer.manifestFile,
      );
      expect(saved!.placeholderCount, 0);
      expect(
        File(p.join(renderer.directory.path, 'p0b1.ph.wav')).existsSync(),
        isFalse,
      );

      // 之后整卷重跑：这句按单句声音沿用，不再失败。
      backend.synthCalls.clear();
      final MangaRenderOutcome again = await run(
        script,
        ledger,
        previous: out.manifest,
      );
      expect(again.reused, 3);
      expect(backend.synthCalls, isEmpty);
    });

    test('补回：候选都失败过 → 没有可换的声音；手动填写 + 指定声音成功后写回', () async {
      backend.failVoices.addAll(<String>['bad', 'alt1', 'alt2']);
      final CastVoicingLedger ledger = CastVoicingLedger();
      final MangaAudioScript script = script0();
      final MangaRenderOutcome out = await run(script, ledger);
      for (int i = 0; i < 2; i++) {
        await renderer.backfill(
          script: script,
          pageBlocks: _pages(),
          defaultVoice: 'reading',
          manifest: out.manifest,
          ledger: ledger,
          requests: const <MangaBackfillRequest>[
            MangaBackfillRequest(lineId: 'p0b1', nextRetryVoice: true),
          ],
          onProgress: (int d, int t) {},
          cancel: TtsRenderCancelToken(),
        );
      }
      Map<String, MangaBackfillStatus> r = await renderer.backfill(
        script: script,
        pageBlocks: _pages(),
        defaultVoice: 'reading',
        manifest: out.manifest,
        ledger: ledger,
        requests: const <MangaBackfillRequest>[
          MangaBackfillRequest(lineId: 'p0b1', nextRetryVoice: true),
        ],
        onProgress: (int d, int t) {},
        cancel: TtsRenderCancelToken(),
      );
      expect(r['p0b1'], MangaBackfillStatus.noRetryVoice);

      r = await renderer.backfill(
        script: script,
        pageBlocks: _pages(),
        defaultVoice: 'reading',
        manifest: out.manifest,
        ledger: ledger,
        requests: const <MangaBackfillRequest>[
          MangaBackfillRequest(lineId: 'p0b1', voice: 'reading', say: 'げんき'),
          MangaBackfillRequest(lineId: 'gone'),
        ],
        onProgress: (int d, int t) {},
        cancel: TtsRenderCancelToken(),
      );
      expect(r['p0b1'], MangaBackfillStatus.voiced);
      expect(r['gone'], MangaBackfillStatus.lineMissing);
      expect(script.lineById('p0b1')!.say, 'げんき');
      expect(script.lineById('p0b1')!.voice, 'reading');
      expect(out.manifest.lines[1].text, 'げんき');
    });

    test('单句换种子：保留后种子写回、换文件、删旧文件；撤回只删候选', () async {
      final CastVoicingLedger ledger = CastVoicingLedger();
      final MangaAudioScript script = script0()..voices.byCharacter.clear();
      final MangaRenderOutcome out = await run(script, ledger);

      final MangaRegenerateCandidate c1 = await renderer.regenerate(
        script: script,
        pageBlocks: _pages(),
        defaultVoice: 'reading',
        lineId: 'p2b0',
        seed: 99,
        cancel: TtsRenderCancelToken(),
      );
      expect(c1.file, 'p2b0.s99.m4a');
      expect(out.manifest.lines[2].file, 'p2b0.m4a');
      await renderer.discardCandidate(c1);
      expect(
        File(p.join(renderer.directory.path, c1.file)).existsSync(),
        isFalse,
      );

      final MangaRegenerateCandidate c2 = await renderer.regenerate(
        script: script,
        pageBlocks: _pages(),
        defaultVoice: 'reading',
        lineId: 'p2b0',
        seed: 100,
        cancel: TtsRenderCancelToken(),
      );
      expect(
        await renderer.keepCandidate(
          script: script,
          manifest: out.manifest,
          ledger: ledger,
          candidate: c2,
        ),
        isTrue,
      );
      expect(script.lineById('p2b0')!.seed, 100);
      expect(out.manifest.lines[2].file, 'p2b0.s100.m4a');
      expect(out.manifest.lines[2].seed, 100);
      expect(
        File(p.join(renderer.directory.path, 'p2b0.m4a')).existsSync(),
        isFalse,
      );

      // 重跑沿用保留的候选。
      backend.synthCalls.clear();
      final MangaRenderOutcome again = await run(
        script,
        ledger,
        previous: out.manifest,
      );
      expect(backend.synthCalls, isEmpty);
      expect(again.manifest.lines[2].file, 'p2b0.s100.m4a');
    });

    group('换上本地音频', () {
      /// 把 [content] 当作一段本地音频放进保留目录，返回它的音源。
      MangaLocalAudio stage(String sig, String content) {
        final MangaLocalAudio audio = MangaLocalAudio(
          sig: sig,
          ext: '.wav',
          name: '$sig.wav',
        );
        File(mangaLocalAudioSourcePath(renderer.directory.path, audio))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(content);
        return audio;
      }

      test('全部成功才换：清单 / 演出稿 / 账本一起改、旧文件清掉；重跑沿用，整形版本变了从保留副本重整形', () async {
        final CastVoicingLedger ledger = CastVoicingLedger();
        final MangaAudioScript script = script0();
        backend.failVoices.add('bad');
        final MangaRenderOutcome out = await run(script, ledger);
        expect(ledger.entries.keys, <String>['p0b1']);
        final MangaLocalAudio a = stage('aaaaaaaaaaaaaaaa', 'wav-a');
        final MangaLocalAudio b = stage('bbbbbbbbbbbbbbbb', 'wav-b');

        final MangaLocalBindOutcome bound = await renderer.bindLocalAudio(
          script: script,
          manifest: out.manifest,
          ledger: ledger,
          bindings: <String, MangaLocalAudio>{'p0b1': a, 'p2b0': b},
          cancel: TtsRenderCancelToken(),
        );
        expect(bound.ok, isTrue);
        expect(bound.bound.keys, unorderedEquals(<String>['p0b1', 'p2b0']));
        final MangaRenderedLine l1 = out.manifest.lines[1];
        expect(l1.file, 'p0b1.faaaaaaaaaaaaaaaa.m4a');
        expect(l1.voice, 'file:aaaaaaaaaaaaaaaa');
        expect(l1.placeholder, isFalse);
        expect(l1.seed, isNull);
        expect(l1.shape, 'shape-a');
        expect(l1.durationMs, bound.bound['p0b1']);
        expect(script.lineById('p0b1')!.audio, a);
        expect(ledger.entries, isEmpty);
        expect(
          File(p.join(renderer.directory.path, 'p2b0.m4a')).existsSync(),
          isFalse,
        );
        final MangaRenderManifest? saved = await MangaRenderManifest.load(
          renderer.manifestFile,
        );
        expect(saved!.lines[2].voice, 'file:bbbbbbbbbbbbbbbb');

        // 演出稿往返：音源保留。
        final MangaScriptLine back = MangaScriptLine.fromJson(
          script.lineById('p0b1')!.toJson(),
        )!;
        expect(back.audio, a);
        expect(back.audio.byUser, isTrue);

        // 同一段再绑一次：原样不动。
        final MangaLocalBindOutcome again = await renderer.bindLocalAudio(
          script: script,
          manifest: out.manifest,
          ledger: ledger,
          bindings: <String, MangaLocalAudio>{'p0b1': a},
          cancel: TtsRenderCancelToken(),
        );
        expect(again.unchanged, <String>{'p0b1'});
        expect(backend.localCalls.length, 2);

        // 重跑：本地音频的句子沿用，不合成、不重整形。
        backend.synthCalls.clear();
        final MangaRenderOutcome rerun = await run(
          script,
          ledger,
          previous: out.manifest,
        );
        expect(backend.localCalls.length, 2);
        expect(rerun.manifest.lines[1].file, 'p0b1.faaaaaaaaaaaaaaaa.m4a');
        expect(backend.synthCalls, isEmpty);

        // 整形版本变了：从保留副本重整形（用户原文件在不在都无妨）。
        backend.shapeVersion = 'shape-b';
        final MangaRenderOutcome reshaped = await run(
          script,
          ledger,
          previous: rerun.manifest,
        );
        expect(backend.localCalls.length, 4);
        expect(reshaped.manifest.lines[1].voice, 'file:aaaaaaaaaaaaaaaa');
        expect(reshaped.manifest.lines[1].shape, 'shape-b');
        expect(reshaped.manifest.lines[1].placeholder, isFalse);
      });

      test('有一句失败：什么都不改，这次出的文件删掉', () async {
        final CastVoicingLedger ledger = CastVoicingLedger();
        final MangaAudioScript script = script0();
        final MangaRenderOutcome out = await run(script, ledger);
        final String before = await renderer.manifestFile.readAsString();
        final MangaLocalAudio a = stage('aaaaaaaaaaaaaaaa', 'wav-a');
        final MangaLocalAudio bad = stage('cccccccccccccccc', 'bad');

        final MangaLocalBindOutcome r = await renderer.bindLocalAudio(
          script: script,
          manifest: out.manifest,
          ledger: ledger,
          bindings: <String, MangaLocalAudio>{
            'p0b0': a,
            'p2b0': bad,
            'nope': a,
          },
          cancel: TtsRenderCancelToken(),
        );
        expect(r.ok, isFalse);
        expect(r.bound, isEmpty);
        expect(r.failures['p2b0']!.code, 'encode_failed');
        expect(r.failures['nope']!.code, 'line_missing');
        expect(await renderer.manifestFile.readAsString(), before);
        expect(out.manifest.lines[0].file, 'p0b0.m4a');
        expect(script.lineById('p0b0')!.audio, const MangaSynthesized());
        expect(
          File(
            p.join(renderer.directory.path, 'p0b0.faaaaaaaaaaaaaaaa.m4a'),
          ).existsSync(),
          isFalse,
        );
      });

      test('换种子重生成换回合成并清掉保留副本；保留副本丢了又要重整形时这句占位、记账', () async {
        final CastVoicingLedger ledger = CastVoicingLedger();
        final MangaAudioScript script = script0()..voices.byCharacter.clear();
        final MangaRenderOutcome out = await run(script, ledger);
        final MangaLocalAudio a = stage('aaaaaaaaaaaaaaaa', 'wav-a');
        await renderer.bindLocalAudio(
          script: script,
          manifest: out.manifest,
          ledger: ledger,
          bindings: <String, MangaLocalAudio>{'p2b0': a},
          cancel: TtsRenderCancelToken(),
        );
        final File kept = File(
          mangaLocalAudioSourcePath(renderer.directory.path, a),
        );
        expect(kept.existsSync(), isTrue);

        final MangaRegenerateCandidate c = await renderer.regenerate(
          script: script,
          pageBlocks: _pages(),
          defaultVoice: 'reading',
          lineId: 'p2b0',
          seed: 7,
          cancel: TtsRenderCancelToken(),
        );
        await renderer.keepCandidate(
          script: script,
          manifest: out.manifest,
          ledger: ledger,
          candidate: c,
        );
        expect(script.lineById('p2b0')!.audio, const MangaSynthesized());
        expect(out.manifest.lines[2].voice, 'reading');
        expect(kept.existsSync(), isFalse);

        final MangaLocalAudio b = stage('bbbbbbbbbbbbbbbb', 'wav-b');
        await renderer.bindLocalAudio(
          script: script,
          manifest: out.manifest,
          ledger: ledger,
          bindings: <String, MangaLocalAudio>{'p2b0': b},
          cancel: TtsRenderCancelToken(),
        );
        File(
          mangaLocalAudioSourcePath(renderer.directory.path, b),
        ).deleteSync();
        backend.shapeVersion = 'shape-b';
        final MangaRenderOutcome rerun = await run(
          script,
          ledger,
          previous: out.manifest,
        );
        expect(rerun.manifest.lines[2].placeholder, isTrue);
        expect(
          ledger.entries['p2b0']!.lastAttempt!.code,
          'local_audio_missing',
        );
      });
    });

    test('补回带种子 = 换种子重出已生成的句子：新文件、种子写回；失败保留旧音频、不记账', () async {
      final CastVoicingLedger ledger = CastVoicingLedger();
      final MangaAudioScript script = script0()..voices.byCharacter.clear();
      final MangaRenderOutcome out = await run(script, ledger);
      backend.prepared.clear();

      final Map<String, MangaBackfillStatus> r = await renderer.backfill(
        script: script,
        pageBlocks: _pages(),
        defaultVoice: 'reading',
        manifest: out.manifest,
        ledger: ledger,
        requests: const <MangaBackfillRequest>[
          MangaBackfillRequest(lineId: 'p0b0', seed: 41),
          MangaBackfillRequest(lineId: 'p2b0', seed: 42),
        ],
        onProgress: (int done, int total) {},
        cancel: TtsRenderCancelToken(),
      );
      expect(r.values, everyElement(MangaBackfillStatus.voiced));
      expect(backend.prepared.single, <String>['p0b0', 'p2b0']);
      expect(out.manifest.lines[0].file, 'p0b0.s41.m4a');
      expect(out.manifest.lines[0].seed, 41);
      expect(script.lineById('p2b0')!.seed, 42);
      expect(
        File(p.join(renderer.directory.path, 'p0b0.m4a')).existsSync(),
        isFalse,
      );

      backend.failVoices.add('reading');
      final Map<String, MangaBackfillStatus> failed = await renderer.backfill(
        script: script,
        pageBlocks: _pages(),
        defaultVoice: 'reading',
        manifest: out.manifest,
        ledger: ledger,
        requests: const <MangaBackfillRequest>[
          MangaBackfillRequest(lineId: 'p0b0', seed: 43),
        ],
        onProgress: (int done, int total) {},
        cancel: TtsRenderCancelToken(),
      );
      expect(failed['p0b0'], MangaBackfillStatus.failed);
      expect(out.manifest.lines[0].file, 'p0b0.s41.m4a');
      expect(script.lineById('p0b0')!.seed, 41);
      expect(ledger.entries.containsKey('p0b0'), isFalse);
    });

    test('合成失败的单句重生成抛出一句级失败', () async {
      backend.failVoices.add('reading');
      await expectLater(
        renderer.regenerate(
          script: MangaAudioScript(
            lines: <MangaScriptLine>[
              _line(0, <int>[0]),
            ],
          ),
          pageBlocks: _pages(),
          defaultVoice: 'reading',
          lineId: 'p0b0',
          seed: 1,
          cancel: TtsRenderCancelToken(),
        ),
        throwsA(
          isA<MangaLineFailure>().having(
            (MangaLineFailure f) => f.code,
            'code',
            'tts_rejected',
          ),
        ),
      );
    });

    group('成品与清单一起提交（HBK-AUDIT-201 / 207 / 214）', () {
      String read(String file) =>
          File(p.join(renderer.directory.path, file)).readAsStringSync();

      bool exists(String file) =>
          File(p.join(renderer.directory.path, file)).existsSync();

      List<String> stagedLeft() => <String>[
        for (final FileSystemEntity e in renderer.directory.listSync())
          if (e is File && e.path.contains('.stage.')) p.basename(e.path),
      ];

      MangaLocalAudio keep(String sig, String name, String content) {
        final MangaLocalAudio audio = MangaLocalAudio(
          sig: sig,
          ext: '.wav',
          name: name,
        );
        File(mangaLocalAudioSourcePath(renderer.directory.path, audio))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(content);
        return audio;
      }

      test('同一段音频改名后再绑回原句、同批另一句整形失败：旧成品文件与清单都完好', () async {
        final CastVoicingLedger ledger = CastVoicingLedger();
        final MangaAudioScript script = script0()..voices.byCharacter.clear();
        final MangaRenderOutcome out = await run(script, ledger);
        final MangaLocalAudio a = keep(
          'aaaaaaaaaaaaaaaa',
          'take1.wav',
          'wav-a',
        );
        expect(
          (await renderer.bindLocalAudio(
            script: script,
            manifest: out.manifest,
            ledger: ledger,
            bindings: <String, MangaLocalAudio>{'p0b0': a},
            cancel: TtsRenderCancelToken(),
          )).ok,
          isTrue,
        );
        const String live = 'p0b0.faaaaaaaaaaaaaaaa.m4a';
        final String liveBytes = read(live);
        final String manifestBefore = await renderer.manifestFile
            .readAsString();

        // 同字节换了文件名：演出稿里的音源不再相等，这句要重新整形（目标还是 [live]）。
        final MangaLocalAudio renamed = keep(
          'aaaaaaaaaaaaaaaa',
          'renamed.wav',
          'wav-a',
        );
        final MangaLocalAudio bad = keep('cccccccccccccccc', 'bad.wav', 'bad');
        final MangaLocalBindOutcome r = await renderer.bindLocalAudio(
          script: script,
          manifest: out.manifest,
          ledger: ledger,
          bindings: <String, MangaLocalAudio>{'p0b0': renamed, 'p2b0': bad},
          cancel: TtsRenderCancelToken(),
        );
        expect(r.ok, isFalse);
        expect(r.failures.keys, <String>['p2b0']);
        expect(exists(live), isTrue);
        expect(read(live), liveBytes);
        expect(await renderer.manifestFile.readAsString(), manifestBefore);
        expect(out.manifest.lines[0].file, live);
        expect(script.lineById('p0b0')!.audio, a);
        expect(stagedLeft(), isEmpty);
      });

      test('补回中途取消：已处理的句子音频、清单、演出稿、账本都保持旧版本', () async {
        final CastVoicingLedger ledger = CastVoicingLedger();
        final MangaAudioScript script = script0()..voices.byCharacter.clear();
        final MangaRenderOutcome out = await run(script, ledger);
        final String p0Before = read('p0b0.m4a');
        final String manifestBefore = await renderer.manifestFile
            .readAsString();
        final List<Map<String, Object?>> linesBefore = <Map<String, Object?>>[
          for (final MangaRenderedLine l in out.manifest.lines) l.toJson(),
        ];

        // 读法改了的两句（手填念法）排补回；合成到第二句时取消。
        final TtsRenderCancelToken cancel = TtsRenderCancelToken();
        backend.onSynthesize = (String text) {
          if (text == '二句目') cancel.cancel();
        };
        await expectLater(
          renderer.backfill(
            script: script,
            pageBlocks: _pages(),
            defaultVoice: 'reading',
            manifest: out.manifest,
            ledger: ledger,
            requests: const <MangaBackfillRequest>[
              MangaBackfillRequest(lineId: 'p0b0', say: '一句目'),
              MangaBackfillRequest(lineId: 'p2b0', say: '二句目'),
            ],
            onProgress: (int d, int t) {},
            cancel: cancel,
          ),
          throwsA(isA<TtsRenderCancelled>()),
        );
        expect(backend.synthCalls.last, 'reading|5|一句目');
        expect(read('p0b0.m4a'), p0Before);
        expect(await renderer.manifestFile.readAsString(), manifestBefore);
        expect(<Map<String, Object?>>[
          for (final MangaRenderedLine l in out.manifest.lines) l.toJson(),
        ], linesBefore);
        expect(script.lineById('p0b0')!.say, isNull);
        expect(stagedLeft(), isEmpty);
      });

      test('整卷重跑中途取消：旧清单引用的音频一个字节都不变', () async {
        final CastVoicingLedger ledger = CastVoicingLedger();
        backend.failVoices.add('bad');
        final MangaRenderOutcome out = await run(script0(), ledger);
        final String p0Before = read('p0b0.m4a');
        final String manifestBefore = await renderer.manifestFile
            .readAsString();
        backend.failVoices.clear();

        // 换了默认种子：三句都要重出；出到第三句时取消。
        final MangaAudioScript reseeded = script0()..defaultSeed = 6;
        final TtsRenderCancelToken cancel = TtsRenderCancelToken();
        backend.onSynthesize = (String text) {
          if (text == 'またね') cancel.cancel();
        };
        await expectLater(
          run(reseeded, ledger, previous: out.manifest, cancel: cancel),
          throwsA(isA<TtsRenderCancelled>()),
        );
        expect(read('p0b0.m4a'), p0Before);
        expect(exists('p0b1.ph.wav'), isTrue);
        expect(await renderer.manifestFile.readAsString(), manifestBefore);
        // 第二句这次其实配上了音，但没提交：账本里仍是未配音。
        expect(ledger.entries.keys, <String>['p0b1']);
        expect(stagedLeft(), isEmpty);
      });

      test('同一个种子再出一次候选后撤回：清单正在用的文件不被删', () async {
        final CastVoicingLedger ledger = CastVoicingLedger();
        final MangaAudioScript script = script0()..voices.byCharacter.clear();
        final MangaRenderOutcome out = await run(script, ledger);
        Future<MangaRegenerateCandidate> regen() => renderer.regenerate(
          script: script,
          pageBlocks: _pages(),
          defaultVoice: 'reading',
          lineId: 'p2b0',
          seed: 100,
          cancel: TtsRenderCancelToken(),
        );
        await renderer.keepCandidate(
          script: script,
          manifest: out.manifest,
          ledger: ledger,
          candidate: await regen(),
        );
        expect(out.manifest.lines[2].file, 'p2b0.s100.m4a');
        final String liveBytes = read('p2b0.s100.m4a');

        final MangaRegenerateCandidate again = await regen();
        expect(again.file, 'p2b0.s100.m4a');
        expect(again.stagedFile, isNot(again.file));
        expect(exists(again.stagedFile), isTrue);
        await renderer.discardCandidate(again);
        expect(read('p2b0.s100.m4a'), liveBytes);
        expect(exists(again.stagedFile), isFalse);
      });

      test('发布到一半换不上（目标被占用等）：已换上的还原，旧清单引用的音频不变', () async {
        final CastVoicingLedger ledger = CastVoicingLedger();
        backend.failVoices.add('bad');
        final MangaRenderOutcome out = await run(script0(), ledger);
        final String p0Before = read('p0b0.m4a');
        final String p2Before = read('p2b0.m4a');
        final String manifestBefore = await renderer.manifestFile
            .readAsString();
        backend.failVoices.clear();
        // 最后一句的目标挪不到备份名（那里是个目录）：发布在它这里失败。
        Directory(
          p.join(renderer.directory.path, 'p2b0.prev.m4a'),
        ).createSync();

        final MangaAudioScript reseeded = script0()..defaultSeed = 6;
        await expectLater(
          run(reseeded, ledger, previous: out.manifest),
          throwsA(isA<FileSystemException>()),
        );
        expect(read('p0b0.m4a'), p0Before);
        expect(read('p2b0.m4a'), p2Before);
        expect(exists('p0b1.m4a'), isFalse);
        expect(exists('p0b0.prev.m4a'), isFalse);
        expect(await renderer.manifestFile.readAsString(), manifestBefore);
        expect(ledger.entries.keys, <String>['p0b1']);
        expect(stagedLeft(), isEmpty);
      });

      test('候选等定夺时被别的操作清扫掉：保留返回 false，清单不挂上没有的文件', () async {
        final CastVoicingLedger ledger = CastVoicingLedger();
        final MangaAudioScript script = script0()..voices.byCharacter.clear();
        final MangaRenderOutcome out = await run(script, ledger);
        final String manifestBefore = await renderer.manifestFile
            .readAsString();
        final MangaRegenerateCandidate candidate = await renderer.regenerate(
          script: script,
          pageBlocks: _pages(),
          defaultVoice: 'reading',
          lineId: 'p2b0',
          seed: 100,
          cancel: TtsRenderCancelToken(),
        );
        await renderer.sweepUnreferenced(out.manifest);
        expect(exists(candidate.stagedFile), isFalse);

        expect(
          await renderer.keepCandidate(
            script: script,
            manifest: out.manifest,
            ledger: ledger,
            candidate: candidate,
          ),
          isFalse,
        );
        expect(out.manifest.lines[2].file, 'p2b0.m4a');
        expect(exists('p2b0.s100.m4a'), isFalse);
        expect(await renderer.manifestFile.readAsString(), manifestBefore);
      });

      test('改成「不读」的句子：不再单句合成 / 补回，从清单拿掉并清掉音频', () async {
        final CastVoicingLedger ledger = CastVoicingLedger();
        backend.failVoices.add('bad');
        final MangaAudioScript script = script0();
        final MangaRenderOutcome out = await run(script, ledger);
        script.replaceLine(
          'p0b1',
          (MangaScriptLine l) => l.copyWith(kind: CastLineKind.skip),
        );
        script.replaceLine(
          'p2b0',
          (MangaScriptLine l) => l.copyWith(kind: CastLineKind.skip),
        );
        backend.synthCalls.clear();

        await expectLater(
          renderer.regenerate(
            script: script,
            pageBlocks: _pages(),
            defaultVoice: 'reading',
            lineId: 'p2b0',
            seed: 9,
            cancel: TtsRenderCancelToken(),
          ),
          throwsA(
            isA<MangaLineFailure>().having(
              (MangaLineFailure f) => f.code,
              'code',
              'line_not_read',
            ),
          ),
        );
        final Map<String, MangaBackfillStatus> r = await renderer.backfill(
          script: script,
          pageBlocks: _pages(),
          defaultVoice: 'reading',
          manifest: out.manifest,
          ledger: ledger,
          requests: const <MangaBackfillRequest>[
            MangaBackfillRequest(lineId: 'p0b1', voice: 'alt1'),
          ],
          onProgress: (int d, int t) {},
          cancel: TtsRenderCancelToken(),
        );
        expect(r['p0b1'], MangaBackfillStatus.lineMissing);
        expect(backend.synthCalls, isEmpty);

        final List<String> dropped = await renderer.dropUnreadLines(
          script: script,
          manifest: out.manifest,
          ledger: ledger,
          lineIds: <String>['p0b0', 'p0b1', 'p2b0'],
        );
        expect(dropped, <String>['p0b1', 'p2b0']);
        expect(
          out.manifest.lines.map((MangaRenderedLine l) => l.lineId),
          <String>['p0b0'],
        );
        expect(ledger.entries, isEmpty);
        expect(exists('p2b0.m4a'), isFalse);
        expect(exists('p0b1.ph.wav'), isFalse);
        expect(exists('p0b0.m4a'), isTrue);
        final MangaRenderManifest? saved = await MangaRenderManifest.load(
          renderer.manifestFile,
        );
        expect(saved!.lines.map((MangaRenderedLine l) => l.lineId), <String>[
          'p0b0',
        ]);

        // 与整卷生成同一判据：重跑也不把它们放回来。
        final MangaRenderOutcome rerun = await run(
          script,
          ledger,
          previous: out.manifest,
        );
        expect(
          rerun.manifest.lines.map((MangaRenderedLine l) => l.lineId),
          <String>['p0b0'],
        );
      });
    });
  });

  group('制作队列里的漫画任务', () {
    test('任务类型与补回请求随清单往返；旧清单缺省是小说任务', () {
      final TtsRenderJob job = TtsRenderJob(
        id: '1',
        bookKey: 'vol',
        title: 't',
        presetId: 'reading',
        sections: const <int>[],
        verify: false,
        createdAt: 0,
        updatedAt: 0,
        kind: TtsRenderJobKind.manga,
        lineRequests: const <TtsRenderLineRequest>[
          TtsRenderLineRequest(lineId: 'p0b1', nextRetryVoice: true),
          TtsRenderLineRequest(lineId: 'p2b0', voice: 'v2', say: 'こんにちは'),
          TtsRenderLineRequest(lineId: 'p0b0', seed: 77),
        ],
      );
      final TtsRenderJob back = TtsRenderJob.fromJson(job.toJson());
      expect(back.kind, TtsRenderJobKind.manga);
      expect(back.lineRequests.length, 3);
      expect(back.lineRequests[2].seed, 77);
      expect(back.lineRequests[0].seed, isNull);
      expect(back.lineRequests[0].nextRetryVoice, isTrue);
      expect(back.lineRequests[1].voice, 'v2');
      expect(back.lineRequests[1].say, 'こんにちは');

      final Map<String, Object?> legacy = job.toJson()
        ..remove('kind')
        ..remove('lines');
      final TtsRenderJob old = TtsRenderJob.fromJson(legacy);
      expect(old.kind, TtsRenderJobKind.book);
      expect(old.lineRequests, isEmpty);
    });
  });

  group('演出参数', () {
    test('只保留引擎支持的字段；缓存身份只含生效字段', () {
      const TtsDirection wanted = TtsDirection(seed: 3, durationSeconds: 1.234);
      expect(
        effectiveTtsDirection(TtsDirectionSupport.none, wanted).isEmpty,
        isTrue,
      );
      final TtsDirection seedOnly = effectiveTtsDirection(
        const TtsDirectionSupport(seed: true),
        wanted,
      );
      expect(seedOnly.cacheIdentity, <String, Object?>{'seed': 3});
      expect(wanted.cacheIdentity['durationCs'], 123);
    });

    test('不支持演出参数的引擎走普通合成', () async {
      final _PlainProvider plain = _PlainProvider();
      await synthesizeWithDirection(
        plain,
        'x',
        outputPath: 'o',
        cancel: TtsCancelToken(),
        direction: const TtsDirection(seed: 1),
      );
      expect(plain.plainCalls, 1);
      expect(ttsDirectionSupportOf(plain).seed, isFalse);

      final _DirectedProvider directed = _DirectedProvider();
      await synthesizeWithDirection(
        directed,
        'x',
        outputPath: 'o',
        cancel: TtsCancelToken(),
        direction: const TtsDirection(seed: 1),
      );
      expect(directed.directedSeeds, <int?>[1]);
      expect(ttsDirectionSupportOf(directed).seed, isTrue);
    });
  });
}

class _PlainProvider extends TtsProvider {
  int plainCalls = 0;

  @override
  TtsCapabilities get capabilities => const TtsCapabilities(
    timing: TtsTimingGranularity.sentence,
    online: false,
    needsCredential: false,
  );

  @override
  Future<TtsResult> synthesize(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
  }) async {
    plainCalls++;
    return const TtsResult(format: TtsAudioFormat.wav);
  }
}

class _DirectedProvider extends _PlainProvider implements TtsDirectedSynthesis {
  final List<int?> directedSeeds = <int?>[];

  @override
  TtsDirectionSupport get directionSupport =>
      const TtsDirectionSupport(seed: true);

  @override
  Future<TtsResult> synthesizeDirected(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
    required TtsDirection direction,
  }) async {
    directedSeeds.add(direction.seed);
    return const TtsResult(format: TtsAudioFormat.wav);
  }
}
