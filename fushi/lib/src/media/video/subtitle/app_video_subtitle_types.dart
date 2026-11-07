/// 「生成字幕」目标的值类型与产物落点接口（视频库与音乐库共用）。
///
/// 从 `app_video_subtitle_service.dart` 拆出：服务本身读 AppModel，音乐库的落点 /
/// 目标解析只需要这些类型，经服务 import 会被拖进 AppModel 大环
/// （`test/build/import_cycle_guard_test.dart`）。服务 `export` 本文件，老调用方不变。
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show immutable;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart'
    show SubtitleWorkContext;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_pipeline.dart'
    show VideoSubtitleEpisodeResult;

import 'package:fushi/src/media/video/video_playback_remote.dart'
    show VideoRemoteJobKind;

/// 一集（视频库的一集，或音乐库的一个音频文件）。
@immutable
class AppVideoSubtitleEpisode {
  const AppVideoSubtitleEpisode({
    this.bookUid,
    required this.videoPath,
    required this.title,
    this.registersSubtitleSource = true,
    this.replacesSubtitleSelection = false,
    this.contentLanguage,
  });

  /// 视频库条目（`video_books.book_uid`）；音乐目标为 null（曲目归属由
  /// [AppSubtitleOutputSink] 按 [videoPath] 自己记）。
  final String? bookUid;

  /// 要转写的本地媒体文件（视频或音频；字段名沿用视频时代）。
  final String videoPath;
  final String title;

  /// 用户给这一集设的内容语言（`VideoBooks.language`；没设 null）。只用来给字幕
  /// 语言定初值（[resolveVideoSubtitleLanguage]）。
  final String? contentLanguage;

  /// 导出后能否把字幕登记到这一行的 `subtitleSource`：播放列表里的子集共用一行，
  /// 那一行的字幕选择不属于其中某一集，不登记。
  final bool registersSubtitleSource;

  /// 登记时是否**替换**这一行已有的字幕选择。视频页对当前这一集点「生成日语字幕」
  /// 是用户明确要用生成的字幕：转录要好几分钟，用户常常先退出播放页，任务结束时页面
  /// 已不在、页面那条「结束后切成当前字幕」走不到，产物只能靠这里登记；若照整季 /
  /// CLI 的口径「已有选择不覆盖」，条目原本选着内嵌轨或下载字幕时，生成的字幕重进
  /// 播放页也不会被用上（用户反馈 DEStBY5I66）。整季与 CLI 仍不覆盖。
  final bool replacesSubtitleSelection;
}

/// 本机处理不了的一集（远端 / 文件不存在）。
enum AppVideoSubtitleUnavailableReason { remote, missingFile }

@immutable
class AppVideoSubtitleUnavailable {
  const AppVideoSubtitleUnavailable({
    this.bookUid,
    required this.title,
    required this.reason,
  });

  /// 视频库条目；音乐目标为 null。
  final String? bookUid;
  final String title;
  final AppVideoSubtitleUnavailableReason reason;
}

/// 一次生成的目标：单集（视频页 / CLI 的 bookUid）、整季（合集），或音乐库的曲目 /
/// 专辑 / 来源（[sink] 是音乐库的落点）。
@immutable
class AppVideoSubtitleTarget {
  const AppVideoSubtitleTarget({
    required this.title,
    required this.work,
    required this.episodes,
    this.unavailable = const <AppVideoSubtitleUnavailable>[],
    this.collectionId,
    this.bookUid,
    this.sink,
    this.trackCounts,
    bool? wholeSeason,
    String? key,
  }) : _wholeSeason = wholeSeason,
       _key = key;

  /// 音乐目标按**曲目**计数（[episodes] 是去重后的文件，CUE 整轨一个文件多首）：要写
  /// 字幕的曲目数与已有生成字幕、跳过的曲目数。视频目标为 null（按集计）。
  final ({int pending, int skipped})? trackCounts;

  final String title;
  final SubtitleWorkContext work;
  final List<AppVideoSubtitleEpisode> episodes;
  final List<AppVideoSubtitleUnavailable> unavailable;

  /// 整季目标的合集 id（单集为 null）。
  final int? collectionId;

  /// 单集目标的条目（整季为 null）。
  final String? bookUid;

  /// 产物落点；null = 视频库（[VideoBookSubtitleSink]，登记 `video_books.subtitleSource`）。
  final AppSubtitleOutputSink? sink;

  final bool? _wholeSeason;
  final String? _key;

  /// 批量（整季 / 整张专辑 / 整个来源）：已有导出字幕（`<媒体名>.<语言>.srt`）的集由
  /// 管线直接跳过，并做跨集一致性。显式给了就用给的；视频默认按「是不是合集目标」。
  bool get wholeSeason => _wholeSeason ?? collectionId != null;

  /// 进程内去重键（同一目标只能有一个任务）。
  String get key =>
      _key ??
      (collectionId != null
          ? 'collection:$collectionId'
          : 'book:$bookUid:${episodes.map((AppVideoSubtitleEpisode e) => e.videoPath).join('|')}');

  /// 给 CLI / 结果 JSON 看的目标名。
  String get describe => collectionId != null
      ? 'collection:$collectionId'
      : bookUid != null
      ? 'book:$bookUid'
      : key;

  List<String> get videoPaths => <String>[
    for (final AppVideoSubtitleEpisode e in episodes) e.videoPath,
  ];

  /// 作品身份没有刮削数据：UI 提示「建议先刮削」（只对视频有意义）。
  bool get missingScrapedData => !isMusic && !work.hasScrapedData;

  /// 音乐库目标（曲目 / 专辑 / 来源）。
  bool get isMusic => sink?.domain == AppSubtitleTargetDomain.music;
}

/// 生成目标属于哪个库。
enum AppSubtitleTargetDomain { video, music }

/// 生成产物落到哪个库：导出目录、证据、样式参考、远控镜像、登记都经它（视频库与
/// 音乐库共用同一个服务与管线，只有这里不同）。
abstract interface class AppSubtitleOutputSink {
  /// 落点属于哪个库（面板文案：「整季 / 集」还是「批量 / 首」）。
  AppSubtitleTargetDomain get domain;

  /// 字幕导出目录；null = 媒体文件旁（视频播放页的 sidecar 探测直接加载）。
  Directory? exportDirFor(String mediaPath);

  /// 是否按媒体旁已有的 ASS 另出一份带样式的 ASS（只对视频有意义）。
  bool get usesStyleReference;

  /// 远控镜像（`video job`）的种类与主体。
  VideoRemoteJobKind get mirrorKind;
  String mirrorSubject(AppVideoSubtitleTarget target);

  /// 除媒体旁 / 内嵌之外，这一集还登记在库里的人工字幕（证据）。
  Future<List<String>> extraEvidenceFiles(AppVideoSubtitleEpisode episode);

  /// 批量时导出位置已有字幕（管线跳过转写）的那一集也要登记：音乐的登记是按曲目的
  /// （CUE 整轨一个文件多首），文件已转写过、曲目却还没有 `asr` 行（单曲入口只写了一首、
  /// 整轨新增了曲目）时，直接用已有的导出文件补登，否则这些曲目永远登记不上。视频的
  /// 「已有字幕」可能是用户自己的文件，不替它登记。
  bool get registersSkippedExisting;

  /// 一集导出成功后登记产物；返回这次真正登记了的身份（视频条目 / 曲目）。
  Future<List<String>> register(
    AppVideoSubtitleEpisode episode,
    VideoSubtitleEpisodeResult result,
  );
}

/// 找不到要生成的目标（条目 / 合集不存在）。
class AppVideoSubtitleTargetNotFound implements Exception {
  const AppVideoSubtitleTargetNotFound(this.what);

  final String what;

  @override
  String toString() => 'AppVideoSubtitleTargetNotFound($what)';
}
