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

  @override
  Future<int> synthesizeLine({
    required String voice,
    required int seed,
    required List<String> segments,
    required String outputPath,
    required TtsRenderCancelToken cancel,
  }) async {
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
        ],
      );
      final TtsRenderJob back = TtsRenderJob.fromJson(job.toJson());
      expect(back.kind, TtsRenderJobKind.manga);
      expect(back.lineRequests.length, 2);
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
