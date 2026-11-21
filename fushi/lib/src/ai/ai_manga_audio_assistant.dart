/// 漫画演出标注（[AiFeature.mangaAudio]，设计 §4）的应用层：解析提供商、读卷（本地
/// `manga.json` + 页图）、缩图、落盘，流程本身在引擎层 `MangaAnnotateRunner`。
///
/// - 未解析到可用提供商不发任何请求（[MangaAudioAnnotateError] `no_ai_provider`）。
/// - 请求走 [AiChatClient.complete]：共享限频器、临时性失败指数退避、错误脱敏成短码。
/// - 回复落地前过引擎层本地校验；不合格的行丢弃并记进失败账本供复核界面列出。
/// - 页图上传前的同意与预估请求数在界面层（`manga_audio_annotate_flow.dart`）。
/// - 按系列：角色表从系列档案起步，每卷标完学回系列（[SeriesCastProfile.learnRoster]），
///   下一卷带着上一卷认出的人继续；按系列跑（`TtsSeriesRun`）按系列成员顺序逐卷跑。
/// - 会话只管一卷一次的读写；后台跑、取消、观察进度在进程级任务表
///   `MangaAnnotateTasks`（`manga_audio_annotate_tasks.dart`），页面只是观察者。
///
/// 只支持本地卷（整卷一个目录、一份 `manga.json`）；在线作品按章下载、每章一份
/// OCR，没有「一卷」的页序，本期不做（[MangaAudioAnnotateError] `online_unsupported`）。
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart';
import 'package:fushi_engine/tts/cast/series_cast.dart';
import 'package:fushi_engine/tts/cast/cast_text_substitution.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate_ledger.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate_runner.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_validate.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/audiobook/tts/cast/series_cast_resolver.dart';
import 'package:fushi/src/media/audiobook/tts/studio/audio_production_host.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_stores.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_substitution_image.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';

/// 单页回复的输出上限：一页几十句全是台词约 2k token，给推理模型的思考留余量。
const int _kAnnotateMaxTokens = 8192;

/// 页图 JPEG 质量（缩到 [kMangaAnnotateImageMaxSide] 之后）。
const int _kAnnotateJpegQuality = 85;

/// 标注没法开始（[code]：`no_ai_provider` / `not_found` / `online_unsupported` /
/// `no_ocr` / `unreadable`）。
class MangaAudioAnnotateError implements Exception {
  const MangaAudioAnnotateError(this.code);
  final String code;

  @override
  String toString() => 'MangaAudioAnnotateError($code)';
}

/// 用户能选的提供商（配全且启用），按设置里的顺序——「切配置重试」从这里挑。
List<AiProviderConfig> mangaAudioUsableProviders(
  AudioProductionHost appModel,
) => appModel.isPreferencesReady
    ? <AiProviderConfig>[
        for (final AiProviderConfig c in appModel.prefsRepo.aiProviders)
          if (c.isUsable) c,
      ]
    : const <AiProviderConfig>[];

/// 本次用哪家：[providerId] 指定（切配置重试）就用它（必须可用）；否则按功能指派。
AiProviderConfig? resolveMangaAudioProvider(
  AudioProductionHost appModel, {
  String? providerId,
}) {
  if (!appModel.isPreferencesReady) return null;
  if (providerId != null) {
    for (final AiProviderConfig c in mangaAudioUsableProviders(appModel)) {
      if (c.id == providerId) return c;
    }
    return null;
  }
  return appModel.prefsRepo.aiFeatureAssignments.resolve(
    AiFeature.mangaAudio,
    appModel.prefsRepo.aiProviders,
  );
}

/// 一卷本地漫画：书架行、OCR 结果与页图文件（`relativeUrl` → 文件）。
class MangaAnnotateVolume {
  const MangaAnnotateVolume({
    required this.row,
    required this.payload,
    required this.pageFiles,
  });

  final EpubBookRow row;
  final MokuroPayload payload;
  final Map<String, File> pageFiles;

  String get bookKey => row.bookKey;

  /// 本卷 OCR 签名（引擎签名优先，没有时按块内容算：mokuro 导入的卷也能判过期）。
  String get ocrSignature => mangaPayloadOcrSignature(payload);
  bool get hasText =>
      payload.images.any((MokuroImage image) => image.blocks.isNotEmpty);
}

/// 读一卷；不是本地漫画卷 / 没识别过 / 读不出时抛 [MangaAudioAnnotateError]。
Future<MangaAnnotateVolume> loadMangaAnnotateVolume(
  AudioProductionHost appModel,
  String bookKey,
) async {
  final EpubBookRow? row = await appModel.database.getEpubBook(bookKey);
  if (row == null || BookFormat.tryParse(row.format) != BookFormat.manga) {
    throw const MangaAudioAnnotateError('not_found');
  }
  if (OnlineMangaLibraryEntry.tryParse(row.sourceMetadata) != null) {
    throw const MangaAudioAnnotateError('online_unsupported');
  }
  final String jsonPath = p.join(row.extractDir, row.epubPath);
  final String dir = row.extractDir;
  final ({MokuroPayload payload, Map<String, String> files})? read =
      await Isolate.run(() => _readVolume(jsonPath, dir));
  if (read == null) throw const MangaAudioAnnotateError('unreadable');
  final MangaAnnotateVolume volume = MangaAnnotateVolume(
    row: row,
    payload: read.payload,
    pageFiles: <String, File>{
      for (final MapEntry<String, String> e in read.files.entries)
        e.key: File(e.value),
    },
  );
  if (!volume.hasText) throw const MangaAudioAnnotateError('no_ocr');
  return volume;
}

Future<({MokuroPayload payload, Map<String, String> files})?> _readVolume(
  String jsonPath,
  String dir,
) async {
  final File json = File(jsonPath);
  if (!json.existsSync()) return null;
  try {
    final MokuroPayload payload = parseMangaJson(await json.readAsString());
    return (
      payload: payload,
      files: <String, String>{
        for (final MangaOcrPageFile f in enumerateMangaPages(Directory(dir)))
          f.relativeUrl: f.file.path,
      },
    );
  } on FormatException {
    return null;
  }
}

/// 读第 [page] 页并缩到长边 [kMangaAnnotateImageMaxSide] 的 JPEG；本来就不大于它的
/// JPEG / PNG / WebP 原样发，其它格式转 JPEG。命中替换表的页先重绘文字块再发；
/// 读不出或替换失败返回 null（记 `image` 失败），不退回含原词的页图。
Future<AiChatImage?> loadMangaAnnotatePageImage(
  MangaAnnotateVolume volume,
  int page, {
  List<CastTextSubstitution> substitutions = const <CastTextSubstitution>[],
}) async {
  if (page < 0 || page >= volume.payload.images.length) return null;
  final MokuroImage image = volume.payload.images[page];
  final File? file = volume.pageFiles[image.url];
  if (file == null) return null;
  final String path = file.path;
  final ({int width, int height})? target = mangaAnnotateImageTarget(
    image.size.width,
    image.size.height,
  );
  try {
    if (mangaPageHasSubstitutions(image, substitutions)) {
      final Uint8List bytes = await file.readAsBytes();
      final Uint8List? replaced = await prepareMangaSubstitutionImage(
        bytes: bytes,
        page: image,
        substitutions: substitutions,
        quality: _kAnnotateJpegQuality,
      );
      return replaced == null
          ? null
          : AiChatImage(bytes: replaced, mimeType: 'image/jpeg');
    }
    final ({Uint8List bytes, String mime})? out = await Isolate.run(
      () => _preparePageImage(path, target),
    );
    return out == null
        ? null
        : AiChatImage(bytes: out.bytes, mimeType: out.mime);
  } on FileSystemException {
    return null;
  }
}

({Uint8List bytes, String mime})? _preparePageImage(
  String path,
  ({int width, int height})? target,
) {
  final Uint8List bytes = File(path).readAsBytesSync();
  final FushiComputeImage kernel = FushiComputeImage.instance;
  if (target != null) {
    final Uint8List? fitted = kernel.fitJpeg(
      bytes,
      width: target.width,
      height: target.height,
      quality: _kAnnotateJpegQuality,
    );
    if (fitted != null) return (bytes: fitted, mime: 'image/jpeg');
  }
  final String? mime = switch (p.extension(path).toLowerCase()) {
    '.jpg' || '.jpeg' => 'image/jpeg',
    '.png' => 'image/png',
    '.webp' => 'image/webp',
    _ => null,
  };
  if (target == null && mime != null) return (bytes: bytes, mime: mime);
  // 需要缩却缩不了（带 alpha 等）或格式不在三家共同支持的集合里：转 JPEG。
  final Uint8List? jpeg = kernel.toJpeg(bytes, quality: _kAnnotateJpegQuality);
  return jpeg == null ? null : (bytes: jpeg, mime: 'image/jpeg');
}

/// 一卷的标注会话：演出稿、失败账本与系列档案一起读、一起存。
class MangaAudioAnnotateSession {
  MangaAudioAnnotateSession._({
    required this.appModel,
    required this.volume,
    required this.script,
    required this.ledger,
    required this.seriesKey,
    required this.series,
  });

  final AudioProductionHost appModel;
  final MangaAnnotateVolume volume;
  final MangaAudioScript script;
  final MangaAnnotationLedger ledger;

  /// 所属系列；null = 不属于任何系列（角色表只存在本卷）。
  final String? seriesKey;

  /// 本会话手里的系列档案拷贝（界面与标注用）；每次存盘后换成最新档案。
  SeriesCastProfile? series;

  /// 自上次存盘以来对系列档案的改动：存盘时在最新档案上依次重做
  /// （[SeriesCastStore.update]），不拿整份旧拷贝覆盖别处的写入。
  final List<void Function(SeriesCastProfile)> _seriesEdits =
      <void Function(SeriesCastProfile)>[];

  void _editSeries(void Function(SeriesCastProfile) edit) {
    final SeriesCastProfile? s = series;
    if (s == null) return;
    edit(s);
    _seriesEdits.add(edit);
  }

  String get bookKey => volume.bookKey;

  static Future<MangaAudioAnnotateSession> open(
    AudioProductionHost appModel,
    String bookKey,
  ) async {
    final MangaAnnotateVolume volume = await loadMangaAnnotateVolume(
      appModel,
      bookKey,
    );
    final String? seriesKey = await resolveSeriesKey(appModel, bookKey);
    final SeriesCastProfile? series = seriesKey == null
        ? null
        : await seriesCastStoreFor(appModel).load(seriesKey);
    final MangaAudioScript script = await mangaAudioScriptStoreFor(
      appModel,
    ).load(bookKey);
    script.series = series?.voices;
    return MangaAudioAnnotateSession._(
      appModel: appModel,
      volume: volume,
      script: script,
      ledger: await mangaAnnotationLedgerStoreFor(appModel).load(bookKey),
      seriesKey: seriesKey,
      series: series,
    );
  }

  int get pageCount => volume.payload.images.length;

  /// OCR 重跑过：块下标不可信，要整卷重新标注。
  bool get isStale =>
      script.freshness(volume.ocrSignature) ==
      MangaScriptFreshness.needsReannotation;

  /// 复核界面里说话人的候选：系列角色表 + 本卷角色表。
  Map<String, TtsCastCharacter> get roster => mergedMangaRoster(
    series: series?.roster ?? const <String, TtsCastCharacter>{},
    volume: script.roster,
  );

  /// 一句的台词文本（OCR 块拼接，手填优先）。
  String textOf(MangaScriptLine line) => line.page >= 0 && line.page < pageCount
      ? resolveMangaLineText(line, volume.payload.images[line.page].blocks)
      : '';

  Future<void> save() async {
    await mangaAudioScriptStoreFor(appModel).save(bookKey, script);
    await mangaAnnotationLedgerStoreFor(appModel).save(bookKey, ledger);
  }

  Future<void> _saveSeries() async {
    final SeriesCastProfile? s = series;
    final String? key = seriesKey;
    if (s == null || key == null || _seriesEdits.isEmpty) return;
    final List<void Function(SeriesCastProfile)> edits =
        List<void Function(SeriesCastProfile)>.of(_seriesEdits);
    _seriesEdits.clear();
    final SeriesCastProfile fresh = await seriesCastStoreFor(appModel).update(
      key,
      (SeriesCastProfile p) {
        for (final void Function(SeriesCastProfile) edit in edits) {
          edit(p);
        }
      },
    );
    if (fresh.title.isEmpty) fresh.title = s.title;
    series = fresh;
    script.series = fresh.voices;
  }

  /// 本次要标的页（[only] 非空 = 只标这些；否则全卷，[skipAnnotated] 跳过已标的）。
  List<int> pagesToAnnotate({
    Set<int> only = const <int>{},
    bool skipAnnotated = true,
  }) => mangaPagesToAnnotate(
    script,
    pageCount,
    only: only,
    skipAnnotated: skipAnnotated && !isStale,
  );

  MangaAnnotationEstimate estimate(List<int> pages, {bool withRoster = true}) =>
      estimateMangaAnnotation(<int>[
        for (final int p in pages) volume.payload.images[p].blocks.length,
      ], withRoster: withRoster);

  MangaAnnotateRunner _runner(
    AiProviderConfig provider,
    AiChatClient client, {
    required bool Function() isCancelled,
    void Function(MangaAnnotatePhase phase, int done, int total)? onProgress,
  }) {
    // 同一次运行的文字与页图必须使用同一份表，不能因 checkpoint 后系列快照刷新而漂移。
    final List<CastTextSubstitution> substitutions =
        List<CastTextSubstitution>.unmodifiable(
          series?.substitutions ?? const <CastTextSubstitution>[],
        );
    return MangaAnnotateRunner(
      payload: volume.payload,
      script: script,
      ledger: ledger,
      seriesRoster: series?.roster ?? const <String, TtsCastCharacter>{},
      substitutions: substitutions,
      ask: (List<AiChatMessage> messages) => client.complete(
        provider: provider,
        messages: messages,
        maxTokens: _kAnnotateMaxTokens,
      ),
      imageFor: (int page) => loadMangaAnnotatePageImage(
        volume,
        page,
        substitutions: substitutions,
      ),
      providerId: provider.id,
      model: provider.model,
      checkpoint: save,
      isCancelled: isCancelled,
      onProgress: onProgress,
    );
  }

  /// 跑一次标注。OCR 重跑过时先整卷清掉旧锚点（角色表与声音指派保留）。标完把认出
  /// 的人学回系列档案。整次中止（鉴权失败 / 取消）抛 [MangaAnnotateAbort]，已标的页
  /// 与失败账本都已落盘。
  Future<MangaAnnotateRunSummary> annotate({
    required AiProviderConfig provider,
    required List<int> pages,
    bool withRoster = true,
    bool withReview = true,
    required bool Function() isCancelled,
    void Function(MangaAnnotatePhase phase, int done, int total)? onProgress,
  }) => _withRunner(
    provider,
    isCancelled: isCancelled,
    onProgress: onProgress,
    body: (MangaAnnotateRunner runner) {
      // 旧锚点清掉后「只标这些页」已无意义：整卷重标。
      final bool reset = resetStaleMangaScript(
        script,
        ledger,
        volume.ocrSignature,
      );
      return runner.run(
        pages: reset ? pagesToAnnotate() : pages,
        withRoster: withRoster,
        withReview: withReview,
      );
    },
  );

  /// 按账本重试一处失败；[provider] 换成别家即「切配置重试」。
  Future<MangaAnnotateRunSummary> retry(
    MangaAnnotateFailure failure, {
    required AiProviderConfig provider,
    required bool Function() isCancelled,
    void Function(MangaAnnotatePhase phase, int done, int total)? onProgress,
  }) => _withRunner(
    provider,
    isCancelled: isCancelled,
    onProgress: onProgress,
    body: (MangaAnnotateRunner runner) => runner.retry(failure),
  );

  Future<MangaAnnotateRunSummary> _withRunner(
    AiProviderConfig provider, {
    required bool Function() isCancelled,
    void Function(MangaAnnotatePhase phase, int done, int total)? onProgress,
    required Future<MangaAnnotateRunSummary> Function(MangaAnnotateRunner) body,
  }) async {
    final AiChatClient client = AiChatClient();
    final MangaAnnotateRunner runner = _runner(
      provider,
      client,
      isCancelled: isCancelled,
      onProgress: onProgress,
    );
    try {
      return await body(runner);
    } finally {
      client.close();
      final List<TtsCastCharacter> found = runner.workingRoster.values.toList();
      _editSeries((SeriesCastProfile p) => p.learnRoster(found));
      await save();
      await _saveSeries();
    }
  }

  /// 用户手工标某页（AI 标不出来时）：每个还没归属的块一句（OCR 顺序、说话人不明、
  /// 说出口），来源记为用户，之后在复核界面逐句改；该页失败与丢弃记录清掉。
  void handAnnotatePage(int page) {
    final List<MangaScriptLine> existing = script.linesOnPage(page);
    final Set<int> claimed = <int>{
      for (final MangaScriptLine l in existing) ...l.blocks,
    };
    final int blocks = volume.payload.images[page].blocks.length;
    final List<MangaScriptLine> added = <MangaScriptLine>[
      for (int b = 0; b < blocks; b++)
        if (!claimed.contains(b))
          MangaScriptLine(
            page: page,
            blocks: <int>[b],
            speaker: kTtsUnknown,
            kind: CastLineKind.spoken,
            source: TtsCastSource.user,
          ),
    ];
    final int at = script.lines.lastIndexWhere(
      (MangaScriptLine l) => l.page <= page,
    );
    script.lines.insertAll(at + 1, added);
    script.annotatedPages.add(page);
    script.engineSignature ??= volume.ocrSignature;
    ledger.clearPage(page);
  }

  /// 角色改名 / 合并：本卷行、本卷角色表与系列档案一起改。
  void renameCharacter(String from, String to) {
    for (int i = 0; i < script.lines.length; i++) {
      if (script.lines[i].speaker == from) {
        script.lines[i] = script.lines[i].copyWith(
          speaker: to,
          source: TtsCastSource.user,
        );
      }
    }
    final TtsCastCharacter? gone = script.roster.remove(from);
    if (gone != null && to != kTtsUnknown && to != kTtsNarrator) {
      mergeCastRoster(script.roster, <TtsCastCharacter>[
        TtsCastCharacter(name: to, aliases: <String>[from, ...gone.aliases]),
      ]);
    }
    script.voices.renameCharacter(from, to);
    _editSeries((SeriesCastProfile p) => p.renameCharacter(from, to));
  }

  /// 给角色表加一个人（复核界面「新角色」）；同时记进系列。
  void addCharacter(String name) {
    final TtsCastCharacter c = TtsCastCharacter(name: name);
    mergeCastRoster(script.roster, <TtsCastCharacter>[c]);
    _editSeries((SeriesCastProfile p) => p.learnRoster(<TtsCastCharacter>[c]));
  }

  /// 制作台的存盘（演出稿 + 账本 + 系列档案）。演出稿按读盘修订写
  /// （[MangaAudioScriptStore.saveIfCurrent]）：本会话读盘后这卷被别处存过（标注任务、
  /// 生成回填、ctl）就什么都不写、返回 false，调用方应重开会话——账本与演出稿总是
  /// 一起由标注写入方落盘，演出稿没被动过即说明这份账本也还是最新的。
  Future<bool> saveEdits() async {
    final bool written = await mangaAudioScriptStoreFor(
      appModel,
    ).saveIfCurrent(bookKey, script);
    if (!written) return false;
    await mangaAnnotationLedgerStoreFor(appModel).save(bookKey, ledger);
    await _saveSeries();
    return true;
  }

  /// 逐句复核的存盘：只写复核会改的演出稿与系列档案改动，账本不动（复核不改账本，
  /// 写回会拿本会话的旧账本盖掉标注任务刚记下的失败）。演出稿按读盘修订写
  /// （[MangaAudioScriptStore.saveIfCurrent]）：本会话读盘后这卷被别处存过就不写、
  /// 返回 false，调用方应重开会话，不能拿整份旧稿盖掉新结果。
  Future<bool> saveReviewEdits() async {
    final bool written = await mangaAudioScriptStoreFor(
      appModel,
    ).saveIfCurrent(bookKey, script);
    if (!written) return false;
    await _saveSeries();
    return true;
  }
}

/// 系列的成员卷（按标注顺序 = [seriesMemberBooks] 的系列顺序，与生成、小说按系列跑
/// 同一份）。只收漫画格式的书；在线卷由标注会话自己报「暂不支持」。
Future<List<EpubBookRow>> mangaSeriesVolumes(
  AudioProductionHost appModel,
  String seriesKey,
) async => <EpubBookRow>[
  for (final String key in await seriesMemberBooks(appModel, seriesKey))
    if (await appModel.database.getEpubBook(key) case final EpubBookRow row
        when BookFormat.tryParse(row.format) == BookFormat.manga)
      row,
];
