/// 漫画有声（演出稿 / 标注 / 生成）控制通道路由与 AI 操作目录共用的装配：依赖注入、
/// 条目键校验、线上 JSON、改演出稿前后的快照与撤销恢复。
///
/// 路由（`ctl_tts_routes.dart`）与撤销（`op_descriptions_tts.dart`）都只经这里碰演出稿、
/// 成品清单与任务表，同一份逻辑；业务本体仍是制作台 / 复核页背后的那些函数：
/// - 读卷：[loadMangaAudioVolume]（OCR + 演出稿 + 系列声音）；
/// - 标注：进程级 [MangaAnnotateTasks]（复核页同一张任务表）；
/// - 整卷生成：全应用唯一的制作队列（制作台「生成」同一入口）；
/// - 单句换种子：[regenerateMangaLine] + 引擎 [MangaAudioRenderer.keepCandidate]
///   （制作台「换种子重生成 → 保留」同一对函数）。保留之前把旧音频备份到
///   `<db>/manga_audio/_undo/<sha1(bookKey)>/`，撤销时放回去（AI 听不了候选，撤销就是
///   制作台的「撤回」）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart' show sha1;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/cast/cast_line_direction.dart';
import 'package:fushi_engine/tts/cast/cast_line_voicing.dart';
import 'package:fushi_engine/tts/cast/series_cast.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate.dart'
    show mergedMangaRoster;
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate_ledger.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_narrator.dart'
    show MangaNarratorVoice;
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render_plan.dart'
    show MangaRenderItem;
import 'package:fushi_engine/tts/manga_audio/manga_audio_renderer.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_validate.dart'
    show resolveMangaLineText;
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/src/ai/ai_manga_audio_assistant.dart'
    show resolveMangaAudioProvider;
import 'package:fushi/src/media/audiobook/tts/cast/series_cast_resolver.dart'
    show resolveSeriesKey, seriesCastStoreFor;
import 'package:fushi/src/media/audiobook/tts/irodori_voice_packs.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_series_cast.dart'
    show ttsVoicingStoreFor;
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_service.dart'
    show ttsRenderQueueFor;
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_annotate_flow.dart'
    show
        hasMangaAudioUploadConsent,
        kMangaAudioUploadConsentKey,
        kMangaAudioUploadConsentVersion,
        mangaLineNeedsReview;
import 'package:fushi/src/media/manga/audio/manga_audio_annotate_tasks.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_library.dart'
    show updateMangaAudioLine;
import 'package:fushi/src/media/manga/audio/manga_audio_package_tasks.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_render_service.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_stores.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/ctl_library_entries.dart';
import 'package:fushi/src/ops/op_context.dart';

/// 路由根：`/api/admin/tts/manga/:key/...`（CLI：`fushi_cli tts ...`）。
const String kTtsMangaCtlRoot = '/api/admin/tts/manga';

/// 可选的声音列表（声音指派、整卷生成的 voice 参数从这里取 id）。
const String kTtsVoicesCtlPath = '/api/admin/tts/voices';

/// 单句重生成撤销用的旧音频备份，每卷最多留这么多份（最旧的先删；删掉的那次撤销
/// 报「旧音频备份已清理」）。
const int kMangaRegenBackupLimit = 50;

/// 单句重生成：换种子合成一个候选（不改清单 / 演出稿）。
typedef MangaLineRegenerator =
    Future<MangaRegenerateCandidate> Function(
      MangaAudioVolume volume, {
      required String lineId,
      required int seed,
      required String voice,
    });

/// 路由与撤销共用的依赖。测试经 [debugOverrideTtsCtlDeps] 换假实现。
class TtsCtlDeps {
  TtsCtlDeps({
    required this.app,
    required this.annotateTasks,
    required this.renderQueue,
    required this.provider,
    required this.hasUploadConsent,
    required this.recordUploadConsent,
    required this.voices,
    required this.activeVoice,
    required this.regenerate,
    required this.stopPlayback,
    required this.localAudioBackend,
    MangaAudioPackageTasks Function()? packageTasks,
    String Function()? appLabel,
  }) : packageTasks = packageTasks ?? (() => MangaAudioPackageTasks.instance),
       appLabel = appLabel ?? (() => 'fushi');

  factory TtsCtlDeps.of(OpContext context) => TtsCtlDeps(
    app: () => context.appModel,
    annotateTasks: () => mangaAnnotateTasksFor(context.appModel),
    renderQueue: () => ttsRenderQueueFor(context.appModel),
    provider: () => resolveMangaAudioProvider(context.appModel),
    hasUploadConsent: hasMangaAudioUploadConsent,
    recordUploadConsent: () async => (await SharedPreferences.getInstance())
        .setInt(kMangaAudioUploadConsentKey, kMangaAudioUploadConsentVersion),
    voices: () => ttsProductionPresets(
      TtsServices.of(context.appModel.prefsRepo),
      context.appModel,
    ),
    activeVoice: () =>
        TtsServices.of(context.appModel.prefsRepo).store.activePreset()?.id,
    regenerate:
        (
          MangaAudioVolume volume, {
          required String lineId,
          required int seed,
          required String voice,
        }) => regenerateMangaLine(
          context.appModel,
          volume: volume,
          lineId: lineId,
          seed: seed,
          defaultVoice: voice,
          cancel: TtsRenderCancelToken(),
        ),
    stopPlayback: (List<String> bookKeys) =>
        context.appModel.audiobookSession.stopIfPlayingAny(bookKeys),
    localAudioBackend: mangaLocalAudioBackend,
    appLabel: () => 'fushi ${context.appModel.packageInfo.version}',
  );

  final AppModel Function() app;
  final MangaAnnotateTasks Function() annotateTasks;
  final TtsRenderQueue Function() renderQueue;

  /// 指派给「漫画演出标注」的 AI 提供商；null = 没指派 / 不可用（不发请求）。
  final AiProviderConfig? Function() provider;
  final Future<bool> Function() hasUploadConsent;
  final Future<void> Function() recordUploadConsent;

  /// 能选的声音（声音预设 + 声音包参考音频组，制作台同一份）。
  final List<TtsVoicePreset> Function() voices;

  List<String> voiceIds() => <String>[
    for (final TtsVoicePreset v in voices()) v.id,
  ];

  /// 当前朗读声音（没有任务记录时整卷生成用它）。
  final String? Function() activeVoice;
  final MangaLineRegenerator regenerate;

  /// 停掉这些书的播放（换句文件前；Windows 上被占用的文件换不掉）。
  final Future<void> Function(List<String> bookKeys) stopPlayback;

  /// 「按句替换本地音频」整形用的后端（只整形本地音频；ffmpeg 不可用抛
  /// [TtsRenderFailure]）。
  final Future<MangaRenderBackend> Function() localAudioBackend;

  /// 有声漫画导出包的任务表（工作台同一张，默认进程级那张）。
  final MangaAudioPackageTasks Function() packageTasks;

  /// 导出包里记的导出方（`fushi <版本>`）。
  final String Function() appLabel;

  /// 标注任务结束时演出稿的指纹（`<bookKey>@<startedAt>` → 指纹）：撤销标注时据此判断
  /// 之后有没有被手改过。进程内有效；app 重启后撤销报 superseded，不盲目覆盖。
  final Map<String, Future<String?>> annotateResults =
      <String, Future<String?>>{};

  AppModel get appModel => app();

  /// 一卷生成该用的声音：这卷最近一次任务的声音 → 当前朗读声音（制作台同一顺序），
  /// 不在可选声音里的跳过。
  String? defaultVoiceFor(String bookKey) {
    final Set<String> ids = voiceIds().toSet();
    for (final String? id in <String?>[
      renderQueue().latestFor(bookKey)?.presetId,
      activeVoice(),
    ]) {
      if (id != null && ids.contains(id)) return id;
    }
    return null;
  }
}

final Expando<TtsCtlDeps> _depsByContext = Expando<TtsCtlDeps>('ttsCtlDeps');

/// [context] 上的依赖（路由与 `op_descriptions_tts.dart` 的撤销共用同一份）。
TtsCtlDeps ttsCtlDeps(OpContext context) =>
    _depsByContext[context] ??= TtsCtlDeps.of(context);

/// 测试：给 [context] 换上假依赖。
@visibleForTesting
void debugOverrideTtsCtlDeps(OpContext context, TtsCtlDeps deps) =>
    _depsByContext[context] = deps;

// ─────────────────────────────────────────────────────────────────────────
// 门与键
// ─────────────────────────────────────────────────────────────────────────

/// 漫画模块开着（漫画有声挂在漫画模块下；本地漫画不受 iOS 上架合规门约束）。
void requireTtsMangaModule(TtsCtlDeps deps) {
  if (!deps.appModel.moduleEnabled(ModuleId.manga)) {
    throw const CtlFailure.rejected('漫画模块已在设置里关闭');
  }
}

void requireTtsWritable(TtsCtlDeps deps) {
  if (deps.appModel.isMigrationReadonly) {
    throw const CtlFailure.rejected('数据已迁移到新版，旧版处于只读状态');
  }
}

/// 路径里的条目键 → 本地漫画卷的 bookKey。格式不对 400、没有 404、不是本地漫画卷 422。
Future<String> ttsMangaBookKey(TtsCtlDeps deps, String raw) async {
  final LibraryCtlKey? key = LibraryCtlKey.tryParse(raw);
  if (key == null || key.store != LibraryCtlStore.book) {
    throw CtlFailure.badRequest('漫画条目键应为 book:<bookKey>，收到「$raw」');
  }
  final EpubBookRow? row = await deps.appModel.database.getEpubBook(key.id);
  if (row == null) throw CtlFailure.notFound('书架里没有 ${key.wire}');
  if (BookFormat.parseOrEpub(row.format) != BookFormat.manga) {
    throw CtlFailure.rejected('${key.wire} 不是漫画');
  }
  if (!isLocalMangaVolume(row)) {
    throw CtlFailure.rejected('${key.wire} 是在线作品，漫画有声只支持本地卷');
  }
  return row.bookKey;
}

/// 这一卷所属的系列（没有为 null）。
Future<String?> ttsMangaSeriesKey(TtsCtlDeps deps, String bookKey) =>
    resolveSeriesKey(deps.appModel, bookKey);

String ttsMangaWireKey(String bookKey) =>
    LibraryCtlKey(LibraryCtlStore.book, bookKey).wire;

/// 载入一卷；`manga.json` 读不出 422。
Future<MangaAudioVolume> loadTtsMangaVolume(
  TtsCtlDeps deps,
  String bookKey,
) async {
  final MangaAudioVolume? volume = await loadMangaAudioVolume(
    deps.appModel,
    bookKey,
  );
  if (volume == null) {
    throw CtlFailure.rejected('${ttsMangaWireKey(bookKey)} 读不出 OCR 结果（先识别文字）');
  }
  return volume;
}

/// 本卷标注在跑时不许改演出稿 / 生成（标注会整页覆盖，复核页同样锁住编辑）。
void requireNotAnnotating(TtsCtlDeps deps, String bookKey) {
  if (deps.annotateTasks().isRunning(bookKey)) {
    throw const CtlFailure.conflict('这一卷正在标注，等它结束或先取消（tts annotate-cancel）');
  }
}

/// 本卷正在导入有声漫画包（导入任务占着它，解包到落库结束）时不许标注 / 生成 / 改演出稿
/// 或成品：导入会整份替换演出稿、成品与登记，两边会互相覆盖。
void requireNotImportingPackage(TtsCtlDeps deps, String bookKey) {
  if (deps.packageTasks().importingVolume(bookKey) != null) {
    throw const CtlFailure.conflict('这一卷正在导入有声漫画包，等它结束（tts package-task）');
  }
}

/// 本卷有在排队 / 在跑的生成任务时不许换句文件。
void requireNotRendering(TtsCtlDeps deps, String bookKey) {
  final TtsRenderJob? job = deps.renderQueue().latestFor(bookKey);
  if (job != null && !job.isTerminal) {
    throw const CtlFailure.conflict('这一卷正在生成，等它结束或先取消（tts render-cancel）');
  }
}

/// 改单句 / 换本地音频 / 按角色重生成要改的那份成品清单（[mangaAudioEditTarget]）：
/// 登记的是哪份就改哪份——本机生成的、或 `tts import` 导入的外部清单（原地改写用户
/// 目录里的清单与音频，拍板 isATnQZ_eN-external）；没登记（只生成没入库）改本机那份，
/// 之后按它整份登记。登记的是广播剧 / 动画音轨成品时 409：那些段不是按演出稿逐句出的，
/// 改本机清单再按句写库会把两份清单的句子混进同一份登记。判据与 app 内入口共用
/// [mangaLineEditTarget]。
Future<MangaAudioEditTarget> requireLineEditableAudio(
  TtsCtlDeps deps,
  String bookKey,
) async {
  try {
    return await mangaLineEditTarget(deps.appModel, bookKey);
  } on TtsRenderFailure catch (e) {
    if (e.code != kMangaAudioDramaFailure) rethrow;
    throw const CtlFailure(
      409,
      kMangaAudioDramaFailure,
      '这一卷登记的有声成品是广播剧 / 动画音轨（段不是按演出稿逐句出的），不能按句改：'
      '先整卷生成（tts render）换成合成成品',
    );
  }
}

/// 撤销载荷里记下的那份清单（操作当时改的就是它）；旧载荷没记时按当前登记找。
Future<MangaAudioEditTarget> mangaUndoTarget(
  AppModel appModel,
  String bookKey,
  Object? manifestPath,
) async => manifestPath is String && manifestPath.isNotEmpty
    ? MangaAudioEditTarget.forManifest(appModel, bookKey, File(manifestPath))
    : mangaAudioEditTarget(appModel, bookKey);

/// 说话人的线上名：旁白 / 不明用 `narrator` / `unknown`。
String ttsSpeakerWire(String speaker) => switch (speaker) {
  kTtsNarrator => 'narrator',
  kTtsUnknown => 'unknown',
  _ => speaker,
};

/// 线上名 → 演出稿里的说话人。
String ttsSpeakerFromWire(String wire) => switch (wire) {
  'narrator' || kTtsNarrator => kTtsNarrator,
  'unknown' || kTtsUnknown => kTtsUnknown,
  _ => wire,
};

/// 1 起的页码 → 0 起下标；越界 400。
int ttsMangaPageIndex(Object? raw, int pageCount) {
  final int? page = raw is int ? raw : int.tryParse('${raw ?? ''}'.trim());
  if (page == null || page < 1 || page > pageCount) {
    throw CtlFailure.badRequest('页码应为 1..$pageCount，收到「$raw」');
  }
  return page - 1;
}

// ─────────────────────────────────────────────────────────────────────────
// 线上 JSON
// ─────────────────────────────────────────────────────────────────────────

List<MokuroBlock> _blocksOf(MangaAudioVolume volume, int page) =>
    page >= 0 && page < volume.payload.images.length
    ? volume.payload.images[page].blocks
    : const <MokuroBlock>[];

/// 一句的线上 JSON（页码 1 起；`id` 是稳定行身份，改行 / 重生成都按它）。
Map<String, Object?> ttsMangaLineJson(
  MangaAudioVolume volume,
  MangaScriptLine line,
) => <String, Object?>{
  'id': line.lineId,
  'page': line.page + 1,
  'blocks': line.blocks,
  'text': resolveMangaLineText(line, _blocksOf(volume, line.page)),
  'speaker': ttsSpeakerWire(line.speaker),
  'kind': line.kind.wire,
  if (line.beatMs != 0) 'beatMs': line.beatMs,
  if (line.emotion != null) 'emotion': line.emotion!.wire,
  if (line.intensity != null) 'intensity': line.intensity,
  if (line.tone != null) 'tone': line.tone,
  if (line.seed != null) 'seed': line.seed,
  if (line.say != null) 'say': line.say,
  if (line.textFixes.isNotEmpty)
    'fixes': <String, String>{
      for (final MapEntry<int, String> e in line.textFixes.entries)
        '${e.key}': e.value,
    },
  if (line.voice != null) 'voice': line.voice,
  'audio': switch (line.audio) {
    MangaLocalAudio(:final String? name) => <String, Object?>{
      'type': 'file',
      'name': ?name,
    },
    MangaAudiobookClip() => <String, Object?>{'type': 'audiobook'},
    MangaSynthesized() => <String, Object?>{'type': 'synth'},
  },
  'source': line.source.name,
  if (line.confidence != null) 'confidence': line.confidence,
  'needsReview': mangaLineNeedsReview(line),
};

/// 某卷演出稿摘要：角色表、行数、未定说话人数、需不需要重新标注。
Map<String, Object?> ttsMangaScriptSummary(
  MangaAudioVolume volume, {
  required bool rendered,
}) {
  final MangaAudioScript script = volume.script;
  final Map<String, TtsCastCharacter> roster = mergedMangaRoster(
    series: volume.series?.roster ?? const <String, TtsCastCharacter>{},
    volume: script.roster,
  );
  final Map<String, int> counts = <String, int>{};
  for (final MangaScriptLine l in script.lines) {
    counts[l.speaker] = (counts[l.speaker] ?? 0) + 1;
  }
  return <String, Object?>{
    'key': ttsMangaWireKey(volume.bookKey),
    'title': volume.row.title,
    'pages': volume.payload.images.length,
    'annotatedPages': script.annotatedPages.length,
    'lines': script.lines.length,
    'audibleLines': script.audibleLines.length,
    'unknownSpeakerLines': <MangaScriptLine>[
      for (final MangaScriptLine l in script.lines)
        if (l.kind.isAudible && l.speaker == kTtsUnknown) l,
    ].length,
    'needsReviewLines': script.lines.where(mangaLineNeedsReview).length,
    'needsReannotation':
        volume.freshness == MangaScriptFreshness.needsReannotation,
    'defaultSeed': script.defaultSeed,
    'sourcePolicy': script.sourcePolicy.wire,
    if (volume.seriesKey != null) 'series': volume.seriesKey,
    'rendered': rendered,
    'narrationVoice': script.voiceFor(
      MangaScriptLine(
        page: 0,
        blocks: const <int>[0],
        speaker: kTtsNarrator,
        kind: CastLineKind.narration,
      ),
    ),
    'defaultVoice': script.voices.defaultVoice ?? script.series?.defaultVoice,
    'roster': <Map<String, Object?>>[
      for (final TtsCastCharacter c in roster.values)
        <String, Object?>{
          'name': c.name,
          if (c.aliases.isNotEmpty) 'aliases': c.aliases,
          if (c.gender != null) 'gender': c.gender,
          if (c.age != null) 'age': c.age,
          if (c.description != null) 'description': c.description,
          'lines': counts[c.name] ?? 0,
          if (script.voices.byCharacter[c.name] ??
                  script.series?.byCharacter[c.name]
              case final String voice)
            'voice': voice,
          if (_kindVoices(script, c.name) case final Map<String, String> kinds
              when kinds.isNotEmpty)
            'kindVoices': kinds,
        },
    ],
  };
}

Map<String, String> _kindVoices(MangaAudioScript script, String name) =>
    <String, String>{
      for (final MapEntry<CastLineKind, String> e in <CastLineKind, String>{
        ...?script.series?.byCharacterKind[name],
        ...?script.voices.byCharacterKind[name],
      }.entries)
        e.key.wire: e.value,
    };

/// 标注任务的线上 JSON。
Map<String, Object?> ttsAnnotateTaskJson(MangaAnnotateTask task) =>
    <String, Object?>{
      'taskId': ttsMangaWireKey(task.bookKey),
      'status': task.status.name,
      if (task.phase != null) 'phase': task.phase!.name,
      'done': task.progressDone,
      'total': task.progressTotal,
      'failures': task.failures.length,
      if (task.cancelRequested) 'cancelRequested': true,
      if (task.errorCode != null) 'error': task.errorCode,
      if (task.summary case final summary?)
        'summary': <String, Object?>{
          'annotatedPages': summary.annotatedPages.length,
          'failedPages': <int>[for (final int p in summary.failedPages) p + 1],
          'rejectedLines': summary.rejectedLines,
          'reviewedLines': summary.reviewedLines,
        },
      'startedAt': task.startedAt.millisecondsSinceEpoch,
      if (task.finishedAt != null)
        'finishedAt': task.finishedAt!.millisecondsSinceEpoch,
    };

/// 生成任务的线上 JSON（`id` 是队列任务 id）。
Map<String, Object?> ttsRenderJobJson(TtsRenderJob job) => <String, Object?>{
  'id': job.id,
  'status': job.status.name,
  if (job.phase != null) 'phase': job.phase!.name,
  'done': job.done,
  'total': job.total,
  'voice': job.presetId,
  if (job.lineRequests.isNotEmpty) 'backfillLines': job.lineRequests.length,
  if (job.unvoiced > 0) 'unvoiced': job.unvoiced,
  if (job.error != null) 'error': job.error,
  'createdAt': job.createdAt,
  'updatedAt': job.updatedAt,
};

// ─────────────────────────────────────────────────────────────────────────
// 演出稿快照
// ─────────────────────────────────────────────────────────────────────────

/// 演出稿落盘内容的指纹（撤销前判断之后有没有被改过）。
String ttsScriptFingerprint(MangaAudioScript script) =>
    sha1.convert(utf8.encode(jsonEncode(script.toJson()))).toString();

/// 盘上演出稿的指纹。
Future<String> ttsStoredScriptFingerprint(
  TtsCtlDeps deps,
  String bookKey,
) async => ttsScriptFingerprint(
  await mangaAudioScriptStoreFor(deps.appModel).load(bookKey),
);

/// 某页的行（落盘 JSON，保持顺序）。
List<Object?> ttsPageLinesJson(MangaAudioScript script, int page) => <Object?>[
  for (final MangaScriptLine l in script.linesOnPage(page)) l.toJson(),
];

/// 某页的指纹（行的落盘 JSON）。
String ttsPageRevision(MangaAudioScript script, int page) => sha1
    .convert(utf8.encode(jsonEncode(ttsPageLinesJson(script, page))))
    .toString();

/// 改一句前的快照：这一句所在页的行。行不在 404。
Future<Map<String, Object?>> captureMangaLineSnapshot(
  TtsCtlDeps deps,
  String bookKey,
  String lineId,
) async {
  final MangaAudioScript script = await mangaAudioScriptStoreFor(
    deps.appModel,
  ).load(bookKey);
  final MangaScriptLine? line = script.lineById(lineId);
  if (line == null) throw CtlFailure.notFound('演出稿里没有这一句：$lineId');
  return <String, Object?>{
    'bookKey': bookKey,
    'page': line.page,
    'before': ttsPageLinesJson(script, line.page),
  };
}

/// 把第 [page] 页的行整体换成 [lines]（页内顺序即朗读顺序），插在原来那一页的位置。
void replaceMangaPageLines(
  MangaAudioScript script,
  int page,
  List<MangaScriptLine> lines,
) {
  int at = script.lines.indexWhere((MangaScriptLine l) => l.page == page);
  script.lines.removeWhere((MangaScriptLine l) => l.page == page);
  if (at < 0 || at > script.lines.length) {
    at = script.lines.lastIndexWhere((MangaScriptLine l) => l.page < page) + 1;
  }
  script.lines.insertAll(at, lines);
}

List<MangaScriptLine> _linesFromJson(Object? raw) => <MangaScriptLine>[
  if (raw is List)
    for (final Object? l in raw)
      if (MangaScriptLine.fromJson(l) case final MangaScriptLine line) line,
];

/// 改一句的结果（撤销载荷要的前后两份页快照都在里面）。
class TtsLineEdit {
  const TtsLineEdit({
    required this.page,
    required this.line,
    required this.revision,
    this.addedCharacter,
  });

  final int page;
  final MangaScriptLine line;

  /// 改完后这一页的指纹（[ttsPageRevision]）：撤销前比对，之后又被改过就不覆盖。
  final String revision;

  /// 这次顺手加进本卷角色表的新角色（撤销时若没人再用就删掉）。
  final String? addedCharacter;
}

/// 线上「不标语气」的写法（`tts.manga.line.edit` 的 `emotion`）。
const String kTtsEmotionNone = 'none';

/// 改一句：说话人 / 类型 / 一拍 / 语气与强度 / 语气说明 / 页内位置 / 手填文字 / OCR 错字修正。改过的行记为
/// 用户手改（重新标注时保留，复核页同一语义）。参数不对抛 400，行不在 404。
TtsLineEdit editMangaLine(
  MangaAudioVolume volume,
  String lineId,
  Map<String, Object?> body,
) {
  final MangaAudioScript script = volume.script;
  final MangaScriptLine? old = script.lineById(lineId);
  if (old == null) throw CtlFailure.notFound('演出稿里没有这一句：$lineId');
  final int page = old.page;
  MangaScriptLine next = old;
  bool changed = false;
  String? added;

  final Object? speakerRaw = body['speaker'];
  if (speakerRaw != null) {
    final String speaker = ttsSpeakerFromWire('$speakerRaw'.trim());
    if (speaker.isEmpty) throw const CtlFailure.badRequest('speaker 不能为空');
    final Map<String, TtsCastCharacter> roster = mergedMangaRoster(
      series: volume.series?.roster ?? const <String, TtsCastCharacter>{},
      volume: script.roster,
    );
    final bool known =
        speaker == kTtsNarrator ||
        speaker == kTtsUnknown ||
        roster.containsKey(speaker);
    if (!known) {
      if (body['newCharacter'] != true) {
        throw CtlFailure.badRequest(
          '角色表里没有「$speaker」（可选：narrator / unknown / '
          '${roster.keys.join(' / ')}；确实是新角色加 newCharacter=true）',
        );
      }
      mergeCastRoster(script.roster, <TtsCastCharacter>[
        TtsCastCharacter(name: speaker),
      ]);
      added = speaker;
    }
    next = next.copyWith(speaker: speaker);
    changed = true;
  }

  final Object? kindRaw = body['kind'];
  if (kindRaw != null) {
    final CastLineKind? kind = CastLineKind.parse('$kindRaw'.trim());
    if (kind == null) {
      throw CtlFailure.badRequest(
        'kind 可选：${CastLineKind.values.map((CastLineKind k) => k.wire).join(' / ')}',
      );
    }
    next = next.copyWith(kind: kind);
    changed = true;
  }

  final Object? beatRaw = body['beat'];
  if (beatRaw != null) {
    final int? beat = beatRaw is int ? beatRaw : int.tryParse('$beatRaw');
    if (beat == null || beat < 0 || beat > MangaScriptLimits.maxBeatMs) {
      throw CtlFailure.badRequest(
        'beat 应为 0..${MangaScriptLimits.maxBeatMs} 毫秒',
      );
    }
    next = next.copyWith(beatMs: beat);
    changed = true;
  }

  // 语气（情绪）与强度：进合成（2026-11-23 起；能原生表达情绪的引擎直接用，其余折成
  // 语速 / 音高 / 音量）。改了之后整卷生成按清单行的演出指纹重出这句。`none` / 空串
  // 清掉情绪（强度随之清掉）。
  if (body.containsKey('emotion')) {
    final String raw = '${body['emotion'] ?? ''}'.trim();
    if (raw.isEmpty || raw == kTtsEmotionNone) {
      next = next.copyWith(clearEmotion: true);
    } else {
      final CastEmotion? emotion = CastEmotion.parse(raw);
      if (emotion == null) {
        throw CtlFailure.badRequest(
          'emotion 可选：$kTtsEmotionNone / '
          '${CastEmotion.values.map((CastEmotion e) => e.wire).join(' / ')}',
        );
      }
      next = next.copyWith(emotion: emotion);
    }
    changed = true;
  }

  if (body.containsKey('intensity')) {
    final Object? raw = body['intensity'];
    final int? parsed = raw is int ? raw : int.tryParse('${raw ?? ''}'.trim());
    // -1 / null / 空串 = 不标强度（操作目录会丢掉值为 null 的参数，所以另给 -1）。
    if (raw == null || '$raw'.trim().isEmpty || parsed == -1) {
      next = next.copyWith(clearIntensity: true);
    } else {
      final int? intensity = parsed;
      if (intensity == null ||
          intensity < 0 ||
          intensity > CastLineLimits.maxIntensity) {
        throw CtlFailure.badRequest(
          'intensity 应为 0..${CastLineLimits.maxIntensity}（-1 = 不标强度）',
        );
      }
      if (next.emotion == null) {
        throw const CtlFailure.badRequest('这一句没有语气，强度要和 emotion 一起给');
      }
      next = next.copyWith(intensity: intensity);
    }
    changed = true;
  }

  // 语气说明（自由文本演技指令，如「おずおずと」）：空串清掉；超长截断（[castToneOf]）。
  if (body.containsKey('tone')) {
    final Object? toneRaw = body['tone'];
    if (toneRaw != null && toneRaw is! String) {
      throw const CtlFailure.badRequest('tone 应为文字（空串 = 清掉）');
    }
    final String? tone = castToneOf(toneRaw);
    next = tone == null
        ? next.copyWith(clearTone: true)
        : next.copyWith(tone: tone);
    changed = true;
  }

  if (body.containsKey('say')) {
    final String say = '${body['say'] ?? ''}'.trim();
    next = say.isEmpty
        ? next.copyWith(clearSay: true)
        : next.copyWith(say: say);
    changed = true;
  }

  final Object? fixesRaw = body['fixes'];
  if (fixesRaw != null) {
    if (fixesRaw is! Map) {
      throw const CtlFailure.badRequest('fixes 应为 {块下标: 修正后的文字}');
    }
    final Map<int, String> fixes = Map<int, String>.of(next.textFixes);
    for (final MapEntry<Object?, Object?> e in fixesRaw.entries) {
      final int? block = int.tryParse('${e.key}');
      if (block == null || !next.blocks.contains(block)) {
        throw CtlFailure.badRequest(
          'fixes 的键应是这一句的块下标（${next.blocks.join(', ')}），收到「${e.key}」',
        );
      }
      final String text = '${e.value ?? ''}'.trim();
      if (text.isEmpty) {
        fixes.remove(block);
      } else {
        fixes[block] = text;
      }
    }
    next = next.copyWith(textFixes: fixes);
    changed = true;
  }

  final List<MangaScriptLine> onPage = script.linesOnPage(page);
  final int from = onPage.indexWhere((MangaScriptLine l) => l.lineId == lineId);
  int to = from;
  final Object? positionRaw = body['position'];
  if (positionRaw != null) {
    final int? position = positionRaw is int
        ? positionRaw
        : int.tryParse('$positionRaw');
    if (position == null || position < 1 || position > onPage.length) {
      throw CtlFailure.badRequest('position 应为 1..${onPage.length}（页内第几句）');
    }
    to = position - 1;
    changed = true;
  }

  if (!changed) {
    throw const CtlFailure.badRequest(
      '没有要改的字段（speaker / kind / beat / emotion / intensity / tone / say / '
      'fixes / position）',
    );
  }
  next = next.copyWith(source: TtsCastSource.user);
  final List<MangaScriptLine> page2 = List<MangaScriptLine>.of(onPage)
    ..removeAt(from)
    ..insert(to, next);
  replaceMangaPageLines(script, page, page2);
  return TtsLineEdit(
    page: page,
    line: next,
    revision: ttsPageRevision(script, page),
    addedCharacter: added,
  );
}

/// 撤销「改一句」：这一页还是改完时的样子才放回改之前的行；之后又被改过报 superseded。
Future<OpUndoOutcome> revertMangaLineEdit(
  TtsCtlDeps deps,
  Map<String, Object?> payload,
) async {
  final String bookKey = '${payload['bookKey']}';
  final int page = payload['page'] is int ? payload['page']! as int : -1;
  if (deps.annotateTasks().isRunning(bookKey)) {
    return const OpUndoOutcome.failed('这一卷正在标注，结束后再撤销');
  }
  final MangaAudioScriptStore store = mangaAudioScriptStoreFor(deps.appModel);
  final MangaAudioScript script = await store.load(bookKey);
  if (ttsPageRevision(script, page) != payload['revision']) {
    return const OpUndoOutcome.superseded('这一页之后又被改过，没有覆盖');
  }
  replaceMangaPageLines(script, page, _linesFromJson(payload['before']));
  final Object? added = payload['addedCharacter'];
  if (added is String &&
      !script.lines.any((MangaScriptLine l) => l.speaker == added)) {
    script.roster.remove(added);
  }
  await store.save(bookKey, script);
  return const OpUndoOutcome.done();
}

/// 改某角色的结果。
class TtsCharacterEdit {
  const TtsCharacterEdit({
    required this.name,
    required this.renamedLines,
    required this.revision,
    this.seriesKey,
    this.seriesRevision,
  });

  /// 改完后的名字（改名时是新名字）。
  final String name;
  final int renamedLines;

  /// 改完后本卷演出稿的指纹。
  final String revision;

  /// 写到系列档案时：系列、改完后系列声音指派的指纹。
  final String? seriesKey;
  final String? seriesRevision;
}

/// 改某角色：改名 / 合并（只改本卷：行、本卷角色表、本卷声音指派），以及声音指派
/// （`scope` = volume 只这一卷，series 写系列档案、下一卷沿用）。改完落盘。
Future<TtsCharacterEdit> editMangaCharacter(
  TtsCtlDeps deps,
  MangaAudioVolume volume,
  String rawName,
  Map<String, Object?> body,
) async {
  final MangaAudioScript script = volume.script;
  final String name = ttsSpeakerFromWire(rawName.trim());
  final Map<String, TtsCastCharacter> roster = mergedMangaRoster(
    series: volume.series?.roster ?? const <String, TtsCastCharacter>{},
    volume: script.roster,
  );
  final bool isNarrator = name == kTtsNarrator;
  if (!isNarrator &&
      !roster.containsKey(name) &&
      !script.lines.any((MangaScriptLine l) => l.speaker == name)) {
    throw CtlFailure.notFound('角色表里没有「$rawName」');
  }
  final String? renameRaw = body['rename'] == null
      ? null
      : '${body['rename']}'.trim();
  final bool hasVoice = body.containsKey('voice');
  if (renameRaw == null && !hasVoice) {
    throw const CtlFailure.badRequest('没有要改的字段（rename / voice）');
  }
  String? voice;
  CastLineKind? kind;
  bool seriesScope = false;
  if (hasVoice) {
    final String v = '${body['voice'] ?? ''}'.trim();
    voice = v.isEmpty ? null : v;
    if (voice != null && !deps.voiceIds().contains(voice)) {
      throw CtlFailure.badRequest('没有声音「$voice」（见 tts voices / 制作台的声音列表）');
    }
    final Object? kindRaw = body['kind'];
    if (kindRaw != null && !isNarrator) {
      kind = CastLineKind.parse('$kindRaw'.trim());
      if (kind == null || kind == CastLineKind.skip) {
        throw const CtlFailure.badRequest('kind 应为会发声的台词类型');
      }
    }
    final String scope = '${body['scope'] ?? 'volume'}'.trim();
    if (scope != 'volume' && scope != 'series') {
      throw const CtlFailure.badRequest('scope 只能是 volume 或 series');
    }
    seriesScope = scope == 'series';
    if (seriesScope && volume.seriesKey == null) {
      throw const CtlFailure.rejected('这一卷不属于任何系列，只能 scope=volume');
    }
  }
  if (renameRaw != null) {
    if (isNarrator) throw const CtlFailure.badRequest('旁白不能改名');
    if (renameRaw.isEmpty) throw const CtlFailure.badRequest('rename 不能为空');
  }

  String current = name;
  int renamed = 0;
  if (renameRaw != null) {
    final String to = ttsSpeakerFromWire(renameRaw);
    if (to == name) throw const CtlFailure.badRequest('新名字与原名相同');
    for (int i = 0; i < script.lines.length; i++) {
      if (script.lines[i].speaker == name) {
        script.lines[i] = script.lines[i].copyWith(
          speaker: to,
          source: TtsCastSource.user,
        );
        renamed++;
      }
    }
    final TtsCastCharacter? gone = script.roster.remove(name) ?? roster[name];
    if (to != kTtsUnknown && to != kTtsNarrator) {
      mergeCastRoster(script.roster, <TtsCastCharacter>[
        TtsCastCharacter(
          name: to,
          aliases: <String>[name, ...?gone?.aliases],
          gender: gone?.gender,
          age: gone?.age,
          description: gone?.description,
        ),
      ]);
    }
    script.voices.renameCharacter(name, to);
    current = to;
  }

  void assign(CastVoiceAssignment target) {
    if (isNarrator || current == kTtsNarrator) {
      target.narrationVoice = voice;
    } else if (kind != null) {
      final Map<CastLineKind, String> kinds = target.byCharacterKind
          .putIfAbsent(current, () => <CastLineKind, String>{});
      if (voice == null) {
        kinds.remove(kind);
      } else {
        kinds[kind] = voice;
      }
      if (kinds.isEmpty) target.byCharacterKind.remove(current);
    } else if (voice == null) {
      target.byCharacter.remove(current);
    } else {
      target.byCharacter[current] = voice;
    }
  }

  String? seriesRevision;
  final String? seriesKey = volume.seriesKey;
  if (hasVoice && !seriesScope) assign(script.voices);
  if (hasVoice && seriesScope && seriesKey != null) {
    final SeriesCastProfile fresh = await seriesCastStoreFor(deps.appModel)
        .update(seriesKey, (SeriesCastProfile profile) {
          assign(profile.voices);
          seriesRevision = ttsVoicesFingerprint(profile.voices);
        });
    volume.series = fresh;
    script.series = fresh.voices;
  }
  await mangaAudioScriptStoreFor(deps.appModel).save(volume.bookKey, script);
  return TtsCharacterEdit(
    name: current,
    renamedLines: renamed,
    revision: ttsScriptFingerprint(script),
    seriesKey: seriesScope ? seriesKey : null,
    seriesRevision: seriesRevision,
  );
}

String ttsVoicesFingerprint(CastVoiceAssignment voices) =>
    sha1.convert(utf8.encode(jsonEncode(voices.toJson()))).toString();

/// 改某角色前的快照：本卷演出稿整份，以及（写系列时）系列的声音指派。
Future<Map<String, Object?>> captureMangaCharacterSnapshot(
  TtsCtlDeps deps,
  String bookKey,
  String? seriesKey,
) async => <String, Object?>{
  'bookKey': bookKey,
  'before': (await mangaAudioScriptStoreFor(
    deps.appModel,
  ).load(bookKey)).toJson(),
  if (seriesKey != null) ...<String, Object?>{
    'seriesKey': seriesKey,
    'seriesBefore': (await seriesCastStoreFor(
      deps.appModel,
    ).load(seriesKey)).voices.toJson(),
  },
};

void _assignInPlace(CastVoiceAssignment target, CastVoiceAssignment source) {
  target
    ..defaultVoice = source.defaultVoice
    ..narrationVoice = source.narrationVoice;
  target.byCharacter
    ..clear()
    ..addAll(source.byCharacter);
  target.byCharacterKind
    ..clear()
    ..addAll(source.byCharacterKind);
  target.retryVoices
    ..clear()
    ..addAll(source.retryVoices);
}

/// 撤销「改某角色」：演出稿还是改完时的样子才整份放回；系列档案的声音指派同理。
Future<OpUndoOutcome> revertMangaCharacterEdit(
  TtsCtlDeps deps,
  Map<String, Object?> payload,
) async {
  final String bookKey = '${payload['bookKey']}';
  if (deps.annotateTasks().isRunning(bookKey)) {
    return const OpUndoOutcome.failed('这一卷正在标注，结束后再撤销');
  }
  final MangaAudioScriptStore store = mangaAudioScriptStoreFor(deps.appModel);
  final MangaAudioScript current = await store.load(bookKey);
  if (ttsScriptFingerprint(current) != payload['revision']) {
    return const OpUndoOutcome.superseded('演出稿之后又被改过，没有覆盖');
  }
  final Object? seriesKey = payload['seriesKey'];
  final Object? seriesRevision = payload['seriesRevision'];
  if (seriesKey is String && seriesRevision is String) {
    bool superseded = false;
    await seriesCastStoreFor(deps.appModel).update(seriesKey, (
      SeriesCastProfile profile,
    ) {
      if (ttsVoicesFingerprint(profile.voices) != seriesRevision) {
        superseded = true;
        return;
      }
      _assignInPlace(
        profile.voices,
        CastVoiceAssignment.fromJson(payload['seriesBefore']),
      );
    });
    if (superseded) {
      return const OpUndoOutcome.superseded('系列的声音指派之后又被改过，没有覆盖');
    }
  }
  await store.save(bookKey, MangaAudioScript.fromJson(payload['before']));
  return const OpUndoOutcome.done();
}

// ─────────────────────────────────────────────────────────────────────────
// 标注
// ─────────────────────────────────────────────────────────────────────────

/// 标注前的快照（演出稿 + 失败账本落盘 JSON）。
Future<Map<String, Object?>> captureMangaAnnotateSnapshot(
  TtsCtlDeps deps,
  String bookKey,
) async => <String, Object?>{
  'script': (await mangaAudioScriptStoreFor(
    deps.appModel,
  ).load(bookKey)).toJson(),
  'ledger': (await mangaAnnotationLedgerStoreFor(
    deps.appModel,
  ).load(bookKey)).toJson(),
};

String ttsAnnotateRunId(MangaAnnotateTask task) =>
    '${task.bookKey}@${task.startedAt.millisecondsSinceEpoch}';

/// 任务结束时记下演出稿指纹（撤销时比对）。
void watchMangaAnnotateResult(TtsCtlDeps deps, MangaAnnotateTask task) {
  deps.annotateResults[ttsAnnotateRunId(task)] = task.finished.then(
    (_) => ttsStoredScriptFingerprint(deps, task.bookKey),
  );
}

/// 撤销「发起标注」：还在跑就先取消并等它停下；然后（标完之后没被改过时）把演出稿与
/// 失败账本放回标注前的样子。系列档案里学到的角色不撤（只增不改，下一卷照样有用）。
Future<OpUndoOutcome> revertMangaAnnotate(
  TtsCtlDeps deps,
  Map<String, Object?> payload,
) async {
  final String bookKey = '${payload['bookKey']}';
  final String runId = '${payload['runId']}';
  final MangaAnnotateTasks tasks = deps.annotateTasks();
  final MangaAnnotateTask? running = tasks.runningFor(bookKey);
  if (running != null) {
    if (ttsAnnotateRunId(running) != runId) {
      return const OpUndoOutcome.superseded('这一卷正在跑另一次标注，没有动它');
    }
    tasks.cancel(bookKey);
    await running.finished;
  }
  final Future<String?>? settled = deps.annotateResults[runId];
  if (settled == null) {
    return const OpUndoOutcome.superseded('app 重启过，无法确认标注后有没有被手改，没有覆盖');
  }
  final String? fingerprint = await settled;
  if (fingerprint == null ||
      fingerprint != await ttsStoredScriptFingerprint(deps, bookKey)) {
    return const OpUndoOutcome.superseded('标注之后演出稿又被改过，没有覆盖');
  }
  await mangaAudioScriptStoreFor(
    deps.appModel,
  ).save(bookKey, MangaAudioScript.fromJson(payload['script']));
  await mangaAnnotationLedgerStoreFor(
    deps.appModel,
  ).save(bookKey, MangaAnnotationLedger.fromJson(payload['ledger']));
  deps.annotateResults.remove(runId);
  return const OpUndoOutcome.done();
}

// ─────────────────────────────────────────────────────────────────────────
// 单句换种子重生成
// ─────────────────────────────────────────────────────────────────────────

/// 这一卷撤销用的旧音频备份目录（单句重生成一份一个文件；批量操作一份一个子目录，
/// 见 `ctl_tts_batch.dart`）。
Directory mangaCtlBackupDir(AppModel appModel, String bookKey) => Directory(
  p.join(
    mangaAudioRoot(appModel).path,
    '_undo',
    sha1.convert(utf8.encode(bookKey)).toString(),
  ),
);

/// 重生成前的快照：清单里这一句、演出稿这一行、未配音账本里这一句（占位时才有）。
Future<Map<String, Object?>> captureMangaRegenSnapshot(
  TtsCtlDeps deps,
  String bookKey,
  String lineId,
) async {
  final File manifestFile = (await mangaAudioEditTarget(
    deps.appModel,
    bookKey,
  )).manifestFile;
  final MangaRenderManifest? manifest = await MangaRenderManifest.load(
    manifestFile,
  );
  final MangaScriptLine? scriptLine = (await mangaAudioScriptStoreFor(
    deps.appModel,
  ).load(bookKey)).lineById(lineId);
  final CastVoicingLedger ledger = await ttsVoicingStoreFor(
    deps.appModel,
  ).load(bookKey);
  MangaRenderedLine? rendered;
  for (final MangaRenderedLine l in manifest?.lines ?? <MangaRenderedLine>[]) {
    if (l.lineId == lineId) rendered = l;
  }
  return <String, Object?>{
    'manifest': manifestFile.path,
    'oldLine': rendered?.toJson(),
    'oldScriptLine': scriptLine?.toJson(),
    'ledgerEntry': ledger.entries[lineId]?.toJson(),
  };
}

/// 换种子重生成并直接保留（AI 听不了候选；撤回 = 撤销这次操作）。保留前把旧音频
/// 备份起来供撤销放回。
Future<Map<String, Object?>> regenerateAndKeepMangaLine(
  TtsCtlDeps deps,
  MangaAudioVolume volume, {
  required MangaAudioEditTarget target,
  required String lineId,
  required int? seed,
}) async {
  final AppModel appModel = deps.appModel;
  final String bookKey = volume.bookKey;
  final MangaScriptLine? line = volume.script.lineById(lineId);
  if (line == null) throw CtlFailure.notFound('演出稿里没有这一句：$lineId');
  final File manifestFile = target.manifestFile;
  final MangaRenderManifest? manifest = await MangaRenderManifest.load(
    manifestFile,
  );
  MangaRenderedLine? old;
  for (final MangaRenderedLine l in manifest?.lines ?? <MangaRenderedLine>[]) {
    if (l.lineId == lineId) old = l;
  }
  if (manifest == null || old == null) {
    throw const CtlFailure.rejected('这一句还没生成过，先整卷生成（tts render）');
  }
  final String? voice = deps.defaultVoiceFor(bookKey);
  if (voice == null) {
    throw const CtlFailure.rejected('没有可用的声音（先在朗读设置里选一个声音）');
  }
  if (seed != null && (seed < 0 || seed > MangaScriptLimits.maxSeed)) {
    throw const CtlFailure.badRequest(
      'seed 应为 0..${MangaScriptLimits.maxSeed}',
    );
  }
  final int useSeed = seed ?? math.Random().nextInt(MangaScriptLimits.maxSeed);
  final MangaRegenerateCandidate candidate;
  try {
    candidate = await deps.regenerate(
      volume,
      lineId: lineId,
      seed: useSeed,
      voice: voice,
    );
  } on MangaLineFailure catch (e) {
    throw CtlFailure(422, e.code, '重生成失败：${e.code}');
  } on TtsRenderFailure catch (e) {
    throw CtlFailure(422, e.code, '重生成失败：${e.code}');
  }

  final MangaAudioRenderer renderer = target.renderer(
    const TtsCtlNoSynthesis(),
  );
  // 旧音频备份（保留候选时清单不再引用它，会被清掉）。
  final File oldFile = File(p.join(manifestFile.parent.path, old.file));
  String? backup;
  if (await oldFile.exists()) {
    final Directory dir = mangaCtlBackupDir(appModel, bookKey);
    await dir.create(recursive: true);
    backup = '${DateTime.now().microsecondsSinceEpoch}-${old.file}';
    await oldFile.copy(p.join(dir.path, backup));
    await pruneMangaCtlBackups(dir);
  }
  await deps.stopPlayback(<String>[bookKey]);
  final CastVoicingStore voicing = ttsVoicingStoreFor(appModel);
  final CastVoicingLedger ledger = await voicing.load(bookKey);
  final bool kept = await renderer.keepCandidate(
    script: volume.script,
    manifest: manifest,
    ledger: ledger,
    candidate: candidate,
  );
  if (!kept) {
    if (backup != null) {
      await deleteMangaFileQuietly(
        File(p.join(mangaCtlBackupDir(appModel, bookKey).path, backup)),
      );
    }
    throw CtlFailure.notFound('这一句已不在成品清单里：$lineId');
  }
  await mangaAudioScriptStoreFor(appModel).save(bookKey, volume.script);
  await voicing.save(bookKey, ledger);
  await updateMangaAudioLine(
    appModel.database,
    bookKey: bookKey,
    manifestFile: manifestFile,
    manifest: manifest,
    lineId: lineId,
  );
  return <String, Object?>{
    'key': ttsMangaWireKey(bookKey),
    'lineId': lineId,
    'seed': candidate.seed,
    if (old.seed != null) 'previousSeed': old.seed,
    'durationMs': candidate.durationMs,
    'voice': candidate.voice,
    'text': candidate.text,
    'file': candidate.file,
    if (backup != null) 'backup': backup,
  };
}

/// 撤销「换音」类操作（单句重生成 / 按角色批量重生成 / 换本地音频）时清单这一句只放回
/// 音频本身：文件、时长、占位、声音、种子、念的文字与整形版本都随那段旧音频一起回去；
/// 说话人 / 类型 / 一拍等演出字段保留当前值（之后被独立改过的不被抹掉，HBK-AUDIT-208）。
MangaRenderedLine mangaRenderedAudioRestored(
  MangaRenderedLine current,
  MangaRenderedLine before,
) => current.replaced(
  file: before.file,
  durationMs: before.durationMs,
  placeholder: before.placeholder,
  voice: before.voice,
  seed: before.seed,
  text: before.text,
  spoken: before.spoken,
  shape: before.shape,
  direction: before.direction,
);

/// 撤销「换音」类操作时演出稿这一句只放回这次操作改过的字段：音源（[MangaScriptLine.audio]）
/// 总是；种子只在 [seed] 为 true（换种子重生成）时。停顿、说话人、手填文字、错字修正、
/// 单句声音等之后被独立改过的字段保留当前值（HBK-AUDIT-208）。
MangaScriptLine mangaScriptAudioRestored(
  MangaScriptLine current,
  MangaScriptLine before, {
  required bool seed,
}) => current.copyWith(
  audio: before.audio,
  seed: seed ? before.seed : null,
  clearSeed: seed && before.seed == null,
);

/// 撤销「单句重生成」：清单里这一句还是这次的候选文件时，把备份的旧音频放回去，清单、
/// 演出稿这一行、未配音账本都恢复到重生成之前。
Future<OpUndoOutcome> revertMangaRegen(
  TtsCtlDeps deps,
  Map<String, Object?> payload,
) async {
  final AppModel appModel = deps.appModel;
  final String bookKey = '${payload['bookKey']}';
  final String lineId = '${payload['lineId']}';
  final MangaRenderedLine? oldLine = MangaRenderedLine.fromJson(
    payload['oldLine'],
  );
  if (oldLine == null) return const OpUndoOutcome.failed('没有旧音频的记录');
  final TtsRenderJob? job = deps.renderQueue().latestFor(bookKey);
  if (job != null && !job.isTerminal) {
    return const OpUndoOutcome.failed('这一卷正在生成，结束后再撤销');
  }
  final MangaAudioEditTarget target = await mangaUndoTarget(
    appModel,
    bookKey,
    payload['manifest'],
  );
  final File manifestFile = target.manifestFile;
  final MangaRenderManifest? manifest = await MangaRenderManifest.load(
    manifestFile,
  );
  MangaRenderedLine? current;
  for (final MangaRenderedLine l in manifest?.lines ?? <MangaRenderedLine>[]) {
    if (l.lineId == lineId) current = l;
  }
  if (manifest == null || current == null || current.file != payload['file']) {
    return const OpUndoOutcome.superseded('这一句之后又重新生成过，没有覆盖');
  }
  final Object? backup = payload['backup'];
  final File? backupFile = backup is String
      ? File(p.join(mangaCtlBackupDir(appModel, bookKey).path, backup))
      : null;
  if (backupFile == null || !await backupFile.exists()) {
    return const OpUndoOutcome.failed('旧音频备份已清理，恢复不了');
  }
  await deps.stopPlayback(<String>[bookKey]);
  await backupFile.copy(p.join(manifestFile.parent.path, oldLine.file));
  manifest.replaceLine(
    lineId,
    (MangaRenderedLine now) => mangaRenderedAudioRestored(now, oldLine),
  );
  await manifest.save(manifestFile);

  final MangaAudioScriptStore scripts = mangaAudioScriptStoreFor(appModel);
  final MangaAudioScript script = await scripts.load(bookKey);
  final MangaScriptLine? before = MangaScriptLine.fromJson(
    payload['oldScriptLine'],
  );
  final MangaScriptLine? now = script.lineById(lineId);
  if (before != null && now != null && now.seed == payload['seed']) {
    script.replaceLine(
      lineId,
      (MangaScriptLine l) => mangaScriptAudioRestored(l, before, seed: true),
    );
    await scripts.save(bookKey, script);
  }
  final CastVoicingEntry? entry = CastVoicingEntry.fromJson(
    payload['ledgerEntry'],
  );
  if (entry != null) {
    final CastVoicingStore voicing = ttsVoicingStoreFor(appModel);
    final CastVoicingLedger ledger = await voicing.load(bookKey);
    ledger.entries[lineId] = entry;
    await voicing.save(bookKey, ledger);
  }
  await updateMangaAudioLine(
    appModel.database,
    bookKey: bookKey,
    manifestFile: manifestFile,
    manifest: manifest,
    lineId: lineId,
  );
  await target.renderer(const TtsCtlNoSynthesis()).sweepUnreferenced(manifest);
  await deleteMangaFileQuietly(backupFile);
  return const OpUndoOutcome.done();
}

/// 每卷备份最多留 [kMangaRegenBackupLimit] 份（单句的文件与批量的子目录各算一份，按
/// 名字里的时间戳从新到旧）；更旧的删掉，那几次撤销报「备份已清理」。
Future<void> pruneMangaCtlBackups(Directory dir) async {
  final List<FileSystemEntity> entries =
      <FileSystemEntity>[
        for (final FileSystemEntity e in dir.listSync())
          if (e is File || e is Directory) e,
      ]..sort(
        (FileSystemEntity a, FileSystemEntity b) =>
            p.basename(b.path).compareTo(p.basename(a.path)),
      );
  for (final FileSystemEntity stale in entries.skip(kMangaRegenBackupLimit)) {
    if (stale is File) {
      await deleteMangaFileQuietly(stale);
    } else {
      try {
        await stale.delete(recursive: true);
      } on FileSystemException {
        // 被占用（Windows）：留着，下次修剪再删。
      }
    }
  }
}

Future<void> deleteMangaFileQuietly(File f) async {
  try {
    if (await f.exists()) await f.delete();
  } on FileSystemException {
    // 被占用（Windows）：留着，下次修剪再删。
  }
}

/// 保留候选 / 清理只动文件与清单，不合成。
class TtsCtlNoSynthesis implements MangaRenderBackend {
  const TtsCtlNoSynthesis();

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
