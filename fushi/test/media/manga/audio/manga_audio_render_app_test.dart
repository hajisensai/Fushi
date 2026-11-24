import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/audiobook_session.dart';
import 'package:fushi/src/media/audiobook/tts/cast/series_cast_resolver.dart';
import 'package:fushi/src/media/audiobook/tts/studio/audio_production_host.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_text.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_library.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_render_backend.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_render_service.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_stores.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/tts/cast/series_cast.dart';
import 'package:fushi_engine/tts/cast/cast_line_kind.dart';
import 'package:fushi_engine/tts/local/irodori_batch_worker.dart'
    show IrodoriBatchItem;
import 'package:fushi_engine/tts/local/irodori_voice_pack_provider.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_narrator.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_renderer.dart'
    show MangaRegenerateCandidate;
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart'
    show MangaAudiobookClip, MangaAudioScript, MangaScriptLine;
import 'package:fushi_engine/tts/render/tts_render_queue.dart'
    show TtsRenderFailure;
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:path/path.dart' as p;

Future<String> _insertBook(
  FushiDatabase db,
  String bookKey, {
  String format = 'manga',
}) async {
  await db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: bookKey,
      title: bookKey,
      epubPath: 'manga.json',
      extractDir: '/x/$bookKey',
      chapterCount: 1,
      chaptersJson: '[]',
      importedAt: 1000,
      format: Value<String>(format),
    ),
  );
  return (await db.resolveEpubBookUid(bookKey))!;
}

class _Session implements AudiobookSession {
  final List<String> stopped = <String>[];

  @override
  Future<void> stopIfPlayingAny(Iterable<String> bookKeys) async {
    stopped.addAll(bookKeys);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Host implements AudioProductionHost {
  _Host(this.database, this.databaseDirectory, this.audiobookSession);

  @override
  final FushiDatabase database;

  @override
  final Directory databaseDirectory;

  @override
  final AudiobookSession audiobookSession;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ffmpeg 参数', () {
    test('一句的各片段先统一格式再拼接，拼完裁首尾静音、归一响度，输出 m4a', () {
      final List<String> one = buildMangaLineEncodeArgs(
        inputs: <String>['a.wav'],
        outputPath: 'out.part',
      );
      final String graph1 = one[one.indexOf('-filter_complex') + 1];
      expect(graph1, startsWith('[0:a]aresample=44100'));
      expect(graph1, contains('[a0]concat=n=1:v=0:a=1[c];[c]silenceremove'));
      expect(
        graph1,
        endsWith('areverse,$kMangaLoudnessFilter,aresample=44100[out]'),
        reason: '响度归一在裁静音之后，loudnorm 升采样后要回到 44.1 kHz',
      );
      expect(graph1, isNot(contains('afade')), reason: '合成句不加淡入淡出');
      expect(one.sublist(one.length - 3), <String>['-f', 'mp4', 'out.part']);

      final List<String> two = buildMangaLineEncodeArgs(
        inputs: <String>['a.wav', 'b.mp3'],
        outputPath: 'o',
      );
      expect(two.where((String a) => a == '-i').length, 2, reason: '每个片段一个输入');
      expect(
        two[two.indexOf('-filter_complex') + 1],
        contains('[a0][a1]concat=n=2:v=0:a=1[c]'),
      );
    });

    test('默认（广播剧音轨铺满整条音轨）只按 cue 边界剪，不整形', () {
      final List<String> args = buildMangaClipArgs(
        sourcePath: 'book.m4a',
        startMs: 1500,
        endMs: 2300,
        outputPath: 'o',
      );
      expect(args.sublist(1, 7), <String>[
        '-ss',
        '1.500',
        '-t',
        '0.800',
        '-i',
        'book.m4a',
      ]);
      expect(args.join(' '), isNot(contains('silenceremove')));
      expect(args.join(' '), isNot(contains('loudnorm')));
    });

    test('和合成句排在一起的有声书片段：裁首尾静音、淡入淡出、与合成句同一个响度', () {
      final List<String> args = buildMangaClipArgs(
        sourcePath: 'book.m4a',
        startMs: 1500,
        endMs: 2300,
        outputPath: 'o',
        shapeAsLine: true,
      );
      final String af = args[args.indexOf('-af') + 1];
      expect(af, startsWith('silenceremove'));
      expect(af, contains(kMangaEdgeFadeFilter));
      expect(af, endsWith('$kMangaLoudnessFilter,aresample=44100'));
      expect(args.sublist(args.length - 3), <String>['-f', 'mp4', 'o']);
    });

    test('旁白参考音频：同一套整形，写无损 WAV', () {
      final List<String> args = buildMangaNarratorRefArgs(
        sourcePath: 'book.m4a',
        startMs: 1000,
        endMs: 5000,
        outputPath: 'ref.wav.part',
      );
      expect(args.sublist(1, 7), <String>[
        '-ss',
        '1.000',
        '-t',
        '4.000',
        '-i',
        'book.m4a',
      ]);
      expect(args[args.indexOf('-af') + 1], contains(kMangaLoudnessFilter));
      expect(args[args.indexOf('-c:a') + 1], 'pcm_s16le');
      expect(args.sublist(args.length - 3), <String>[
        '-f',
        'wav',
        'ref.wav.part',
      ]);
    });

    test('整形版本是整形参数的指纹；旁白参考音频文件名带上它', () {
      expect(kMangaShapeVersion, matches(RegExp(r'^[0-9a-f]{12}$')));
      // 版本取自三个参数构造器的完整输出（不只整形滤镜）：拼接前的统一采样 / 声道、
      // 参考音频的编码变了也要换版本。
      expect(
        kMangaShapeVersion,
        mangaShapeFingerprint(<List<String>>[
          buildMangaLineEncodeArgs(
            inputs: const <String>['in0', 'in1'],
            outputPath: 'out',
          ),
          buildMangaClipArgs(
            sourcePath: 'in',
            startMs: 0,
            endMs: 1000,
            outputPath: 'out',
            shapeAsLine: true,
          ),
          buildMangaNarratorRefArgs(
            sourcePath: 'in',
            startMs: 0,
            endMs: 1000,
            outputPath: 'out',
          ),
        ]),
      );
      expect(
        mangaShapeFingerprint(<List<String>>[
          <String>['a', 'b'],
        ]),
        isNot(
          mangaShapeFingerprint(<List<String>>[
            <String>['ab'],
          ]),
        ),
      );
      const MangaAudiobookClip clip = MangaAudiobookClip(
        bookKey: 'novel',
        fileIndex: 0,
        startMs: 0,
        endMs: 4000,
      );
      expect(
        mangaNarratorRefFileName(clip),
        '${mangaNarratorRefName(clip)}.$kMangaShapeVersion.wav',
      );
      // 旧版本（含没有版本号的历史文件）算过期；当前版本与在写的临时文件不算。
      expect(
        isStaleMangaNarratorRef('${mangaNarratorRefName(clip)}.wav'),
        isTrue,
      );
      expect(isStaleMangaNarratorRef('0123.000000000000.wav'), isTrue);
      expect(isStaleMangaNarratorRef(mangaNarratorRefFileName(clip)), isFalse);
      expect(
        isStaleMangaNarratorRef('${mangaNarratorRefFileName(clip)}.part'),
        isFalse,
      );
    });

    test('旁白虚拟预设走声音包管线：不挂 LoRA，参考音频按顺序', () {
      final MangaNarratorVoice narrator = MangaNarratorVoice(
        const <MangaAudiobookClip>[
          MangaAudiobookClip(
            bookKey: 'novel',
            fileIndex: 0,
            startMs: 0,
            endMs: 4000,
          ),
        ],
      );
      final TtsVoicePreset preset = mangaNarratorPreset(narrator, <String>[
        '/c/a.wav',
      ]);
      expect(preset.id, narrator.id);
      expect(preset.providerId, kIrodoriPackProviderId);
      final IrodoriBatchItem item = irodoriBatchItemFromPreset(
        preset,
        id: 'k',
        text: 'こんにちは',
        outputPath: 'o.wav',
      )!;
      expect(item.refs, <String>['/c/a.wav']);
      expect(item.adapterDir, isNull);
    });
  });

  group('数据库', () {
    late FushiDatabase db;
    late Directory tmp;
    late SeriesCastStore store;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      tmp = await Directory.systemTemp.createTemp('manga_audio_app_test_');
      store = SeriesCastStore(Directory(p.join(tmp.path, 'tts_cast')));
    });

    tearDown(() async {
      await db.close();
      await tmp.delete(recursive: true);
    });

    test('入库：清单每行一条 cue（页、块下标、时长、文件下标），音频绝对路径按行顺序', () async {
      const String bookKey = 'vol-1';
      await _insertBook(db, bookKey);
      final File manifestFile = MangaRenderManifest.fileFor(tmp, bookKey);
      final MangaRenderManifest manifest = MangaRenderManifest(
        pageCount: 3,
        lines: <MangaRenderedLine>[
          const MangaRenderedLine(
            lineId: 'p0b0.1',
            page: 0,
            blocks: <int>[0, 1],
            speaker: 'A',
            kind: CastLineKind.spoken,
            beatMs: 0,
            file: 'p0b0.1.m4a',
            durationMs: 1200,
            text: 'おはよう',
          ),
          const MangaRenderedLine(
            lineId: 'p2b0',
            page: 2,
            blocks: <int>[0],
            speaker: 'B',
            kind: CastLineKind.thought,
            beatMs: 0,
            file: 'p2b0.ph.wav',
            durationMs: 900,
            text: 'またね',
            placeholder: true,
          ),
        ],
      );
      await registerMangaAudio(
        db,
        bookKey: bookKey,
        manifestFile: manifestFile,
        manifest: manifest,
      );
      final AudiobookRepository repo = AudiobookRepository(db);
      final Audiobook? book = await repo.findByBookKey(bookKey);
      expect(book!.alignmentFormat, kMangaAlignmentFormat);
      expect(book.alignmentPath, manifestFile.path);
      expect(book.audioPaths, <String>[
        p.join(manifestFile.parent.path, 'p0b0.1.m4a'),
        p.join(manifestFile.parent.path, 'p2b0.ph.wav'),
      ]);
      final List<AudioCue> cues = await repo.cuesForBook(bookKey);
      expect(cues.length, 2);
      expect(cues[0].chapterHref, 'manga-page-0');
      expect(cues[0].textFragmentId, '0,1');
      expect(cues[0].endMs, 1200);
      expect(cues[0].audioFileIndex, 0);
      expect(cues[1].chapterHref, 'manga-page-2');
      expect(cues[1].audioFileIndex, 1);
      expect(cues[1].sentenceIndex, 1);
      expect(cues[1].text, 'またね');
    });

    test('系列：显式关联优先；否则取包含这卷的第一个合集（按合集排序；成员键 uid / bookKey 都认）', () async {
      final String uid1 = await _insertBook(db, 'vol-1');
      await _insertBook(db, 'vol-2');
      await _insertBook(db, 'loose');
      final int c1 = await db.createMediaCollection('Series A');
      final int c2 = await db.createMediaCollection('Other');
      await db.addToCollection(c1, MediaKind.epub, uid1);
      await db.addToCollection(c2, MediaKind.epub, uid1);
      await db.addToCollectionRaw(c1, 'epub', 'vol-2');

      expect(await resolveSeriesKeyIn(db, store, 'vol-1'), 'collection:$c1');
      expect(await resolveSeriesKeyIn(db, store, 'vol-2'), 'collection:$c1');
      expect(await resolveSeriesKeyIn(db, store, 'loose'), isNull);

      await store.link('loose', 'my-series');
      expect(await resolveSeriesKeyIn(db, store, 'loose'), 'my-series');

      // 显式「不归入任何系列」压过合集推断。
      await store.link('vol-2', kSeriesKeyStandalone);
      expect(await resolveSeriesKeyIn(db, store, 'vol-2'), isNull);
      expect(c2, isNot(c1));
    });

    test('按系列跑的卷序：合集顺序在前、显式关联的补在后，只列本地漫画卷', () async {
      final String uidA = await _insertBook(db, 'vol-a');
      final String uidB = await _insertBook(db, 'vol-b');
      final String uidNovel = await _insertBook(db, 'novel', format: 'epub');
      await _insertBook(db, 'vol-c');
      final int c = await db.createMediaCollection('S');
      await db.addToCollection(c, MediaKind.epub, uidB);
      await db.addToCollection(c, MediaKind.epub, uidA);
      await db.addToCollection(c, MediaKind.epub, uidNovel);
      await store.link('vol-c', 'collection:$c');

      final List<String> keys = await mangaSeriesVolumeKeysIn(
        db,
        store,
        'collection:$c',
      );
      final List<MediaCollectionItemRow> items = await db.getCollectionItems(c);
      final List<String> collectionOrder = <String>[
        for (final MediaCollectionItemRow i in items)
          if (i.entryKey == uidA) 'vol-a' else if (i.entryKey == uidB) 'vol-b',
      ];
      expect(keys, <String>[...collectionOrder, 'vol-c']);
    });
  });

  test('单句改成「不读」：从成品清单与库里拿掉，播放器不再念它（HBK-AUDIT-214）', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    final Directory tmp = await Directory.systemTemp.createTemp(
      'manga_audio_drop_test_',
    );
    addTearDown(() async {
      await db.close();
      await tmp.delete(recursive: true);
    });
    final _Session session = _Session();
    final _Host host = _Host(db, tmp, session);
    const String bookKey = 'vol-1';
    await _insertBook(db, bookKey);
    final File manifestFile = mangaRenderManifestFile(host, bookKey);
    MangaRenderedLine rendered(String id, int page) => MangaRenderedLine(
      lineId: id,
      page: page,
      blocks: const <int>[0],
      speaker: 'A',
      kind: CastLineKind.spoken,
      beatMs: 0,
      file: '$id.m4a',
      durationMs: 1000,
      text: id,
    );
    final MangaRenderManifest manifest = MangaRenderManifest(
      pageCount: 3,
      lines: <MangaRenderedLine>[rendered('p0b0', 0), rendered('p2b0', 2)],
    );
    await manifest.save(manifestFile);
    for (final MangaRenderedLine l in manifest.lines) {
      await File(p.join(manifestFile.parent.path, l.file)).writeAsString('a');
    }
    await registerMangaAudio(
      db,
      bookKey: bookKey,
      manifestFile: manifestFile,
      manifest: manifest,
    );
    final MangaAudioScript script = MangaAudioScript(
      lines: <MangaScriptLine>[
        MangaScriptLine(
          page: 0,
          blocks: <int>[0],
          speaker: 'A',
          kind: CastLineKind.spoken,
        ),
        MangaScriptLine(
          page: 2,
          blocks: <int>[0],
          speaker: 'A',
          kind: CastLineKind.skip,
        ),
      ],
    );

    // 还在读的句子不动。
    expect(
      await dropMangaUnreadLines(
        host,
        bookKey: bookKey,
        script: script,
        lineIds: <String>['p0b0'],
      ),
      isFalse,
    );
    expect(
      await dropMangaUnreadLines(
        host,
        bookKey: bookKey,
        script: script,
        lineIds: <String>['p2b0'],
      ),
      isTrue,
    );
    expect(session.stopped, <String>[bookKey]);
    final MangaRenderManifest? saved = await MangaRenderManifest.load(
      manifestFile,
    );
    expect(saved!.lines.map((MangaRenderedLine l) => l.lineId), <String>[
      'p0b0',
    ]);
    expect(
      File(p.join(manifestFile.parent.path, 'p2b0.m4a')).existsSync(),
      isFalse,
    );
    final AudiobookRepository repo = AudiobookRepository(db);
    expect((await repo.findByBookKey(bookKey))!.audioPaths, <String>[
      p.join(manifestFile.parent.path, 'p0b0.m4a'),
    ]);
    expect((await repo.cuesForBook(bookKey)).length, 1);
  });

  test('登记的是广播剧 / 动画音轨时，app 内按句改（保留候选 / 拿掉不读的句子）拦下、'
      '不碰合成清单与登记（拍板 pr4255b，BUG-5340）', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    final Directory tmp = await Directory.systemTemp.createTemp(
      'manga_audio_drama_guard_test_',
    );
    addTearDown(() async {
      await db.close();
      await tmp.delete(recursive: true);
    });
    final _Session session = _Session();
    final _Host host = _Host(db, tmp, session);
    const String bookKey = 'vol-1';
    await _insertBook(db, bookKey);
    MangaRenderedLine rendered(String id, int page) => MangaRenderedLine(
      lineId: id,
      page: page,
      blocks: const <int>[0],
      speaker: 'A',
      kind: CastLineKind.spoken,
      beatMs: 0,
      file: '$id.m4a',
      durationMs: 1000,
      text: id,
    );
    // 本机合成清单（两句）与广播剧清单（一段），登记的是广播剧。
    final File renderedFile = mangaRenderManifestFile(host, bookKey);
    final MangaRenderManifest renderedManifest = MangaRenderManifest(
      pageCount: 3,
      lines: <MangaRenderedLine>[rendered('p0b0', 0), rendered('p2b0', 2)],
    );
    await renderedManifest.save(renderedFile);
    for (final MangaRenderedLine l in renderedManifest.lines) {
      await File(p.join(renderedFile.parent.path, l.file)).writeAsString('a');
    }
    final String renderedBefore = await renderedFile.readAsString();
    final File dramaFile = mangaDramaManifestFile(host, bookKey);
    final MangaRenderManifest dramaManifest = MangaRenderManifest(
      pageCount: 3,
      lines: <MangaRenderedLine>[rendered('seg0', 0)],
    );
    await dramaManifest.save(dramaFile);
    await File(p.join(dramaFile.parent.path, 'seg0.m4a')).writeAsString('d');
    await registerMangaAudio(
      db,
      bookKey: bookKey,
      manifestFile: dramaFile,
      manifest: dramaManifest,
    );
    final AudiobookRepository repo = AudiobookRepository(db);
    final List<String> dramaPaths = <String>[
      p.join(dramaFile.parent.path, 'seg0.m4a'),
    ];
    Matcher dramaFailure() => throwsA(
      isA<TtsRenderFailure>().having(
        (TtsRenderFailure e) => e.code,
        'code',
        kMangaAudioDramaFailure,
      ),
    );

    // 同一个判据：编辑目标仍指向本机清单、种类记 drama；按句改的入口拦下。
    final MangaAudioEditTarget target = await mangaAudioEditTarget(
      host,
      bookKey,
    );
    expect(target.kind, MangaAudioProductKind.drama);
    await expectLater(mangaLineEditTarget(host, bookKey), dramaFailure());

    final MangaAudioScript script = MangaAudioScript(
      lines: <MangaScriptLine>[
        MangaScriptLine(
          page: 0,
          blocks: <int>[0],
          speaker: 'A',
          kind: CastLineKind.spoken,
        ),
        MangaScriptLine(
          page: 2,
          blocks: <int>[0],
          speaker: 'A',
          kind: CastLineKind.skip,
        ),
      ],
    );
    await expectLater(
      dropMangaUnreadLines(
        host,
        bookKey: bookKey,
        script: script,
        lineIds: <String>['p2b0'],
      ),
      dramaFailure(),
    );

    // 试听期间登记成了广播剧：保留候选拦下，候选文件撤回。
    final MangaRegenerateCandidate candidate = MangaRegenerateCandidate(
      lineId: 'p0b0',
      seed: 7,
      file: 'p0b0.s7.m4a',
      durationMs: 900,
      voice: 'v',
      text: 'p0b0',
      shape: 'shape',
    );
    final File staged = File(
      p.join(renderedFile.parent.path, candidate.stagedFile),
    );
    await staged.writeAsString('candidate');
    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    final MangaAudioVolume volume = MangaAudioVolume(
      row: row,
      payload: const MokuroPayload(images: <MokuroImage>[]),
      script: script,
      seriesKey: null,
      series: null,
    );
    await expectLater(
      keepMangaCandidate(host, volume: volume, candidate: candidate),
      dramaFailure(),
    );
    expect(staged.existsSync(), isFalse);

    // 什么都没写：合成清单与它的句文件原样、登记仍是广播剧、没停播放。
    expect(await renderedFile.readAsString(), renderedBefore);
    expect(
      File(p.join(renderedFile.parent.path, 'p2b0.m4a')).existsSync(),
      isTrue,
    );
    final AudiobookRow? registered = await db.getAudiobookByBookKey(bookKey);
    expect(registered!.alignmentPath, dramaFile.absolute.path);
    expect((await repo.findByBookKey(bookKey))!.audioPaths, dramaPaths);
    expect(session.stopped, isEmpty);
    expect(
      ttsRenderFailureText(kMangaAudioDramaFailure),
      t.manga_audio_failure_drama_registered,
    );
  });

  test('任务 / 一句级失败码有文案', () {
    for (final String code in <String>[
      'manga_script_stale',
      'manga_script_empty',
      'empty_text',
      'silent_output',
      'clip_source_missing',
      'ffmpeg_missing',
      'line_not_read',
      kMangaAudioDramaFailure,
    ]) {
      expect(
        ttsRenderFailureText(code),
        isNot(ttsRenderFailureText('no_such_code')),
        reason: code,
      );
    }
  });
}
