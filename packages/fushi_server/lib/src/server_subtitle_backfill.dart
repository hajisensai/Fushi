/// 服务端的补字幕：单视频补字幕（互联 `POST /api/library/videos/<id>/subtitle/backfill`）、
/// 下载导入刮完后补字幕、下载后缺字幕的定期重试共用这一份装配。
///
/// 与 app `AppModel` 的三条路同一套引擎代码（`backfillLibraryVideoSubtitle` /
/// `backfillScrapedWorkSubtitles` / `runDownloadSubtitleRetryRound`），差别只在装配：
/// - 字幕来源每次用时按当前偏好 / 环境现建、用完即关（WebUI / ctl 存的 key、WebUI
///   改的字幕语言即时生效），见 [buildServerSubtitleRegistry]；
/// - AI 重排候选（`aiSubtitleBackfillReorder`）用配置文件 `ai:` 段那一家
///   （[ServerAiSettings] 把「视频搜索辅助」指给它）；没有 `ai:` 段 / 没配全时
///   解析出 null，一个 AI 请求都不发；
/// - 两条自动路径与 app 同一个开关 `video_subtitle_backfill_after_scrape`（偏好表，
///   默认开），关了就整个静默跳过；没配任何字幕来源时同样跳过。
library;

import 'dart:async';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_video_search_assistant.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/media/video/download/download_confirmed_identity.dart'
    show DownloadConfirmedIdentityResolver;
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi_engine/media/video/external_video.dart'
    show normalizeVideoPath;
import 'package:fushi_engine/media/video/metadata/video_source_scrape_coordinator.dart'
    show VideoScrapedWorkNotice;
import 'package:fushi_engine/media/video/subtitle/download_subtitle_retry.dart';
import 'package:fushi_engine/media/video/subtitle/library_video_subtitle_backfill.dart';
import 'package:fushi_engine/media/video/subtitle/scraped_work_subtitle_backfill.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_backfill.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show VideoSubtitleBackfillReport;
import 'package:fushi_server/src/config/server_ai_config.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/server_subtitle_providers.dart';

/// 「自动获取字幕」开关（app `PreferencesRepository.videoSubtitleBackfillAfterScrape`
/// 同名键，默认开）：刮削后补字幕与下载后缺字幕重试共用。
const String kVideoSubtitleBackfillAfterScrapePref =
    'video_subtitle_backfill_after_scrape';

/// 诊断日志的 source tag。
const String kServerSubtitleBackfillLogSource = 'ServerSubtitleBackfill';

class ServerSubtitleBackfill {
  ServerSubtitleBackfill({
    required this.db,
    required this.prefs,
    required ServerConfig Function() config,
    required VideoSubtitleRegistry Function() registryFactory,
    AiClientFactory? aiClientFactory,
    DateTime Function()? clock,
  }) : _config = config,
       _registryFactory = registryFactory,
       _aiClientFactory = aiClientFactory,
       _clock = clock ?? DateTime.now;

  final FushiDatabase db;
  final PrefStore prefs;
  final ServerConfig Function() _config;

  /// 在线字幕来源（生产 = [buildServerSubtitleRegistry]）；每次用时现建、用完即关。
  final VideoSubtitleRegistry Function() _registryFactory;

  /// 测试缝：AI 重排的客户端（注入假 `http.Client`）。生产 null = 默认客户端。
  final AiClientFactory? _aiClientFactory;
  final DateTime Function() _clock;

  Timer? _retryTimer;

  /// 正在跑的那一轮重试（不叠加；停机时等它落地再关库）。
  Future<void>? _retryInFlight;

  /// 两条自动路径的总开关（每次现读）。
  bool get automaticEnabled => prefBool(
    prefs,
    kVideoSubtitleBackfillAfterScrapePref,
    defaultValue: true,
  );

  /// 按当前配置装一个补字幕服务（语言、对齐开关、AI 重排都现读）。
  VideoSubtitleBackfillService _service(VideoSubtitleRegistry registry) {
    final ServerConfig config = _config();
    return VideoSubtitleBackfillService(
      registry: registry,
      subtitleAligner: serverSubtitleAligner(prefs),
      preferredLanguages: serverPreferredSubtitleLanguages(
        config.subtitleLanguage,
      ),
      defaultContentLanguage: serverDefaultContentLanguage(prefs),
      // 真下载前由 AI 在候选里挑先下哪几条；提供商每次调用时现解析（WebUI 改了
      // `ai:` 段即生效），没配 / 失败都退回本地顺序。
      aiReorder: aiSubtitleBackfillReorder(
        resolveProvider: () =>
            resolveVideoSearchAiProvider(ServerAiSettings(() => _config().ai)),
        clientFactory: _aiClientFactory,
      ),
    );
  }

  String? _seriesLanguage(String seriesKey) =>
      serverSeriesSubtitleLanguage(prefs, seriesKey);

  /// 给库里一个视频补一条字幕（互联路由）。视频不存在返回 null（路由 404）；一家
  /// 字幕来源都没配时回 `unavailable`。显式请求，不看自动开关。
  Future<VideoSubtitleBackfillReport?> backfillVideo(
    String videoId, {
    String? language,
  }) async {
    final VideoSubtitleRegistry registry = _registryFactory();
    try {
      return await backfillLibraryVideoSubtitle(
        database: db,
        service: _service(registry),
        videoId: videoId,
        // 与 app 同一判据：用户在下载确认里选定的作品身份优先于刮削结论。
        confirmedIdentities: DownloadConfirmedIdentityResolver(db),
        language: language,
        seriesLanguage: _seriesLanguage,
      );
    } finally {
      registry.close();
    }
  }

  /// 刮削协调器的 `onWorkScraped`：刮完一个**下载来的**作品 → 给它仍缺字幕的成员
  /// 各补一条。
  ///
  /// 只认下载任务导入过的文件，与 app 的范围一致：app 只在下载管线自己的刮削协调器
  /// 上挂这个钩子（库页的整库刮削不挂）。服务端只有一个协调器，扫描补刮、互联重刮
  /// 都经过它；不加这道判据，第一次扫描一个没有字幕的大库就会逐集打一遍字幕站
  /// （Jimaku 每窗口 25 次、OpenSubtitles 免费额度按天计）。
  ///
  /// 异常照抛：协调器把它记成这部作品的刮削 warning，不影响刮削结论。
  Future<void> onWorkScraped(VideoScrapedWorkNotice notice) async {
    if (!automaticEnabled) return;
    final VideoSubtitleRegistry registry = _registryFactory();
    try {
      // 一家来源都没配：别为空结果去探一堆视频时长。
      if (registry.providers.isEmpty) return;
      if (!await _hasDownloadedMember(notice)) return;
      await backfillScrapedWorkSubtitles(
        database: db,
        service: _service(registry),
        notice: notice,
        seriesLanguage: _seriesLanguage,
      );
    } finally {
      registry.close();
    }
  }

  Future<bool> _hasDownloadedMember(VideoScrapedWorkNotice notice) async {
    final Set<String> downloaded = <String>{
      for (final VideoDownloadJobFileRow row
          in await db.getImportedVideoDownloadJobFiles())
        normalizeVideoPath(row.finalAbsolutePath!),
    };
    return notice.work.members.any(
      (VideoBookRow book) =>
          book.videoPath.trim().isNotEmpty &&
          downloaded.contains(normalizeVideoPath(book.videoPath)),
    );
  }

  /// 跑一轮下载后缺字幕重试。开关关了 / 没配字幕来源 / 上一轮还没跑完时返回 null
  /// （本轮跳过）。失败记日志后返回 null：这是后台定时任务，下一轮照常再看。
  Future<DownloadSubtitleRetryReport?> retryDownloadsOnce() async {
    if (_retryInFlight != null || !automaticEnabled) return null;
    final Completer<void> done = Completer<void>();
    _retryInFlight = done.future;
    final VideoSubtitleRegistry registry = _registryFactory();
    try {
      if (registry.providers.isEmpty) return null;
      final DownloadSubtitleRetryReport report =
          await runDownloadSubtitleRetryRound(
            database: db,
            service: _service(registry),
            seriesLanguage: _seriesLanguage,
            now: _clock(),
          );
      if (report.attempted > 0) {
        engineLog.logDiagnostic(
          kServerSubtitleBackfillLogSource,
          'download subtitle retry: attempted ${report.attempted}, '
          'installed ${report.installed}, settled ${report.settled}',
        );
      }
      return report;
    } on Object catch (e, st) {
      engineLog.log('$kServerSubtitleBackfillLogSource.retry', e, st);
      return null;
    } finally {
      registry.close();
      _retryInFlight = null;
      done.complete();
    }
  }

  /// 起重试循环：立刻跑一轮，此后每 [period] 看一眼（每行自带 6 小时退避、14 天
  /// 窗口，见 `download_subtitle_retry.dart`；周期只决定发现到期行的延迟）。
  void startRetryLoop({Duration period = kDownloadSubtitleRetryPollPeriod}) {
    _retryTimer?.cancel();
    _retryTimer = startDownloadSubtitleRetryLoop(
      () => unawaited(retryDownloadsOnce()),
      period: period,
    );
  }

  /// 停重试循环，并等在途的一轮落地（之后才能关库）。
  Future<void> stop() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    await _retryInFlight;
  }
}
