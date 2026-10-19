/// 下载后缺字幕的定期重试。
///
/// 下载流水线只在视频落盘那一刻搜一次字幕；`bestEffort` 下搜不到就记一条
/// `unavailable` 放行入库，此后再没有任何链路回头找（刮削后补字幕也只在同一时刻
/// 跑一次）。连载番恰恰最常见这种情况：片源当晚就有，Jimaku 上的日语字幕一两天后
/// 才上传——实测《FX戦士くるみちゃん》第 3 集 10-15 21:15 下完，字幕 10-17 才出现，
/// 这一集就永远没有日语字幕了。
///
/// 这里按退避间隔把窗口内的 `unavailable` 行重新交给「给库里这一个视频补字幕」
/// （[backfillLibraryVideoSubtitle]，身份取已落库的刮削结论），装上了把行标成
/// `placed`，确定不必再找的标 `skipped`，其余只刷新尝试时刻与原因等下一轮。
library;

import 'dart:async';

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show VideoSubtitleBackfillReport;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/video/subtitle/library_video_subtitle_backfill.dart'
    show subtitleSourceBlocksBackfill;

/// 下载完成后多久之内还值得回头找字幕。超过这个窗口仍没有，多半是真没人做。
const Duration kDownloadSubtitleRetryWindow = Duration(days: 14);

/// 同一行两次尝试之间至少隔多久：字幕站按天更新，频繁重搜只是滥用来源站。
const Duration kDownloadSubtitleRetryInterval = Duration(hours: 6);

/// 多久看一眼有没有退避到期的行（每行自带 [kDownloadSubtitleRetryInterval] 退避，
/// 这个周期只决定发现到期行的延迟）。
const Duration kDownloadSubtitleRetryPollPeriod = Duration(minutes: 30);

/// 起一个重试循环：**立刻跑一轮**，此后每 [period] 再跑一轮。
///
/// 首轮不能等满一个周期：移动端 app 很少连续在前台停留 30 分钟，`Timer.periodic`
/// 的首轮几乎永远触发不到，到期的行就一直没人看。立刻跑一轮不会多打来源站——
/// 退避没到期的行根本不会被查出来。
Timer startDownloadSubtitleRetryLoop(
  void Function() runOnce, {
  Duration period = kDownloadSubtitleRetryPollPeriod,
}) {
  runOnce();
  return Timer.periodic(period, (_) => runOnce());
}

/// 一轮重试的结果计数（日志与测试用）。
class DownloadSubtitleRetryReport {
  const DownloadSubtitleRetryReport({
    this.attempted = 0,
    this.installed = 0,
    this.settled = 0,
    this.unmatched = 0,
  });

  /// 本轮真正交给补字幕服务的行数。
  final int attempted;

  /// 其中装上了字幕的行数。
  final int installed;

  /// 确定不必再找、标成 `skipped` 的行数（库里那一集已经有字幕）。
  final int settled;

  /// 按任务记下的最终路径在库里找不到视频的行数。**不终结**：路径对不上不等于
  /// 视频离库（见 [retryUnavailableDownloadSubtitles]），只记原因、等下一轮，
  /// 超出 [kDownloadSubtitleRetryWindow] 后自然不再被查出来。
  final int unmatched;
}

/// 跑一轮重试。[backfill] 按库内视频 id 补字幕，视频不存在返回 null；生产装配是
/// `backfillLibraryVideoSubtitle(embeddedSelectionBlocks: false)`。逐条串行：一轮可能涉及多集，并发打同一个字幕站
/// 是滥用，而且这条路径跑在后台、没人在等。
Future<DownloadSubtitleRetryReport> retryUnavailableDownloadSubtitles({
  required FushiDatabase database,
  required Future<VideoSubtitleBackfillReport?> Function(String videoId)
  backfill,
  required DateTime now,
  Duration window = kDownloadSubtitleRetryWindow,
  Duration interval = kDownloadSubtitleRetryInterval,
}) async {
  final int nowMs = now.millisecondsSinceEpoch;
  final List<
    ({VideoDownloadJobSubtitleRow subtitle, VideoDownloadJobFileRow file})
  >
  rows = await database.getRetryableUnavailableDownloadSubtitles(
    createdAfter: nowMs - window.inMilliseconds,
    updatedBefore: nowMs - interval.inMilliseconds + 1,
  );
  if (rows.isEmpty) return const DownloadSubtitleRetryReport();

  // 任务文件行只记得最终路径，库里的视频按路径认（导入就是按这条路径落库的）。
  final Map<String, String> bookUidByPath = <String, String>{
    for (final VideoBookRow book in await database.allVideoBooks())
      if (book.videoPath.trim().isNotEmpty)
        p.canonicalize(book.videoPath): book.bookUid,
  };

  int attempted = 0;
  int installed = 0;
  int settled = 0;
  int unmatched = 0;
  for (final (
        :VideoDownloadJobSubtitleRow subtitle,
        :VideoDownloadJobFileRow file,
      )
      in rows) {
    final String? bookUid =
        bookUidByPath[p.canonicalize(file.finalAbsolutePath!)];
    final int at = nowMs;
    // 路径对不上**不是**「视频已离库」的证据：app 内的改名 / 移动
    // （`AppModel.downloadRelocateService` →
    // `VideoBookRepository.applyDownloadRelocation`）与数据根迁移会把
    // `video_books.video_path` 与任务行 `finalAbsolutePath` 一起改写，但用户在
    // app 外挪动文件、或库侧重扫改了路径时两者仍会分叉。任务行也没有记下导入时的
    // bookUid，没有别的身份可认。所以只记原因、留在 unavailable 等下一轮；真离库的
    // 行在重试窗口过后自然不再被查出来。
    final VideoSubtitleBackfillReport? report = bookUid == null
        ? null
        : await backfill(bookUid);
    if (bookUid != null) attempted++;
    if (report == null) {
      unmatched++;
      await database.updateVideoDownloadJobSubtitle(
        subtitle.subtitleId,
        VideoDownloadJobSubtitlesCompanion(
          error: Value<String?>(
            bookUid == null
                ? 'no library video at the downloaded path'
                : 'library video disappeared before the retry',
          ),
          updatedAt: Value<int>(at),
        ),
      );
      continue;
    }
    if (report.installed) {
      installed++;
      await database.updateVideoDownloadJobSubtitle(
        subtitle.subtitleId,
        VideoDownloadJobSubtitlesCompanion(
          language: Value<String?>(report.language),
          finalPath: Value<String?>(report.installedPath),
          status: const Value<String>(VideoDownloadJobSubtitleStatus.placed),
          error: const Value<String?>(null),
          updatedAt: Value<int>(at),
        ),
      );
      // 补字幕服务只落 sidecar、不碰库。库里主字幕源还是空（无偏好）时指向新装的
      // 文件，等于补完下载流水线当初装上字幕时会做的那一步。非空一律不动：
      // `off:` / 外挂路径 / `embedded:<n>` 都只由用户在播放器里选源时写入
      // （`_selectSubtitleSource` / `_selectSubtitleOff`；导入与下载只写路径或 null，
      // 起播自动选轨不落库），覆盖它就是改掉用户的选择。新 sidecar 照样落在视频
      // 旁边，字幕菜单里能直接选到。
      final String? installedPath = report.installedPath;
      final VideoBookRow? book = await database.getVideoBookByBookUid(bookUid!);
      if (installedPath != null &&
          book != null &&
          !subtitleSourceBlocksBackfill(book.subtitleSource)) {
        await database.updateVideoBookSubtitleSource(bookUid, installedPath);
      }
      continue;
    }
    if (report.outcome == 'alreadyHasSubtitle') {
      // 用户手放了 sidecar / 手选了字幕：不再替用户找。
      settled++;
      await database.updateVideoDownloadJobSubtitle(
        subtitle.subtitleId,
        VideoDownloadJobSubtitlesCompanion(
          status: const Value<String>(VideoDownloadJobSubtitleStatus.skipped),
          error: const Value<String?>('video already has a subtitle'),
          updatedAt: Value<int>(at),
        ),
      );
      continue;
    }
    // 没候选 / 全被拒 / 没身份 / 来源未配置：留在 unavailable，刷新尝试时刻等下一轮。
    await database.updateVideoDownloadJobSubtitle(
      subtitle.subtitleId,
      VideoDownloadJobSubtitlesCompanion(
        error: Value<String?>(
          report.detail?.trim().isNotEmpty == true
              ? report.detail
              : report.outcome,
        ),
        updatedAt: Value<int>(at),
      ),
    );
  }
  return DownloadSubtitleRetryReport(
    attempted: attempted,
    installed: installed,
    settled: settled,
    unmatched: unmatched,
  );
}
