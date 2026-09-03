/// 「刮削完成 → 给缺字幕的视频自动补字幕」。
///
/// 为什么这件事必须挂在刮削后面，而不是继续让用户去播放页一集集点：
/// 刮削是**全仓唯一一处真正解析出规范身份**（AniList / TMDB / Bangumi id + 日文
/// 原名）的地方。而字幕搜索的准确率几乎完全取决于身份准不准——播放页那条路拿
/// 「文件名解析出的系列名」去 AniList 现搜，中文译名 + 季度 + 篇名长串在 AniList
/// 必然 0 结果。刮削已经把答案算出来了，字幕侧却重新猜一遍，这是纯粹的浪费。
///
/// 边界：
/// - **只补缺的**，绝不覆盖任何已有字幕（sidecar 或 DB 里的 subtitleSource）。
///   用户手放/手改过的字幕是不可再生的。
/// - 落 sidecar（与下载流水线同一形态），播放页按目录动态发现，不写 DB 选择——
///   这样「自动补的」和「用户选的」不会在同一个字段上打架。
/// - 全函数：任何失败都进返回值，绝不抛。调用方是 fire-and-forget 的刮削回调。
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:fushi_audio/fushi_audio.dart' show decodeTextBytes;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/download/video_subtitle_registry.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_language_preference.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_timing_check.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi/src/media/video/video_duration_probe.dart';
import 'package:fushi/src/media/video/video_sidecar.dart'
    show listSidecarSubtitles;

/// 一个待补字幕的视频。身份来自刮削，不是从文件名现猜的。
class SubtitleBackfillTarget {
  const SubtitleBackfillTarget({
    required this.bookUid,
    required this.videoPath,
    required this.media,
    this.hasExistingSubtitle = false,
    this.scrapedRuntimeMinutes,
    this.contentLanguage,
    this.originalLanguage,
  });

  /// 视频稳定身份（`VideoBooks.bookUid`），只用于日志与调用方对账。
  final String bookUid;

  /// 视频绝对路径。sidecar 落在它旁边。
  final String videoPath;

  /// 刮削解析出的规范身份（含 season/episode）。**这是本模块存在的理由。**
  final VideoMediaReference media;

  /// DB 里是否已记了字幕来源。调用方查（本模块不碰 DB），为 true 时直接跳过。
  final bool hasExistingSubtitle;

  /// 刮削元数据里的播出时长（分钟）。ffprobe 探不到时的兜底时长来源。
  final int? scrapedRuntimeMinutes;

  /// 用户对本视频**手动指定**的内容语言（`VideoBooks.language`，BCP-47）。
  /// 选字幕语言时压过一切自动判断。
  final String? contentLanguage;

  /// 刮削出的作品原语言（TMDB `original_language` 等）。[contentLanguage] 没设时
  /// 的第二档；比 mkv 音轨 tag 可靠（打包者常写错或不写）。
  final String? originalLanguage;
}

/// 单个目标的补字幕结果。
enum SubtitleBackfillOutcome {
  /// 补上了，[SubtitleBackfillResult.installedPath] 是落盘路径。
  installed,

  /// 已经有字幕了（sidecar 或 DB），**没动它**。
  alreadyHasSubtitle,

  /// 搜索没有任何候选。
  noCandidate,

  /// 有候选但全都没通过时长/内容校验。
  allCandidatesRejected,

  /// 视频文件不在了 / 目录读不了 / 写盘失败。
  failed,
}

/// 补字幕结果（全函数返回值，不抛）。
class SubtitleBackfillResult {
  const SubtitleBackfillResult(
    this.outcome, {
    this.installedPath,
    this.language,
    this.detail,
  });

  final SubtitleBackfillOutcome outcome;
  final String? installedPath;
  final String? language;

  /// 失败/拒收的可读原因。
  final String? detail;

  bool get installed => outcome == SubtitleBackfillOutcome.installed;
}

/// 给刮削后仍缺字幕的视频自动补一条字幕。
class VideoSubtitleBackfillService {
  VideoSubtitleBackfillService({
    required this.registry,
    Iterable<String> preferredLanguages = const <String>[],
    this.defaultContentLanguage,
    this.maxCandidates = 4,
  }) : preferredLanguages = List<String>.unmodifiable(preferredLanguages);

  final VideoSubtitleRegistry registry;

  /// 用户在设置里**显式**选的字幕语言。非空即硬过滤（进搜索请求）。
  final List<String> preferredLanguages;

  /// 设置·外观·排版里的默认内容语言；视频没有可读语言时的最后一档。
  final String? defaultContentLanguage;

  /// 最多真下几条候选做校验。理由同下载流水线的
  /// `kSubtitleVerifyMaxCandidates`：候选可能几十条，全下一遍是对来源站的滥用。
  final int maxCandidates;

  Future<SubtitleBackfillResult> backfill(
    SubtitleBackfillTarget target,
  ) async {
    if (target.hasExistingSubtitle) {
      return const SubtitleBackfillResult(
        SubtitleBackfillOutcome.alreadyHasSubtitle,
      );
    }
    final File video = File(target.videoPath);
    if (!video.existsSync()) {
      return const SubtitleBackfillResult(
        SubtitleBackfillOutcome.failed,
        detail: 'video file is gone',
      );
    }
    // 目录里已经躺着 sidecar 就当已有字幕——它可能是用户手放的，也可能是下载
    // 流水线放的。两种都不该被覆盖。
    if (_existingSidecars(video).isNotEmpty) {
      return const SubtitleBackfillResult(
        SubtitleBackfillOutcome.alreadyHasSubtitle,
      );
    }

    final ProviderBatchResult<VideoSubtitleCandidate> result;
    try {
      result = await registry.search(
        VideoSubtitleSearchRequest(
          media: target.media,
          season: target.media.season,
          episode: target.media.episode,
          languages: preferredLanguages,
          fingerprint: LocalVideoFingerprint(
            fileSize: await video.length(),
            fileName: p.basename(video.path),
            openSubtitlesMovieHash:
                await computeOpenSubtitlesMovieHash(video.path),
          ),
        ),
      );
    } on Object catch (error) {
      return SubtitleBackfillResult(
        SubtitleBackfillOutcome.failed,
        detail: 'subtitle search failed: $error',
      );
    }
    if (result.items.isEmpty) {
      return SubtitleBackfillResult(
        SubtitleBackfillOutcome.noCandidate,
        detail: result.failures.isEmpty ? null : result.failures.first.message,
      );
    }

    // 一次 ffprobe 拿两件事实：时长（校验用）+ 音轨语言（选语言用）。
    final VideoProbeFacts facts = await probeVideoFacts(target.videoPath);
    final KnownVideoDuration? duration = _resolveDuration(target, facts);
    // 默认取**视频自己的语言**。这里是排序不是过滤：只有英文字幕的日语番仍然
    // 配得上，只是排在后面。硬过滤只属于用户显式选的语言（已进 request.languages）。
    final String? preferred = resolveSubtitleDownloadLanguage(
      explicitSubtitlePreference: preferredLanguages.firstOrNull,
      videoContentLanguage: target.contentLanguage,
      contentMetadataLanguage:
          target.originalLanguage ?? facts.primaryAudioLanguage,
      globalDefaultContentLanguage: defaultContentLanguage,
    );
    final List<VideoSubtitleCandidate> ordered = rankByPreferredLanguage(
      result.items,
      preferred,
      (VideoSubtitleCandidate c) => c.language,
    );
    String? lastRejection;
    final int limit =
        ordered.length < maxCandidates ? ordered.length : maxCandidates;
    for (int i = 0; i < limit; i++) {
      final VideoSubtitleCandidate candidate = ordered[i];
      final VideoSubtitleDownload download;
      try {
        download = await registry.download(candidate);
      } on Object catch (error) {
        lastRejection = 'download failed: $error';
        continue;
      }
      final SubtitleTimingCheck check = checkSubtitleTiming(
        summarizeSubtitleTiming(await decodeTextBytes(download.bytes)),
        video: duration,
      );
      if (check.rejected) {
        lastRejection = check.detail;
        debugPrint('[subtitle-backfill] rejected "${candidate.fileName}" for '
            '${target.bookUid}: ${check.detail}');
        continue;
      }
      try {
        final String installed = await _writeSidecar(video, download);
        return SubtitleBackfillResult(
          SubtitleBackfillOutcome.installed,
          installedPath: installed,
          language: download.language,
        );
      } on Object catch (error) {
        return SubtitleBackfillResult(
          SubtitleBackfillOutcome.failed,
          detail: 'sidecar write failed: $error',
        );
      }
    }
    return SubtitleBackfillResult(
      SubtitleBackfillOutcome.allCandidatesRejected,
      detail: lastRejection,
    );
  }

  /// 时长来源优先级：ffprobe 探到的真实容器时长 > 刮削的播出时长 > 未知。
  ///
  /// 顺序不能反：刮削 runtime 是**播出时长**（含广告位、只精确到分钟），拿它当
  /// 精确事实会误伤（见 [VideoDurationSource]）。它只在探不到时兜底。
  KnownVideoDuration? _resolveDuration(
    SubtitleBackfillTarget target,
    VideoProbeFacts facts,
  ) {
    final int? probed = facts.durationMs;
    if (probed != null) return KnownVideoDuration.probed(probed);
    final int? runtime = target.scrapedRuntimeMinutes;
    if (runtime != null && runtime > 0) {
      return KnownVideoDuration.scrapedRuntime(runtime * 60 * 1000);
    }
    return null;
  }

  List<String> _existingSidecars(File video) {
    try {
      final Directory dir = video.parent;
      final List<String> names = <String>[
        for (final FileSystemEntity entity in dir.listSync())
          if (entity is File) p.basename(entity.path),
      ];
      return listSidecarSubtitles(
        p.basenameWithoutExtension(video.path),
        names,
      );
    } catch (_) {
      // 目录读不了就当「不确定有没有」，按有处理——宁可不补，也不能覆盖。
      return const <String>['<unreadable>'];
    }
  }

  /// 落 sidecar：`<video 基名>.<lang><ext>`。**已存在同名文件就不写**（上面已经
  /// 查过整目录的 sidecar，这里是防并发的第二道）。
  Future<String> _writeSidecar(
    File video,
    VideoSubtitleDownload download,
  ) async {
    final String extension = sidecarSubtitleExtension(download.fileName);
    final String language = sidecarLanguageTag(download.language);
    final String target = p.join(
      p.dirname(video.path),
      '${p.basenameWithoutExtension(video.path)}.$language$extension',
    );
    final File dest = File(target);
    if (dest.existsSync()) return target;
    // 先写临时文件再 rename：半截字幕文件比没有字幕更糟——播放页会把它当成
    // 一条可用字幕加载，用户看到的是「字幕只有前三句」。
    final File temp = File('$target.fushi.tmp');
    await temp.writeAsBytes(download.bytes, flush: true);
    await temp.rename(target);
    return target;
  }
}

/// 语言标签归一到 sidecar 后缀白名单允许的字符集（见 `isSidecarSubtitleSuffix`：
/// `[A-Za-z0-9_-]{1,32}`）。纯函数，与那条白名单成对单测。
///
/// 不归一会开一个静默的洞：provider 给出 `ja[cc]` 这类带修饰的标签时，写出的
/// `<base>.ja[cc].srt` **不匹配 sidecar 后缀白名单** → 播放页永远发现不了它，
/// 而下一次刮削的「已有 sidecar？」检查同样看不见它 → 每刮一次多一个孤儿文件。
/// 兜底 `und`（ISO 639-2 的「未确定」），不是空串——空串会写成 `<base>..srt`。
String sidecarLanguageTag(String raw) {
  final String cleaned = raw
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9_-]'), '')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (cleaned.isEmpty) return 'und';
  return cleaned.length > 32 ? cleaned.substring(0, 32) : cleaned;
}

/// 只认四种可解析的文本字幕扩展名；其余一律按 `.srt` 落盘。纯函数。
///
/// 不是为了「猜格式」——播放页按扩展名路由 parser，一个 `.zip` 或 `.xyz` 后缀
/// 会让这条字幕在菜单里根本不出现。来源站给的多半确实是文本字幕。
String sidecarSubtitleExtension(String fileName) {
  final String ext = p.extension(fileName).toLowerCase();
  return const <String>{'.srt', '.ass', '.ssa', '.vtt'}.contains(ext)
      ? ext
      : '.srt';
}
