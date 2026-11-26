/// 整库补字幕：给库里**缺目标语言字幕**的集补上字幕（设计稿
/// `docs/specs/2026-11-26-library-subtitle-fill.md`）。
///
/// 每集按目标语言判一次（[judgeSubtitleCoverage]），再走最便宜的可用路径：
///
/// 1. 已有目标语言字幕（登记的文件 / 同目录 sidecar / 原盘托管文件）或用户显式
///    关了字幕 → 不动；
/// 2. 内封文本轨是目标语言 → 选中这条轨（登记 `embedded:<n>`）；
/// 3. 内封图形轨（PGS / VobSub）是目标语言 → 离线 OCR 成 SRT；
/// 4. 在线下载（[VideoSubtitleBackfillService]，身份取刮削结论）；原盘成员下到之后
///    **版本适配**：本地 ASR 转录一遍当参照，把 TV 版字幕逐句重定时到 BD 的时间轴
///    （BD 与 TV 版台词大体相同，差在剪辑），命中率不够就判「不是这个版本」改用
///    ASR 稿；
/// 5. 下不到 → 本地 ASR 生成（不校对、不发 AI 请求）。
///
/// 本层只做编排与落库登记；OCR / ASR / 重定时要 Flutter 侧的模型与 ffmpeg 后端，经
/// [LibrarySubtitleFillHost] 注入。全函数：单集失败只记进它自己的结果，不中断整批。
library;

import 'dart:io';

import 'package:fushi_audio/fushi_audio_core.dart' show decodeTextBytes;
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/foundation/engine_paths.dart' show enginePaths;
import 'package:fushi_engine/media/video/bitmap_subtitle/bitmap_subtitle_track.dart'
    show bitmapSubtitleCodecOf;
import 'package:fushi_engine/media/video/bluray/bluray_episode.dart'
    show parseBlurayEpisodePath;
import 'package:fushi_engine/media/video/bluray/bluray_probe.dart'
    show probeBlurayPlaylistFacts;
import 'package:fushi_engine/media/video/bluray/bluray_source.dart'
    show isBlurayPlaylistPath;
import 'package:fushi_engine/media/video/disc/disc_format.dart'
    show isDiscMemberPath, isDiscStreamFilePath;
import 'package:fushi_engine/media/video/download/download_confirmed_identity.dart'
    show DownloadConfirmedIdentityResolver;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:fushi_engine/media/video/subtitle/library_video_subtitle_backfill.dart'
    show libraryVideoSubtitleTarget;
import 'package:fushi_engine/media/video/subtitle/subtitle_content_language.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_language_preference.dart'
    show normalizeSubtitleLanguageCode;
import 'package:fushi_engine/media/video/subtitle/video_subtitle_backfill.dart';
import 'package:fushi_engine/media/video/video_duration_probe.dart';
import 'package:fushi_engine/media/video/video_local_files.dart'
    show isLocalVideoFilePath;
import 'package:fushi_engine/media/video/video_member_file.dart';
import 'package:fushi_engine/media/video/video_sidecar.dart'
    show listSidecarSubtitles, sidecarSubtitleLanguageTag;
import 'package:fushi_engine/media/video/video_subtitle_source.dart'
    show SubtitleSource;

// ---------------------------------------------------------------------------
// 判缺
// ---------------------------------------------------------------------------

/// 一集相对目标语言的字幕覆盖状态。
enum SubtitleCoverageKind {
  /// 已有目标语言字幕（登记的文件 / sidecar / 选中的目标语言内封轨）。
  covered,

  /// 用户显式关了字幕（`off:`）：尊重选择，不补。
  userDisabled,

  /// 有目标语言的内封文本轨，选上就行。
  embeddedText,

  /// 有目标语言的内封图形轨（PGS / VobSub），要 OCR。
  embeddedGraphic,

  /// 缺：要下载或生成。
  missing,
}

/// 一条内封字幕轨的事实（[SubtitleTrackFacts] 的子集，测试好造）。
class SubtitleFillTrack {
  const SubtitleFillTrack({
    required this.subtitleIndex,
    this.codec,
    this.language,
  });

  /// 字幕流相对序号（`embedded:<n>` 的 n）。
  final int subtitleIndex;
  final String? codec;
  final String? language;

  bool get isGraphic => bitmapSubtitleCodecOf(codec) != null;
}

/// [judgeSubtitleCoverage] 的结论。
class SubtitleCoverage {
  const SubtitleCoverage(this.kind, {this.trackIndex, this.detail});

  final SubtitleCoverageKind kind;

  /// [SubtitleCoverageKind.embeddedText] / [SubtitleCoverageKind.embeddedGraphic]
  /// 时是那条内封轨的相对序号。
  final int? trackIndex;

  /// 给人看的依据（哪个文件 / 哪条轨）。
  final String? detail;
}

/// **纯函数**：按目标语言 [wanted]（[normalizeSubtitleLanguageCode] 值域）判一集的
/// 覆盖状态。
///
/// - [subtitleSource]：库里存的字幕选择；
/// - [registeredFileLanguage]：选择是文件路径时，那份文件的语言（调用方按文件名
///   标记 / 正文判出；文件不在了传 null 且 [registeredFileExists] 为假）；
/// - [coveringFiles]：已经判过是目标语言的 sidecar / 托管文件名；
/// - [tracks]：内封轨。
///
/// 选中的内封轨不是目标语言、选中的文件不是目标语言或已经不在：都**不算**覆盖
/// ——用户要的是这种语言的字幕。
SubtitleCoverage judgeSubtitleCoverage({
  required String wanted,
  required String? subtitleSource,
  required bool registeredFileExists,
  required String? registeredFileLanguage,
  required List<String> coveringFiles,
  required List<SubtitleFillTrack> tracks,
}) {
  final String source = subtitleSource?.trim() ?? '';
  if (SubtitleSource.isOff(source)) {
    return const SubtitleCoverage(SubtitleCoverageKind.userDisabled);
  }
  if (source.isNotEmpty && SubtitleSource.isEmbeddedPersisted(source)) {
    final int? index = int.tryParse(
      source.substring(SubtitleSource.embeddedPrefix.length),
    );
    for (final SubtitleFillTrack track in tracks) {
      if (track.subtitleIndex == index &&
          normalizeSubtitleLanguageCode(track.language) == wanted) {
        return SubtitleCoverage(
          SubtitleCoverageKind.covered,
          trackIndex: index,
          detail: 'selected embedded track $index',
        );
      }
    }
  } else if (source.isNotEmpty &&
      registeredFileExists &&
      registeredFileLanguage == wanted) {
    return SubtitleCoverage(
      SubtitleCoverageKind.covered,
      detail: p.basename(source),
    );
  }
  if (coveringFiles.isNotEmpty) {
    return SubtitleCoverage(
      SubtitleCoverageKind.covered,
      detail: coveringFiles.first,
    );
  }
  for (final SubtitleFillTrack track in tracks) {
    if (track.isGraphic) continue;
    if (normalizeSubtitleLanguageCode(track.language) == wanted) {
      return SubtitleCoverage(
        SubtitleCoverageKind.embeddedText,
        trackIndex: track.subtitleIndex,
        detail:
            'embedded ${track.codec ?? 'text'} track ${track.subtitleIndex}',
      );
    }
  }
  for (final SubtitleFillTrack track in tracks) {
    if (!track.isGraphic) continue;
    if (normalizeSubtitleLanguageCode(track.language) == wanted) {
      return SubtitleCoverage(
        SubtitleCoverageKind.embeddedGraphic,
        trackIndex: track.subtitleIndex,
        detail: 'embedded ${track.codec} track ${track.subtitleIndex}',
      );
    }
  }
  return const SubtitleCoverage(SubtitleCoverageKind.missing);
}

/// **纯函数**：补上的字幕能不能顶替库里现在的选择（写进 `subtitle_source`）。
///
/// 只在「没选 / 选的文件已经不在 / 选的是别种语言的内封轨」时顶替；用户选了一份
/// 还在的别种语言**文件**时不动它（那是用户亲手放的，补上的字幕照样在轨道列表里）。
bool subtitleFillMayTakeSelection({
  required String? subtitleSource,
  required bool registeredFileExists,
}) {
  final String source = subtitleSource?.trim() ?? '';
  if (source.isEmpty) return true;
  if (SubtitleSource.isOff(source)) return false;
  if (SubtitleSource.isEmbeddedPersisted(source)) return true;
  return !registeredFileExists;
}

// ---------------------------------------------------------------------------
// 端口
// ---------------------------------------------------------------------------

/// 一集补字幕的对象。
class SubtitleFillItem {
  const SubtitleFillItem({required this.book, required this.isDisc});

  final VideoBookRow book;

  /// 原盘成员（蓝光 `.mpls` / 分集、DVD title）。
  final bool isDisc;

  String get bookUid => book.bookUid;
  String get videoPath => book.videoPath;
  String get title => book.title;
}

/// 一步产出了一份字幕文件（OCR / 生成 / 重定时）。
class SubtitleFillProduct {
  const SubtitleFillProduct({required this.path, this.registered = false});

  /// 落盘的字幕文件。
  final String path;

  /// 宿主已经把它登记成这一集的字幕源（生成管线的 sink 会自己登记）。
  final bool registered;
}

/// 重定时结果。
class SubtitleFillRetimed {
  const SubtitleFillRetimed({
    required this.path,
    required this.matchPercent,
    required this.medianShiftMs,
  });

  final String path;

  /// 命中锚点的句子占比（0..100）。
  final int matchPercent;
  final int medianShiftMs;
}

/// 一步做不成的原因（不是异常：模型没下、轨抽不出、识别不可用……）。
class SubtitleFillStepFailure implements Exception {
  const SubtitleFillStepFailure(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// 要 Flutter 侧模型 / ffmpeg 后端的三步。实现方失败抛 [SubtitleFillStepFailure]
/// （或任意异常，编排层一律记成这一步失败、往下一档走），取消抛
/// [SubtitlePipelineCancelled]。
abstract interface class LibrarySubtitleFillHost {
  /// 把第 [trackIndex] 条内封图形轨整轨 OCR 成 [language] 的 SRT。
  Future<SubtitleFillProduct> ocrGraphicTrack(
    SubtitleFillItem item,
    int trackIndex,
    String language,
    SubtitleCancelToken cancel,
  );

  /// 本地 ASR 生成 [language] 字幕（不校对、不发 AI 请求）。
  Future<SubtitleFillProduct> generate(
    SubtitleFillItem item,
    String language,
    SubtitleCancelToken cancel,
  );

  /// 拿 [referenceSrtPath]（本集的 ASR 稿）当参照，把 [subtitlePath] 逐句重定时，
  /// 写成一份新字幕文件。
  Future<SubtitleFillRetimed> retime(
    SubtitleFillItem item,
    String subtitlePath,
    String referenceSrtPath,
    SubtitleCancelToken cancel,
  );
}

// ---------------------------------------------------------------------------
// 结果
// ---------------------------------------------------------------------------

/// 一集最终怎么处理的。
enum SubtitleFillAction {
  /// 已有目标语言字幕。
  alreadyCovered,

  /// 用户关了字幕，跳过。
  userDisabled,

  /// 不是本机能处理的条目（流 / 远端 / 原盘里的散 m2ts / 被分集取代的整卷 /
  /// 媒体不在）。
  skipped,

  /// 只预览：会做什么（[SubtitleFillOutcome.plan]）。
  planned,

  /// 选中了目标语言的内封文本轨。
  selectedEmbedded,

  /// 内封图形轨 OCR 成了文字字幕。
  ocr,

  /// 在线下载。
  downloaded,

  /// 在线下载 + 按 ASR 逐句重定时（版本适配）。
  downloadedRetimed,

  /// 本地 ASR 生成。
  generated,

  /// 都没成。
  failed,

  /// 被取消（这一集没处理完）。
  cancelled,
}

/// 一集的处理结果。
class SubtitleFillOutcome {
  const SubtitleFillOutcome({
    required this.bookUid,
    required this.title,
    required this.videoPath,
    required this.action,
    this.path,
    this.plan,
    this.detail,
    this.matchPercent,
    this.previousSubtitleSource,
    this.selectionChanged = false,
    this.notes = const <String>[],
  });

  final String bookUid;
  final String title;
  final String videoPath;
  final SubtitleFillAction action;

  /// 这次产出 / 选中的字幕（文件路径或 `embedded:<n>`）。
  final String? path;

  /// 只预览时打算走的那一档。
  final SubtitleCoverageKind? plan;

  final String? detail;

  /// [SubtitleFillAction.downloadedRetimed] 的命中率。
  final int? matchPercent;

  /// 改写选择之前的 `subtitle_source`（撤销用）。
  final String? previousSubtitleSource;

  /// 这次写了 `subtitle_source`。
  final bool selectionChanged;

  /// 前面几档为什么没成（下载被拒的原因、OCR 不可用……），按顺序。
  final List<String> notes;

  /// 这次新写在盘上的文件（撤销时删）：选中内封轨不算。
  bool get wroteFile =>
      path != null &&
      const <SubtitleFillAction>{
        SubtitleFillAction.ocr,
        SubtitleFillAction.downloaded,
        SubtitleFillAction.downloadedRetimed,
        SubtitleFillAction.generated,
      }.contains(action);

  Map<String, Object?> toJson() => <String, Object?>{
    'bookUid': bookUid,
    'title': title,
    'videoPath': videoPath,
    'action': action.name,
    if (path != null) 'path': path,
    if (plan != null) 'plan': plan!.name,
    if (detail != null) 'detail': detail,
    if (matchPercent != null) 'matchPercent': matchPercent,
    if (selectionChanged) 'previousSubtitleSource': previousSubtitleSource,
    if (selectionChanged) 'selectionChanged': true,
    if (notes.isNotEmpty) 'notes': notes,
  };
}

/// 一次整库补字幕的选项。
class LibrarySubtitleFillOptions {
  const LibrarySubtitleFillOptions({
    required this.language,
    this.allowGenerate = true,
    this.allowOcr = true,
    this.allowDownload = true,
    this.retimeDiscDownloads = true,
    this.dryRun = false,
    this.minGenerateDurationMs = kSubtitleFillMinGenerateDurationMs,
  });

  /// 目标语言（[normalizeSubtitleLanguageCode] 值域，如 `ja`）。
  final String language;
  final bool allowGenerate;
  final bool allowOcr;
  final bool allowDownload;

  /// 原盘成员下到字幕后按 ASR 逐句重定时（要先跑一遍 ASR）。
  final bool retimeDiscDownloads;

  /// 只判、不做。
  final bool dryRun;

  /// 比这还短的条目不生成（片头片尾无字版、PV、菜单动画）。
  final int minGenerateDurationMs;
}

/// 短于 5 分钟的条目不跑 ASR 生成：原盘里这类多半是 NCOP / NCED / CM / PV，
/// 整批里它们占一半以上的条目，生成出来也没人看。
const int kSubtitleFillMinGenerateDurationMs = 5 * 60 * 1000;

/// 重定时命中率低于这个百分比就不信它：多半不是同一集 / 同一版本（同
/// `kRetimedSubtitleLowMatchRate`）。
const int kSubtitleFillMinRetimeMatchPercent = 40;

/// 进度回调：第 [done] 集 / 共 [total] 集，[current] 是刚处理完的那集。
typedef LibrarySubtitleFillProgress =
    void Function(int done, int total, SubtitleFillOutcome current);

// ---------------------------------------------------------------------------
// 选集
// ---------------------------------------------------------------------------

/// 整库补字幕要处理的条目：[bookUids] 为 null 取全库。去掉本机处理不了的
/// （没有本机媒体路径的流 / 远端条目、原盘里逐个入库的 m2ts，BUG-5280），以及
/// 已被分集成员取代的整卷播放列表（同目录有 `<同号>.pNN.mpls` 成员时，整卷那行
/// 只是「全部播放」，补它等于把每集再补一遍）。
Future<List<SubtitleFillItem>> librarySubtitleFillItems(
  FushiDatabase database, {
  Iterable<String>? bookUids,
}) async {
  final List<VideoBookRow> rows = bookUids == null
      ? await database.allVideoBooks()
      : await database.getVideoBooksByBookUids(bookUids.toList());
  final Set<String> splitVolumes = <String>{
    for (final VideoBookRow row in await database.allVideoBooks())
      if (parseBlurayEpisodePath(row.videoPath) != null)
        _splitVolumeKey(row.videoPath),
  };
  final List<SubtitleFillItem> items = <SubtitleFillItem>[];
  for (final VideoBookRow row in rows) {
    final String path = row.videoPath.trim();
    if (path.isEmpty || isDiscStreamFilePath(path)) continue;
    if (!isLocalVideoFilePath(path) && !isDiscMemberPath(path)) continue;
    if (isBlurayPlaylistPath(path) &&
        parseBlurayEpisodePath(path) == null &&
        splitVolumes.contains(p.normalize(path).toLowerCase())) {
      continue;
    }
    items.add(SubtitleFillItem(book: row, isDisc: isDiscMemberPath(path)));
  }
  items.sort(
    (SubtitleFillItem a, SubtitleFillItem b) =>
        a.videoPath.toLowerCase().compareTo(b.videoPath.toLowerCase()),
  );
  return items;
}

/// `…/00001.p03.mpls` → `…/00001.mpls`（小写、规范化），给整卷去重用。
String _splitVolumeKey(String episodePath) {
  final String dir = p.dirname(episodePath);
  final String name = p.basename(episodePath);
  final int dot = name.indexOf('.');
  return p
      .normalize(p.join(dir, '${name.substring(0, dot)}.mpls'))
      .toLowerCase();
}

// ---------------------------------------------------------------------------
// 编排
// ---------------------------------------------------------------------------

/// 整库补字幕的编排器。一次 [run] 串行处理全部条目（ASR 吃满 GPU，下载要守来源站
/// 的频率，并发没有收益）。
class LibrarySubtitleFill {
  LibrarySubtitleFill({
    required this.database,
    required this.host,
    required this.backfill,
    this.seriesLanguage,
    Future<VideoProbeFacts> Function(String path)? probe,
  }) : _probe = probe ?? probeSubtitleFillMediaFacts;

  final FushiDatabase database;
  final LibrarySubtitleFillHost host;

  /// 在线下载；null = 没有任何字幕来源（只做内封 / OCR / 生成）。
  final VideoSubtitleBackfillService? backfill;

  final String? Function(String seriesKey)? seriesLanguage;
  final Future<VideoProbeFacts> Function(String path) _probe;

  Future<List<SubtitleFillOutcome>> run(
    List<SubtitleFillItem> items,
    LibrarySubtitleFillOptions options, {
    SubtitleCancelToken cancel = const SubtitleNeverCancel(),
    LibrarySubtitleFillProgress? onProgress,
  }) async {
    final DownloadConfirmedIdentityResolver identities =
        DownloadConfirmedIdentityResolver(database);
    final List<SubtitleFillOutcome> out = <SubtitleFillOutcome>[];
    for (final SubtitleFillItem item in items) {
      SubtitleFillOutcome outcome;
      if (cancel.isCancelled) {
        outcome = _outcome(item, SubtitleFillAction.cancelled);
      } else {
        try {
          outcome = await _one(item, options, identities, cancel);
        } on SubtitlePipelineCancelled {
          outcome = _outcome(item, SubtitleFillAction.cancelled);
        } on Object catch (error) {
          outcome = _outcome(
            item,
            SubtitleFillAction.failed,
            detail: 'unexpected: $error',
          );
        }
      }
      out.add(outcome);
      onProgress?.call(out.length, items.length, outcome);
    }
    return out;
  }

  Future<SubtitleFillOutcome> _one(
    SubtitleFillItem item,
    LibrarySubtitleFillOptions options,
    DownloadConfirmedIdentityResolver identities,
    SubtitleCancelToken cancel,
  ) async {
    final String wanted =
        normalizeSubtitleLanguageCode(options.language) ?? options.language;
    final bool present = item.isDisc
        ? await hasLocalMediaFile(item.videoPath)
        : await videoPathFileExists(item.videoPath);
    if (!present) {
      return _outcome(
        item,
        SubtitleFillAction.skipped,
        detail: 'media is not on this device',
      );
    }
    // 每次从库里重读：前面的条目（同一张盘的整卷 / 用户同时在播放页操作）可能改了它。
    final VideoBookRow book =
        await database.getVideoBookByBookUid(item.bookUid) ?? item.book;
    final VideoProbeFacts facts = await _probe(item.videoPath);
    final List<SubtitleFillTrack> tracks = <SubtitleFillTrack>[
      for (int i = 0; i < facts.subtitleTracks.length; i++)
        SubtitleFillTrack(
          subtitleIndex: i,
          codec: facts.subtitleTracks[i].codec,
          language: facts.subtitleTracks[i].language,
        ),
    ];
    final String? source = book.subtitleSource?.trim();
    final bool sourceIsFile =
        source != null &&
        source.isNotEmpty &&
        !SubtitleSource.isOff(source) &&
        !SubtitleSource.isEmbeddedPersisted(source) &&
        !SubtitleSource.isHostSidecarPersisted(source);
    final bool registeredExists = sourceIsFile && await File(source).exists();
    final SubtitleCoverage coverage = judgeSubtitleCoverage(
      wanted: wanted,
      subtitleSource: source,
      registeredFileExists: registeredExists,
      registeredFileLanguage: registeredExists
          ? await subtitleFileLanguage(source, videoPath: item.videoPath)
          : null,
      coveringFiles: await _coveringFiles(item, wanted),
      tracks: tracks,
    );
    switch (coverage.kind) {
      case SubtitleCoverageKind.covered:
        return _outcome(
          item,
          SubtitleFillAction.alreadyCovered,
          detail: coverage.detail,
        );
      case SubtitleCoverageKind.userDisabled:
        return _outcome(item, SubtitleFillAction.userDisabled);
      case SubtitleCoverageKind.embeddedText ||
          SubtitleCoverageKind.embeddedGraphic ||
          SubtitleCoverageKind.missing:
        break;
    }
    if (options.dryRun) {
      return _outcome(
        item,
        SubtitleFillAction.planned,
        plan: coverage.kind,
        detail: coverage.detail,
      );
    }
    final bool mayTake = subtitleFillMayTakeSelection(
      subtitleSource: source,
      registeredFileExists: registeredExists,
    );

    if (coverage.kind == SubtitleCoverageKind.embeddedText) {
      final String selection =
          '${SubtitleSource.embeddedPrefix}${coverage.trackIndex}';
      return _finish(
        item,
        book,
        SubtitleFillAction.selectedEmbedded,
        selection,
        mayTake: mayTake,
        detail: coverage.detail,
      );
    }

    final List<String> notes = <String>[];
    if (coverage.kind == SubtitleCoverageKind.embeddedGraphic &&
        options.allowOcr) {
      try {
        final SubtitleFillProduct product = await host.ocrGraphicTrack(
          item,
          coverage.trackIndex!,
          wanted,
          cancel,
        );
        return await _finish(
          item,
          book,
          SubtitleFillAction.ocr,
          product.path,
          mayTake: mayTake && !product.registered,
          alreadyRegistered: product.registered,
          detail: coverage.detail,
        );
      } on SubtitlePipelineCancelled {
        rethrow;
      } on Object catch (error) {
        notes.add('ocr: $error');
      }
    }
    throwIfSubtitleCancelled(cancel);

    String? downloaded;
    final VideoSubtitleBackfillService? service = backfill;
    if (options.allowDownload &&
        service != null &&
        service.registry.providers.isNotEmpty) {
      final ({SubtitleBackfillTarget? target, String? reason}) built =
          await libraryVideoSubtitleTarget(
            database,
            book,
            confirmedIdentities: identities,
            explicitLanguage: wanted,
            seriesLanguage: seriesLanguage,
          );
      final SubtitleBackfillTarget? target = built.target;
      if (target == null) {
        notes.add('download: ${built.reason}');
      } else {
        // 判缺已经按语言判过了：库里的别种语言选择不挡这次下载。
        final SubtitleBackfillResult result = await service.backfill(
          target.withoutExistingSubtitleBlock(),
        );
        if (result.installed) {
          downloaded = result.installedPath;
        } else {
          notes.add(
            'download: ${result.outcome.name}'
            '${result.detail == null ? '' : ' (${result.detail})'}',
          );
        }
      }
    } else if (options.allowDownload) {
      notes.add('download: no online subtitle source is configured');
    }
    throwIfSubtitleCancelled(cancel);

    final bool longEnough =
        facts.durationMs == null ||
        facts.durationMs! >= options.minGenerateDurationMs;
    if (downloaded != null) {
      if (!(item.isDisc &&
          options.retimeDiscDownloads &&
          options.allowGenerate)) {
        return _finish(
          item,
          book,
          SubtitleFillAction.downloaded,
          downloaded,
          mayTake: mayTake,
          notes: notes,
        );
      }
      // 原盘版本适配：ASR 稿既是参照，也是命中率不够时的退路——只识别一遍。
      final SubtitleFillProduct reference;
      try {
        reference = await host.generate(item, wanted, cancel);
      } on SubtitlePipelineCancelled {
        rethrow;
      } on Object catch (error) {
        notes.add('retime: asr failed: $error');
        return _finish(
          item,
          book,
          SubtitleFillAction.downloaded,
          downloaded,
          mayTake: mayTake,
          notes: notes,
        );
      }
      try {
        final SubtitleFillRetimed retimed = await host.retime(
          item,
          downloaded,
          reference.path,
          cancel,
        );
        if (retimed.matchPercent >= kSubtitleFillMinRetimeMatchPercent) {
          await _deleteQuietly(downloaded);
          return await _finish(
            item,
            book,
            SubtitleFillAction.downloadedRetimed,
            retimed.path,
            // 生成管线的 sink 可能已经把 ASR 稿登记上了：那一份是这次写的，顶掉它。
            mayTake: mayTake || reference.registered,
            matchPercent: retimed.matchPercent,
            detail: 'median shift ${retimed.medianShiftMs} ms',
            notes: notes,
          );
        }
        notes.add(
          'retime: only ${retimed.matchPercent}% of lines matched; '
          'the downloaded subtitle is not this version, using ASR',
        );
        await _deleteQuietly(retimed.path);
      } on SubtitlePipelineCancelled {
        rethrow;
      } on Object catch (error) {
        notes.add('retime: $error');
      }
      await _deleteQuietly(downloaded);
      return _finish(
        item,
        book,
        SubtitleFillAction.generated,
        reference.path,
        mayTake: mayTake && !reference.registered,
        alreadyRegistered: reference.registered,
        notes: notes,
      );
    }

    if (!options.allowGenerate) {
      return _outcome(
        item,
        SubtitleFillAction.failed,
        detail: 'nothing to download and generation is off',
        notes: notes,
      );
    }
    if (!longEnough) {
      return _outcome(
        item,
        SubtitleFillAction.skipped,
        detail: 'too short to generate (likely an extra)',
        notes: notes,
      );
    }
    try {
      final SubtitleFillProduct product = await host.generate(
        item,
        wanted,
        cancel,
      );
      return await _finish(
        item,
        book,
        SubtitleFillAction.generated,
        product.path,
        mayTake: mayTake && !product.registered,
        alreadyRegistered: product.registered,
        notes: notes,
      );
    } on SubtitlePipelineCancelled {
      rethrow;
    } on Object catch (error) {
      notes.add('generate: $error');
      return _outcome(
        item,
        SubtitleFillAction.failed,
        detail: 'generate failed',
        notes: notes,
      );
    }
  }

  /// 已经判过是目标语言的字幕文件：原盘看托管目录里自己的那份，普通文件看
  /// 同目录 sidecar（标了语言按标记，没标读正文）。
  Future<List<String>> _coveringFiles(
    SubtitleFillItem item,
    String wanted,
  ) async {
    if (item.isDisc) {
      final Directory dir = await subtitleFillManagedDirectory();
      if (!await dir.exists()) return const <String>[];
      final String stem = managedDiscSubtitleStem(item.bookUid);
      return <String>[
        await for (final FileSystemEntity e in dir.list())
          if (e is File &&
              normalizeSubtitleLanguageCode(
                    sidecarSubtitleLanguageTag(stem, p.basename(e.path)),
                  ) ==
                  wanted)
            p.basename(e.path),
      ];
    }
    final Directory dir = File(item.videoPath).parent;
    final List<String> names;
    try {
      names = <String>[
        await for (final FileSystemEntity e in dir.list())
          if (e is File) p.basename(e.path),
      ];
    } on FileSystemException {
      return const <String>[];
    }
    final List<String> out = <String>[];
    for (final String name in listSidecarSubtitles(
      p.basenameWithoutExtension(item.videoPath),
      names,
    )) {
      final String? language = await subtitleFileLanguage(
        p.join(dir.path, name),
        videoPath: item.videoPath,
      );
      if (language == wanted) out.add(name);
    }
    return out;
  }

  /// 收尾：按 [mayTake] 登记选择，组结果。
  Future<SubtitleFillOutcome> _finish(
    SubtitleFillItem item,
    VideoBookRow book,
    SubtitleFillAction action,
    String path, {
    required bool mayTake,
    bool alreadyRegistered = false,
    int? matchPercent,
    String? detail,
    List<String> notes = const <String>[],
  }) async {
    bool changed = alreadyRegistered;
    if (mayTake) {
      await database.updateVideoBookSubtitleSource(item.bookUid, path);
      changed = true;
    } else if (!alreadyRegistered) {
      // 用户选着一份还在的别种语言文件：不动它。普通文件的 sidecar 会出现在轨道
      // 列表里；原盘托管文件没有登记就找不到，只能在报告里说清楚。
      notes = <String>[
        ...notes,
        'kept your current subtitle selection; pick the new one in the track list',
      ];
    }
    return SubtitleFillOutcome(
      bookUid: item.bookUid,
      title: item.title,
      videoPath: item.videoPath,
      action: action,
      path: path,
      detail: detail,
      matchPercent: matchPercent,
      previousSubtitleSource: book.subtitleSource,
      selectionChanged: changed,
      notes: notes,
    );
  }

  static SubtitleFillOutcome _outcome(
    SubtitleFillItem item,
    SubtitleFillAction action, {
    String? detail,
    SubtitleCoverageKind? plan,
    List<String> notes = const <String>[],
  }) => SubtitleFillOutcome(
    bookUid: item.bookUid,
    title: item.title,
    videoPath: item.videoPath,
    action: action,
    detail: detail,
    plan: plan,
    notes: notes,
  );

  static Future<void> _deleteQuietly(String path) async {
    try {
      final File file = File(path);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // 清不掉的中间产物只是多一个文件，不影响结果。
    }
  }
}

/// 撤销一次整库补字幕：删掉这次新写的文件，把改过的 `subtitle_source` 还原。
/// 用户之后又改过选择的那一集不还原（只还原仍指向这次产物的）。返回还原的集数。
Future<int> undoLibrarySubtitleFill(
  FushiDatabase database,
  List<SubtitleFillOutcome> outcomes,
) async {
  int undone = 0;
  for (final SubtitleFillOutcome o in outcomes) {
    final String? path = o.path;
    if (path == null) continue;
    bool touched = false;
    if (o.selectionChanged) {
      final VideoBookRow? row = await database.getVideoBookByBookUid(o.bookUid);
      if (row != null && row.subtitleSource == path) {
        await database.updateVideoBookSubtitleSource(
          o.bookUid,
          o.previousSubtitleSource,
        );
        touched = true;
      }
    }
    if (o.wroteFile) {
      try {
        final File file = File(path);
        if (await file.exists()) {
          await file.delete();
          touched = true;
        }
      } on FileSystemException {
        // 删不掉就留着；选择已经还原。
      }
    }
    if (touched) undone++;
  }
  return undone;
}

/// 原盘托管字幕目录（`video_subtitles/`）。
Future<Directory> subtitleFillManagedDirectory() =>
    enginePaths.videoSubtitlesDirectory();

/// 字幕文件的语言：文件名语言标记（相对 [videoPath] 的主干，或原盘托管主干）优先，
/// 没标就读正文判（[detectSubtitleContentLanguage]）。读不动 / 判不出返回 null。
Future<String?> subtitleFileLanguage(
  String path, {
  required String videoPath,
}) async {
  final String name = p.basename(path);
  final String? tag =
      sidecarSubtitleLanguageTag(p.basenameWithoutExtension(videoPath), name) ??
      _genericLanguageTag(name);
  final String? fromTag = normalizeSubtitleLanguageCode(tag);
  if (fromTag != null) return fromTag;
  try {
    final String text = await decodeTextBytes(await File(path).readAsBytes());
    return coarseLanguageCode(detectSubtitleContentLanguage(text));
  } on FileSystemException {
    return null;
  }
}

/// `<任意>.<tag>.<ext>` 的 tag（导入副本池里的文件名不以视频主干开头）。只认
/// 2～3 个字母或带地区 / 书写系统的语言形，`Show - 01.retimed.srt` 这类不当语言。
String? _genericLanguageTag(String fileName) {
  final RegExpMatch? m = RegExp(
    r'\.([A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{2,4})?)\.(srt|ass|ssa|vtt)$',
    caseSensitive: false,
  ).firstMatch(fileName);
  return m?.group(1);
}

/// 探一集的容器事实：蓝光播放列表直接读 MPLS 的流表（不起 ffprobe，原盘的 PGS 轨
/// 语言都写在 STN 表里），其余走 ffprobe。
Future<VideoProbeFacts> probeSubtitleFillMediaFacts(String path) =>
    isBlurayPlaylistPath(path)
    ? probeBlurayPlaylistFacts(path)
    : probeVideoFacts(path);
