/// 漫画有声生成的应用级装配：存储位置、载入一卷（OCR + 演出稿 + 系列声音）、制作队列
/// 里的漫画任务（整卷生成 / 补回）、单句换种子、按系列排任务。
///
/// - 演出稿、未配音账本、系列档案都在 `<db>/tts_cast/`（与小说选角表同目录，后缀不同
///   互不覆盖）；成品在 `<db>/manga_audio/<sha1(bookKey)>/`（清单 + 每句一个文件）。
/// - 演出稿的声音指派叠在系列档案上（`MangaAudioScript.series`）；系列由
///   [resolveSeriesKey] 给。
/// - 生成前核对演出稿与当前 OCR 的签名：对不上（OCR 重跑过）整卷拒绝生成，不带着错位的
///   块下标出音频（设计 §1 / 验收）。
library;

import 'dart:io';
import 'dart:isolate';

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart'
    show FfmpegBackend, FfmpegRunResult, resolveFfmpegBackend;
import 'package:fushi_engine/tts/cast/cast_line_voicing.dart';
import 'package:fushi_engine/tts/cast/series_cast.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_narrator.dart'
    show MangaNarratorVoice;
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render_plan.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_renderer.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_validate.dart'
    show mangaPayloadOcrSignature;
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/audiobook/tts/cast/series_cast_resolver.dart';
import 'package:fushi/src/media/audiobook/tts/irodori_voice_packs.dart';
import 'package:fushi/src/media/audiobook/tts/studio/audio_production_host.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_series_cast.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_library.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_render_backend.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_stores.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 是不是能做漫画有声的本地漫画卷（在线作品的章目录不支持，与「未下载不识别」一致）。
bool isLocalMangaVolume(EpubBookRow row) =>
    BookFormat.parseOrEpub(row.format) == BookFormat.manga &&
    OnlineMangaLibraryEntry.tryParse(row.sourceMetadata) == null;

/// 载入好的一卷。
class MangaAudioVolume {
  MangaAudioVolume({
    required this.row,
    required this.payload,
    required this.script,
    required this.seriesKey,
    required this.series,
  });

  final EpubBookRow row;
  final MokuroPayload payload;

  /// 演出稿（`series` 已挂上系列声音指派）。
  final MangaAudioScript script;
  final String? seriesKey;

  /// 系列档案（没有系列为 null）。写系列后换成存盘后的最新档案。
  SeriesCastProfile? series;

  String get bookKey => row.bookKey;

  List<List<MokuroBlock>> get pageBlocks => <List<MokuroBlock>>[
    for (final MokuroImage image in payload.images) image.blocks,
  ];

  MangaScriptFreshness get freshness =>
      script.freshness(mangaPayloadOcrSignature(payload));
}

/// 载入一卷；不是本地漫画卷 / `manga.json` 读不出 → null。
Future<MangaAudioVolume?> loadMangaAudioVolume(
  AudioProductionHost appModel,
  String bookKey,
) async {
  final EpubBookRow? row = await appModel.database.getEpubBook(bookKey);
  if (row == null || !isLocalMangaVolume(row)) return null;
  final File json = File(p.join(row.extractDir, row.epubPath));
  if (!await json.exists()) return null;
  final String raw = await json.readAsString();
  final MokuroPayload payload;
  try {
    payload = await Isolate.run(() => parseMangaJson(raw));
  } on FormatException {
    return null;
  }
  final MangaAudioScript script = await mangaAudioScriptStoreFor(
    appModel,
  ).load(bookKey);
  final String? seriesKey = await resolveSeriesKey(appModel, bookKey);
  SeriesCastProfile? series;
  if (seriesKey != null) {
    series = await seriesCastStoreFor(appModel).load(seriesKey);
    script.series = series.voices;
    // 系列用词替换表改生成端实际念的文字 / cue 文本；AI 文字输入另在标注流程替换，不改演出稿。
    script.substitutions = series.substitutions;
    // 合集派生的系列：展示名取合集名快照（档案落盘时一并记下）。
    if (series.title.isEmpty) {
      final int? id = seriesCollectionId(seriesKey);
      final MediaCollectionRow? collection = id == null
          ? null
          : await appModel.database.getMediaCollectionById(id);
      if (collection != null) series.title = collection.name;
    }
  }
  return MangaAudioVolume(
    row: row,
    payload: payload,
    script: script,
    seriesKey: seriesKey,
    series: series,
  );
}

/// 一卷能不能开始生成；能 → null，不能 → 失败码（同 [TtsRenderFailure.code]）。
String? mangaRenderBlocker(MangaAudioVolume volume) {
  if (volume.payload.images.isEmpty) return 'manga_no_pages';
  if (volume.script.audibleLines.isEmpty) return 'manga_script_empty';
  if (volume.freshness == MangaScriptFreshness.needsReannotation) {
    return 'manga_script_stale';
  }
  return null;
}

Future<AppMangaRenderBackend> _backendFor(
  AudioProductionHost appModel,
  MangaAudioScript script,
) async {
  final TtsServices tts = TtsServices.of(appModel.prefsRepo);
  // 有声书片段：按 `MangaAudiobookClip.bookKey`（旧行回落第一本关联书）取那本书
  // `audioFilesInCueOrder` 里的第 `fileIndex` 个文件（与匹配器写片段时同一坐标）。
  final Map<String, List<String>> clipSources = <String, List<String>>{};
  final AudiobookRepository repo = AudiobookRepository(appModel.database);
  for (final String key in script.audiobookSources) {
    final Audiobook? book = await repo.findByBookKey(key);
    final List<String>? paths = book?.audioPathsInCueOrder;
    if (paths != null) clipSources[key] = paths;
  }
  return AppMangaRenderBackend.fromServices(
    tts: tts,
    cache: await tts.cache(),
    ffmpeg: resolveFfmpegBackend(),
    log: (String source, String summary) =>
        ErrorLogService.instance.log(source, summary, StackTrace.current),
    // 声音预设 + 声音包（`pack:<packId>/<group>`）：演出稿里两类声音 id 都可能出现。
    presets: ttsProductionPresets(tts, appModel),
    clipSources: clipSources,
  );
}

MangaAudioRenderer _rendererFor(
  AudioProductionHost appModel,
  String bookKey,
  MangaRenderBackend backend,
) => MangaAudioRenderer(
  backend: backend,
  manifestFile: mangaRenderManifestFile(appModel, bookKey),
);

Future<void> _ensureFfmpeg(FfmpegBackend backend) async {
  final FfmpegRunResult result = await backend.runQuery(const <String>[
    '-hide_banner',
    '-version',
  ], const Duration(seconds: 20));
  if (!result.isSuccess) throw const TtsRenderFailure('ffmpeg_missing');
}

/// 制作队列里一个漫画任务：`lineRequests` 为空 = 整卷生成，否则 = 补回这些句子。
/// 一句失败不让任务失败（占位 + 记账）；整卷级问题（不是漫画卷、演出稿过期、没生成过
/// 却要补回、ffmpeg 不可用）抛 [TtsRenderFailure]。
Future<({bool verified, List<TtsRenderFlag> flags})> runMangaRenderJob(
  AudioProductionHost appModel,
  TtsRenderJob job, {
  required TtsRenderProgress onProgress,
  required TtsRenderCancelToken cancel,
}) async {
  onProgress(TtsRenderJobPhase.planning, 0, 0);
  final MangaAudioVolume? volume = await loadMangaAudioVolume(
    appModel,
    job.bookKey,
  );
  if (volume == null) throw const TtsRenderFailure('book_missing');
  final String? blocker = mangaRenderBlocker(volume);
  if (blocker != null) throw TtsRenderFailure(blocker);
  await _ensureFfmpeg(resolveFfmpegBackend());
  cancel.throwIfCancelled();

  // 句文件会被原地替换：先停掉这卷的播放（Windows 上被占用的文件换不掉）。
  await appModel.audiobookSession.stopIfPlayingAny(<String>[job.bookKey]);
  final AppMangaRenderBackend backend = await _backendFor(
    appModel,
    volume.script,
  );
  final MangaAudioRenderer renderer = _rendererFor(
    appModel,
    job.bookKey,
    backend,
  );
  final CastVoicingStore voicing = ttsVoicingStoreFor(appModel);
  final CastVoicingLedger ledger = await voicing.load(job.bookKey);
  final MangaRenderManifest? previous = await MangaRenderManifest.load(
    renderer.manifestFile,
  );
  final MangaRenderManifest manifest;
  // 补回时配上音的句子（只更新库里这几句；整卷生成为 null = 整份登记）。
  List<String>? voicedLines;
  try {
    if (job.lineRequests.isEmpty) {
      final MangaRenderOutcome outcome = await renderer.render(
        script: volume.script,
        pageBlocks: volume.pageBlocks,
        defaultVoice: job.presetId,
        previous: previous,
        ledger: ledger,
        onProgress: (int done, int total) =>
            onProgress(TtsRenderJobPhase.synthesizing, done, total),
        cancel: cancel,
      );
      manifest = outcome.manifest;
    } else {
      if (previous == null) throw const TtsRenderFailure('manga_not_rendered');
      final Map<String, MangaBackfillStatus> statuses = await renderer.backfill(
        script: volume.script,
        pageBlocks: volume.pageBlocks,
        defaultVoice: job.presetId,
        manifest: previous,
        ledger: ledger,
        requests: <MangaBackfillRequest>[
          for (final TtsRenderLineRequest r in job.lineRequests)
            MangaBackfillRequest(
              lineId: r.lineId,
              voice: r.voice,
              say: r.say,
              nextRetryVoice: r.nextRetryVoice,
              seed: r.seed,
            ),
        ],
        onProgress: (int done, int total) =>
            onProgress(TtsRenderJobPhase.synthesizing, done, total),
        cancel: cancel,
      );
      manifest = previous;
      voicedLines = <String>[
        for (final MapEntry<String, MangaBackfillStatus> e in statuses.entries)
          if (e.value == MangaBackfillStatus.voiced) e.key,
      ];
      // 补回成功的句子把声音 / 手填文字写回了演出稿那一行。
      await mangaAudioScriptStoreFor(appModel).save(job.bookKey, volume.script);
    }
  } finally {
    // 取消 / 失败时账本里已记下的尝试也要落盘（下次「切配置重试」跳过它们）。
    await voicing.save(job.bookKey, ledger);
    await backend.dispose();
  }
  onProgress(TtsRenderJobPhase.importing, 0, 1);
  // 入库后漫画卡 / 阅读器直接能播（不用手动导入）。补回只换配上音的那几句的 cue 与
  // 音频路径（库与清单对不上时 updateMangaAudioLine 自己退回整份登记）。
  final List<String>? updated = voicedLines;
  if (updated == null) {
    await registerMangaAudio(
      appModel.database,
      bookKey: job.bookKey,
      manifestFile: renderer.manifestFile,
      manifest: manifest,
    );
  } else if (updated.isNotEmpty) {
    await updateMangaAudioLines(
      appModel.database,
      bookKey: job.bookKey,
      manifestFile: renderer.manifestFile,
      manifest: manifest,
      lineIds: updated,
    );
  }
  onProgress(TtsRenderJobPhase.importing, 1, 1);
  return (verified: false, flags: const <TtsRenderFlag>[]);
}

/// 单句换种子重生成（不经队列：一句、要立刻试听）。失败抛 [MangaLineFailure] /
/// [TtsRenderFailure]。
Future<MangaRegenerateCandidate> regenerateMangaLine(
  AudioProductionHost appModel, {
  required MangaAudioVolume volume,
  required String lineId,
  required int seed,
  required String defaultVoice,
  required TtsRenderCancelToken cancel,
}) async {
  await _ensureFfmpeg(resolveFfmpegBackend());
  final AppMangaRenderBackend backend = await _backendFor(
    appModel,
    volume.script,
  );
  try {
    return await _rendererFor(appModel, volume.bookKey, backend).regenerate(
      script: volume.script,
      pageBlocks: volume.pageBlocks,
      defaultVoice: defaultVoice,
      lineId: lineId,
      seed: seed,
      cancel: cancel,
    );
  } finally {
    await backend.dispose();
  }
}

/// 「按句替换本地音频」用的后端：只整形本地音频，不拉起 TTS 引擎。ffmpeg 不可用抛
/// [TtsRenderFailure]（`ffmpeg_missing`）。
Future<MangaRenderBackend> mangaLocalAudioBackend() async {
  final FfmpegBackend ffmpeg = resolveFfmpegBackend();
  await _ensureFfmpeg(ffmpeg);
  return MangaLocalAudioBackend(
    ffmpeg: ffmpeg,
    log: (String source, String summary) =>
        ErrorLogService.instance.log(source, summary, StackTrace.current),
  );
}

/// 候选音频的绝对路径（试听用；保留前它在暂存文件里）。
String mangaCandidatePath(
  AudioProductionHost appModel,
  String bookKey,
  MangaRegenerateCandidate candidate,
) => p.join(
  mangaRenderManifestFile(appModel, bookKey).parent.path,
  candidate.stagedFile,
);

/// 保留候选：清单 / 演出稿 / 账本落盘，重新入库。返回 false = 这句已不在清单里，
/// 或候选文件已被别的操作清掉（什么都没改）。
Future<bool> keepMangaCandidate(
  AudioProductionHost appModel, {
  required MangaAudioVolume volume,
  required MangaRegenerateCandidate candidate,
}) async {
  final File manifestFile = mangaRenderManifestFile(appModel, volume.bookKey);
  final MangaRenderManifest? manifest = await MangaRenderManifest.load(
    manifestFile,
  );
  final MangaAudioRenderer renderer = MangaAudioRenderer(
    backend: const _NoBackend(),
    manifestFile: manifestFile,
  );
  if (manifest == null) {
    await renderer.discardCandidate(candidate);
    return false;
  }
  await appModel.audiobookSession.stopIfPlayingAny(<String>[volume.bookKey]);
  final CastVoicingStore voicing = ttsVoicingStoreFor(appModel);
  final CastVoicingLedger ledger = await voicing.load(volume.bookKey);
  final bool kept = await renderer.keepCandidate(
    script: volume.script,
    manifest: manifest,
    ledger: ledger,
    candidate: candidate,
  );
  if (!kept) return false;
  await mangaAudioScriptStoreFor(appModel).save(volume.bookKey, volume.script);
  await voicing.save(volume.bookKey, ledger);
  // 单句换种子：只换库里这一句。
  await updateMangaAudioLine(
    appModel.database,
    bookKey: volume.bookKey,
    manifestFile: manifestFile,
    manifest: manifest,
    lineId: candidate.lineId,
  );
  return true;
}

/// 演出稿里已改成「不读」类型的句子（[lineIds] 里的）从成品里拿掉：清单、账本落盘，
/// 库按新清单整份重登记，播放器不再念它（与整卷生成同一判据，HBK-AUDIT-214）。返回
/// true = 拿掉了（清单变了）。这卷没生成过 / 这几句都还读时什么都不写。
Future<bool> dropMangaUnreadLines(
  AudioProductionHost appModel, {
  required String bookKey,
  required MangaAudioScript script,
  required Iterable<String> lineIds,
}) async {
  final File manifestFile = mangaRenderManifestFile(appModel, bookKey);
  final MangaRenderManifest? manifest = await MangaRenderManifest.load(
    manifestFile,
  );
  if (manifest == null ||
      mangaUnreadRenderedLines(
        script: script,
        manifest: manifest,
        lineIds: lineIds,
      ).isEmpty) {
    return false;
  }
  // 要删这几句的音频文件：先停掉这卷的播放（Windows 上被占用的文件删不掉）。
  await appModel.audiobookSession.stopIfPlayingAny(<String>[bookKey]);
  final CastVoicingStore voicing = ttsVoicingStoreFor(appModel);
  final CastVoicingLedger ledger = await voicing.load(bookKey);
  final List<String> dropped =
      await MangaAudioRenderer(
        backend: const _NoBackend(),
        manifestFile: manifestFile,
      ).dropUnreadLines(
        script: script,
        manifest: manifest,
        ledger: ledger,
        lineIds: lineIds,
      );
  if (dropped.isEmpty) return false;
  await voicing.save(bookKey, ledger);
  await registerMangaAudio(
    appModel.database,
    bookKey: bookKey,
    manifestFile: manifestFile,
    manifest: manifest,
  );
  return true;
}

/// 撤回候选。
Future<void> discardMangaCandidate(
  AudioProductionHost appModel,
  String bookKey,
  MangaRegenerateCandidate candidate,
) => MangaAudioRenderer(
  backend: const _NoBackend(),
  manifestFile: mangaRenderManifestFile(appModel, bookKey),
).discardCandidate(candidate);

/// 保留 / 撤回候选只动文件与清单，不合成。
class _NoBackend implements MangaRenderBackend {
  const _NoBackend();

  @override
  int get parallelism => 1;

  @override
  String get shapeVersion => throw UnsupportedError('no synthesis here');

  @override
  Future<int> synthesizeLine({
    required String voice,
    required int seed,
    required List<String> segments,
    required CastLineDirection direction,
    required String outputPath,
    required TtsRenderCancelToken cancel,
  }) => throw UnsupportedError('no synthesis here');

  @override
  Future<String?> directionKey({
    required String voice,
    required CastLineDirection direction,
  }) async => null;

  @override
  Future<int> cutClip({
    required MangaAudiobookClip clip,
    required String outputPath,
    required TtsRenderCancelToken cancel,
  }) => throw UnsupportedError('no synthesis here');

  @override
  Future<int> writeSilence({required int ms, required String outputPath}) =>
      throw UnsupportedError('no synthesis here');

  @override
  Future<int> shapeLocalAudio({
    required String sourcePath,
    required String outputPath,
    required TtsRenderCancelToken cancel,
  }) => throw UnsupportedError('no synthesis here');

  @override
  Future<void> prepare({
    required List<MangaRenderItem> items,
    required TtsRenderCancelToken cancel,
  }) async {}

  @override
  bool get canCloneNarrator => false;

  @override
  Future<bool> prepareNarrator({
    required MangaNarratorVoice narrator,
    required TtsRenderCancelToken cancel,
  }) async => false;
}

/// 系列里的卷，按阅读顺序：合集派生的系列先按合集内顺序，再补上显式关联进来的卷；
/// 只列还在书架上的本地漫画卷。
Future<List<String>> mangaSeriesVolumeKeys(
  AudioProductionHost appModel,
  String seriesKey,
) => mangaSeriesVolumeKeysIn(
  appModel.database,
  seriesCastStoreFor(appModel),
  seriesKey,
);

/// [mangaSeriesVolumeKeys] 的本体（只依赖数据库与档案存储，测试直接调）：系列成员
/// 顺序（[seriesMemberBooksIn]，与小说按系列跑同一份）里的本地漫画卷。
Future<List<String>> mangaSeriesVolumeKeysIn(
  FushiDatabase db,
  SeriesCastStore store,
  String seriesKey,
) async => <String>[
  for (final String key in await seriesMemberBooksIn(db, store, seriesKey))
    if (await db.getEpubBook(key) case final EpubBookRow row
        when isLocalMangaVolume(row))
      key,
];

/// 声音指派的改动写到哪：系列（默认，下一卷自动沿用）或只这一卷。没有系列时只能写
/// 这一卷。
///
/// [edit] 是这次的改动：写系列时在最新的系列档案上重做一次（[SeriesCastStore.update]
/// 串行读-改-写），本卷手里的旧拷贝随后换成存盘后的档案。
Future<void> saveMangaVoiceAssignment(
  AudioProductionHost appModel,
  MangaAudioVolume volume, {
  required bool seriesLevel,
  required void Function(CastVoiceAssignment target) edit,
}) async {
  final SeriesCastProfile? series = volume.series;
  final String? seriesKey = volume.seriesKey;
  if (seriesLevel && series != null && seriesKey != null) {
    final SeriesCastProfile fresh = await seriesCastStoreFor(
      appModel,
    ).update(seriesKey, (SeriesCastProfile p) => edit(p.voices));
    if (fresh.title.isEmpty) fresh.title = series.title;
    volume.series = fresh;
    volume.script.series = fresh.voices;
  }
  await mangaAudioScriptStoreFor(appModel).save(volume.bookKey, volume.script);
}
