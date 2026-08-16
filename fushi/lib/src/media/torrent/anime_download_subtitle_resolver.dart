import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_audio/fushi_audio.dart' show decodeTextBytes;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/torrent/anime_download_matching.dart';
import 'package:fushi/src/media/torrent/anime_download_plan.dart';
import 'package:fushi/src/media/video/jimaku_client.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_language_preference.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_timing_check.dart';
import 'package:fushi/src/media/video/video_duration_probe.dart';

/// 延迟字幕解析的结果：配好的字幕 + 失败原因（二选一有值）。
class ResolvedPlanSubtitles {
  const ResolvedPlanSubtitles.ok(this.subtitles) : failureReason = null;

  const ResolvedPlanSubtitles.failed(this.failureReason)
      : subtitles = const <PlanSubtitle>[];

  /// 已下载落地的字幕（顺序 = 反查结果顺序）。
  final List<PlanSubtitle> subtitles;

  /// 失败原因（英文短语，落任务行/日志）；null = 未失败。
  final String? failureReason;
}

/// 下载完成后按**包内真实视频文件名**补取 Jimaku 字幕（BUG-1206）。
///
/// 为什么是「完成后」而不是选种时：选种时手上只有 Nyaa 标题（没有文件列表），
/// 集号与集数都只能猜；种子 add 之后引擎才给得出包内真实文件名。见
/// [matchJimakuFilesToVideoNames] 的文档。
///
/// 职责边界：网络 + 磁盘全在这里，`AnimeDownloadService` 只按回调调用，保持可
/// 纯 fake 测试。全部失败路径都返回带原因的 [ResolvedPlanSubtitles.failed]，
/// **不静默吞掉**——调用方会把它落进计划的 `subtitleNote` 并显示给用户。
class JimakuPlanSubtitleResolver {
  JimakuPlanSubtitleResolver({
    required String Function() apiKeyProvider,
    required Future<http.Client> Function() httpClientFactory,
    required Directory Function(String planId) stagingDirFor,
    String Function()? defaultContentLanguageProvider,
  })  : _apiKeyProvider = apiKeyProvider,
        _httpClientFactory = httpClientFactory,
        _stagingDirFor = stagingDirFor,
        _defaultContentLanguage = defaultContentLanguageProvider ?? (() => '');

  final String Function() _apiKeyProvider;
  final Future<http.Client> Function() _httpClientFactory;
  final Directory Function(String planId) _stagingDirFor;

  /// 设置·外观·排版里的默认内容语言（选字幕语言的最后一档）。回调而非快照：
  /// 用户随时能改，而本 resolver 的生命周期跟 service 一样长。
  final String Function() _defaultContentLanguage;

  /// 为 [plan] 按 [videoAbsolutePaths]（包内真实视频）补取字幕。
  Future<ResolvedPlanSubtitles> resolve(
    AnimeDownloadPlan plan,
    List<String> videoAbsolutePaths,
  ) async {
    final int? entryId = plan.jimakuEntryId;
    if (entryId == null) {
      return const ResolvedPlanSubtitles.failed('no jimaku entry recorded');
    }
    final String apiKey = _apiKeyProvider().trim();
    if (apiKey.isEmpty) {
      return const ResolvedPlanSubtitles.failed('jimaku api key missing');
    }
    if (videoAbsolutePaths.isEmpty) {
      return const ResolvedPlanSubtitles.failed('no video files in pack');
    }

    JimakuClient? jimaku;
    try {
      jimaku = JimakuClient(
        apiKey: apiKey,
        client: await _httpClientFactory(),
      );
      // 列全部文件（不带 episode query）：反查要拿字幕侧完整集号集合，
      // 服务端按文件名 best-effort 过滤反而会遮住「一条都对不上」这个事实。
      final List<JimakuFile> files = await jimaku.listFiles(entryId);
      if (files.isEmpty) {
        return const ResolvedPlanSubtitles.failed('jimaku entry has no files');
      }
      // 语言优先级：用户在下载对话框里显式选的 > 视频自己的语言（音轨 tag）>
      // 全局默认内容语言。都没有时传 null，`jimakuLanguageRank` 退回它自己的默认
      // 权重——Jimaku 是日语字幕站，那条默认在这里是合理的领域知识，不是全局假设。
      final String? preferredLanguage = resolveSubtitleDownloadLanguage(
        explicitSubtitlePreference: plan.jimakuLanguage,
        contentMetadataLanguage:
            (await probeVideoFacts(videoAbsolutePaths.first))
                .primaryAudioLanguage,
        globalDefaultContentLanguage: _defaultContentLanguage(),
      );
      final List<ResolvedSubtitleMatch> matches = matchJimakuFilesToVideoNames(
        videoAbsolutePaths,
        files,
        preferredLanguage: preferredLanguage,
      );
      if (matches.isEmpty) {
        // 反查一条都对不上——绝大多数是条目选错季或用了绝对集号编号。
        // 明说，而不是悄悄不放字幕。
        return const ResolvedPlanSubtitles.failed(
            'no jimaku file matches the pack episodes');
      }
      return ResolvedPlanSubtitles.ok(
        await _download(plan, matches, jimaku, videoAbsolutePaths),
      );
    } catch (e) {
      return ResolvedPlanSubtitles.failed('jimaku fetch failed: $e');
    } finally {
      jimaku?.close();
    }
  }

  /// 逐条下载并落进计划暂存目录；同一 URL 只下一次（同集多版本视频会指向同一
  /// 字幕）。单条失败跳过，不影响其余。
  ///
  /// 落盘前过一道时长/内容校验（BUG-1697）：集号匹配只保证「文件名对得上」，
  /// 保证不了「内容是这一集的」。整季合并成一个文件、条目里混进电影字幕这类形状，
  /// 文件名可以完全合规，只有看内容才发现得了。校验不过的**跳过该条**，其余照配
  /// ——这与本文件既有的「单条失败跳过」语义一致。
  Future<List<PlanSubtitle>> _download(
    AnimeDownloadPlan plan,
    List<ResolvedSubtitleMatch> matches,
    JimakuClient jimaku,
    List<String> videoAbsolutePaths,
  ) async {
    final Directory subsDir = _stagingDirFor(plan.id);
    final Map<String, String> stagedByUrl = <String, String>{};
    final List<PlanSubtitle> out = <PlanSubtitle>[];
    // 每个视频只探一次时长（同一 URL 的字幕会配给多个视频，但校验是按视频算的）。
    final Map<String, int?> durationByVideo = <String, int?>{};
    for (final ResolvedSubtitleMatch match in matches) {
      String? staged = stagedByUrl[match.file.url];
      if (staged == null) {
        final Uint8List? bytes = await jimaku.downloadFile(match.file.url);
        if (bytes == null) continue;
        final String? videoPath = _videoPathFor(match, videoAbsolutePaths);
        if (videoPath != null) {
          final int? durationMs = durationByVideo.containsKey(videoPath)
              ? durationByVideo[videoPath]
              : (durationByVideo[videoPath] =
                  await probeVideoDurationMs(videoPath));
          final SubtitleTimingCheck check = checkSubtitleTiming(
            summarizeSubtitleTiming(await decodeTextBytes(bytes)),
            video: durationMs == null
                ? null
                : KnownVideoDuration.probed(durationMs),
          );
          // 这条路径**没有备选候选**（集号已经锁定唯一一条字幕），所以只认正面
          // 矛盾，不因「读不出」就把用户唯一的字幕扔掉。见 contradictsVideo。
          if (check.contradictsVideo) continue;
        }
        try {
          final File dest =
              File(p.join(subsDir.path, p.basename(match.file.name)))
                ..createSync(recursive: true);
          await dest.writeAsBytes(bytes);
          staged = dest.path;
          stagedByUrl[match.file.url] = staged;
        } catch (_) {
          continue; // 单条落盘失败跳过。
        }
      }
      out.add(PlanSubtitle(
        episode: match.episode,
        fileName: match.file.name,
        stagedPath: staged,
        language: detectSubtitleLanguage(match.file.name),
      ));
    }
    return out;
  }

  /// 把一条匹配还原回它对应的**视频绝对路径**（[ResolvedSubtitleMatch] 只记
  /// basename）。找不到返回 null → 该条跳过时长校验，只按原路径落盘。
  static String? _videoPathFor(
    ResolvedSubtitleMatch match,
    List<String> videoAbsolutePaths,
  ) {
    for (final String path in videoAbsolutePaths) {
      if (p.basename(path) == match.videoFileName) return path;
    }
    return null;
  }
}
