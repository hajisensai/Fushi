import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_language_preference.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi/src/media/manga/mihon/mihon_cloudflare_action.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_source_browse_page.dart';
import 'package:fushi/src/media/manga/mihon/mihon_web_url.dart';
import 'package:fushi/src/media/online/online_work_detail.dart';
import 'package:fushi/src/media/video/online/anime_source_library.dart';
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'package:fushi/src/media/video/online/anime_source_video_client.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/utils.dart';
import 'package:url_launcher/url_launcher.dart';

/// 视频源扩展的作品页：详情 + 剧集列表 → 内置播放器（起播默认选线路）。
///
/// 这是三域在线作品页的**版式基准**（2026-09-27「浏览」阶段 2，[OnlineWorkHeader]
/// 等共用件就是从本页抽出来的）：点集**直接进播放器**——取流、默认选线路（扩展标的
/// `preferred` / 排序第一条）都在播放页的「正在连接视频流」阶段做，多条候选
/// （画质 / hoster）不在这里弹选择器拦一道，用户进去后在播放器画质菜单里换线路
/// （[AnimeSourceVideoClient] 的 `RemoteVideoStreamVariants` 能力）。播放页拿到整部
/// 作品的集列表当 `remoteCollectionMembers`，看完自动连播下一集。
///
/// 主操作「继续观看」落到最近看过的那一集：播放页在合集模式下按「成员 id, 0」
/// 记远端断点（`videoRemotePositionEpisodeAtPrefKey`），本页按同一把键取最新的一集。
/// 另有「加入媒体库 / 移出媒体库」「下载全部」与每集的下载按钮（阶段 2b，见
/// [AnimeSourceLibrary]）：入库是每集一行流媒体书，下载交给 app 级下载管理器
/// （任务在「浏览 › 下载」），下完的集就是普通本地视频，点它直接播本地文件。
class AnimeSourceDetailPage extends ConsumerStatefulWidget {
  const AnimeSourceDetailPage({
    required this.manager,
    required this.sourceContext,
    required this.anime,
    super.key,
    this.repositoryOverride,
    this.openPlayer,
    this.openExternal,
    this.subtitleLanguageResolver,
  });

  final MihonManager manager;
  final MihonSourceContext sourceContext;
  final MihonAnime anime;

  /// 测试注入；生产从 `AppModel.database` 建。
  final VideoBookRepository? repositoryOverride;

  /// 测试注入：替换真实播放页的 push（widget 测试里起不了 libmpv）。
  final Future<void> Function(
    BuildContext context,
    AnimeSourceVideoClient client,
    RemoteVideoInfo info,
    int index,
  )?
  openPlayer;

  /// 测试注入：默认用系统浏览器打开（[launchUrl]）。
  final Future<void> Function(Uri url)? openExternal;

  /// 测试注入：默认字幕轨的首选语言；生产读偏好（见 `_preferredSubtitleLanguage`）。
  final String? Function()? subtitleLanguageResolver;

  @override
  ConsumerState<AnimeSourceDetailPage> createState() =>
      _AnimeSourceDetailPageState();
}

class _AnimeSourceDetailPageState extends ConsumerState<AnimeSourceDetailPage> {
  late MihonAnime _anime = widget.anime;
  List<MihonEpisode> _episodes = const <MihonEpisode>[];
  AnimeSourceVideoClient? _client;

  /// 最近看过的一集（按远端断点时间戳取最新）；-1 = 一集都没看过。
  int _resumeIndex = -1;

  /// 本作品各集的入库状态（有在线行 / 已下载 / 库里没有）；读出来之前为 null。
  AnimeSourceEpisodeStatus? _libraryStatus;
  Set<String> get _downloadedIds =>
      _libraryStatus?.downloaded ?? const <String>{};
  bool _libraryBusy = false;
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _client?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final MihonSourceContext context = widget.sourceContext;
      final MihonAnime details = await widget.manager.animeRuntime
          .getAnimeDetails(
            context.extension,
            context.source,
            _anime,
            preferences: context.preferences,
          );
      final List<MihonEpisode> episodes = await widget.manager.animeRuntime
          .getEpisodes(
            context.extension,
            context.source,
            details,
            preferences: context.preferences,
          );
      if (!mounted) return;
      final List<MihonEpisode> ordered = sortEpisodesForPlayback(episodes);
      _client?.dispose();
      setState(() {
        _anime = details;
        _episodes = ordered;
        _client = AnimeSourceVideoClient(
          manager: widget.manager,
          context: context,
          anime: details,
          episodes: ordered,
          subtitleLanguageResolver:
              widget.subtitleLanguageResolver ?? _preferredSubtitleLanguage,
        );
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error;
      });
      return;
    }
    // 在详情加载的 try 之外：断点只决定「继续观看」落点，读不到不能冒充成「详情
    // 加载失败」。
    _reloadResumeIndex();
    unawaited(_reloadLibraryState());
  }

  AnimeSourceLibrary? _libraryOrNull() {
    final AppModel? appModel = _appModelOrNull;
    if (appModel == null) return null;
    return AnimeSourceLibrary(
      database: appModel.database,
      repository: widget.repositoryOverride,
      // 下载完登记本地行时把在线断点接过去。闭包只抓 appModel（不抓 ref）：下载
      // 可能在本页退出后才完成。
      onlinePositionReader: (String id) => _readOnlinePosition(appModel, id),
    );
  }

  /// 一集的在线断点：与播放页合集模式落盘同一把键 `(成员 id, 0)`（见
  /// `VideoFushiPage._remotePositionKeyForIndex`）。没有 / 近起点返回 null。
  static AnimeOnlinePosition? _readOnlinePosition(
    AppModel appModel,
    String id,
  ) {
    int readInt(String key) {
      final Object? raw = appModel.prefsRepo.getPref(key, defaultValue: 0);
      return raw is num ? raw.toInt() : int.tryParse('${raw ?? ''}') ?? 0;
    }

    final int positionMs = readInt(videoRemotePositionEpisodePrefKey(id, 0));
    if (positionMs <= 0) return null;
    return (
      positionMs: positionMs,
      playedAt: readInt(videoRemotePositionEpisodeAtPrefKey(id, 0)),
    );
  }

  Future<void> _reloadLibraryState() async {
    final AnimeSourceVideoClient? client = _client;
    final AnimeSourceEpisodeStatus status;
    try {
      final AnimeSourceLibrary? library = _libraryOrNull();
      if (client == null || library == null) return;
      status = await library.episodeStatus(client);
    } on Object catch (error, stack) {
      // 入库状态只决定按钮是「加入」还是「移出」、哪些集已下载：读不到时页面照常
      // 在线可用，记日志而不是让它变成未捕获的异步错误。
      ErrorLogService.instance.log(
        'AnimeSourceDetailPage.libraryState',
        error,
        stack,
      );
      return;
    }
    if (!mounted || !identical(client, _client)) return;
    setState(() => _libraryStatus = status);
  }

  /// 「加入媒体库」：还有集不在库里（没入过库 / 只下载过其中几集 / 刷新后多了新集）
  /// 就显示。状态还没读出来时也显示（按钮本身在剧集加载完前是禁用的）。
  bool get _canAddToLibrary => _libraryStatus?.canAdd ?? true;

  /// 「移出媒体库」：有在线行可删才显示。已下载的集是普通本地视频，不算。
  bool get _canRemoveFromLibrary => _libraryStatus?.canRemove ?? false;

  /// 「加入媒体库」：每集一行流媒体书，归进作品合集（刷新后再点只补新集）。
  Future<void> _addToLibrary() async {
    final AnimeSourceVideoClient? client = _client;
    final AnimeSourceLibrary? library = _libraryOrNull();
    if (client == null || library == null || _libraryBusy) return;
    setState(() => _libraryBusy = true);
    try {
      final int added = await library.addToLibrary(client);
      FushiToast.show(
        msg: t.video_online_library_added(n: added),
        severity: ToastSeverity.success,
      );
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('AnimeSourceDetailPage.add', error, stack);
      FushiToast.show(msg: '$error', severity: ToastSeverity.error);
    } finally {
      if (mounted) setState(() => _libraryBusy = false);
    }
    await _reloadLibraryState();
  }

  /// 「移出媒体库」：删在线行；已下载的集是普通本地视频，留在库里（删它们走媒体库
  /// 自己的删除，那里有「同时删除本地文件」的确认）。
  Future<void> _removeFromLibrary() async {
    final AnimeSourceVideoClient? client = _client;
    final AnimeSourceLibrary? library = _libraryOrNull();
    if (client == null || library == null || _libraryBusy) return;
    setState(() => _libraryBusy = true);
    try {
      // 一行都没删（状态过期：别处已经移出 / 这些集刚下载完成了本地行）就不报
      // 「已移出」——下面重读状态后按钮自己会更新。
      if (await library.removeFromLibrary(client) > 0) {
        FushiToast.show(msg: t.video_online_library_removed);
      }
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'AnimeSourceDetailPage.remove',
        error,
        stack,
      );
      FushiToast.show(msg: '$error', severity: ToastSeverity.error);
    } finally {
      if (mounted) setState(() => _libraryBusy = false);
    }
    await _reloadLibraryState();
  }

  /// 下载若干集（交给 app 级下载管理器；任务在「浏览 › 下载」）。
  Future<void> _download(List<String> ids) async {
    final AnimeSourceVideoClient? client = _client;
    final AnimeSourceLibrary? library = _libraryOrNull();
    if (client == null || library == null || ids.isEmpty) return;
    final InterconnectDownloadManager manager = ref.read(
      interconnectDownloadManagerProvider,
    );
    FushiToast.show(msg: t.video_online_download_started);
    await startAnimeEpisodeDownloads(
      manager: manager,
      library: library,
      template: client,
      episodeIds: ids,
    );
    if (mounted) await _reloadLibraryState();
  }

  Future<void> _downloadAll() async {
    final AnimeSourceVideoClient? client = _client;
    if (client == null) return;
    await _download(<String>[
      for (final RemoteVideoInfo info in client.remoteVideos)
        if (!_downloadedIds.contains(info.id)) info.id,
    ]);
  }

  /// 拿不到 AppModel 是正常状态（没有 ProviderScope 的宿主树，如 widget 测试）：
  /// 页面照常展示，只是没有「继续观看」落点。与 `MangaSeriesPage` 同一口径。
  AppModel? get _appModelOrNull {
    try {
      return ref.read(appProvider);
    } on Object {
      return null;
    }
  }

  /// 按远端断点时间戳找最近看过的一集。键与播放页合集模式的落盘同式：
  /// `(成员 id, 0)`（见 `VideoFushiPage._remotePositionKeyForIndex`）。
  void _reloadResumeIndex() {
    final AnimeSourceVideoClient? client = _client;
    final AppModel? appModel = _appModelOrNull;
    if (client == null || appModel == null || !mounted) return;
    final List<RemoteVideoInfo> members = client.remoteVideos;
    int best = -1;
    int bestAt = 0;
    for (int index = 0; index < members.length; index++) {
      final Object? at = appModel.prefsRepo.getPref(
        videoRemotePositionEpisodeAtPrefKey(members[index].id, 0),
        defaultValue: 0,
      );
      final int atMs = at is int ? at : 0;
      if (atMs > bestAt) {
        bestAt = atMs;
        best = index;
      }
    }
    if (best != _resumeIndex) setState(() => _resumeIndex = best);
  }

  /// 扩展字幕轨的默认语言：与自动下字幕同一条链（字幕工作台的默认语言 > 默认内容
  /// 语言），都没设就不表态、保持扩展给的轨序。client 起播时才调用（见
  /// [AnimeSourceVideoClient.preferredSubtitleLanguage]）。
  String? _preferredSubtitleLanguage() {
    // 播放页叠在本页之上，本页正常一直挂着；万一已卸载，`ref` 不可用，不表态。
    if (!mounted) return null;
    final AppModel appModel = ref.read(appProvider);
    return resolveSubtitleDownloadLanguage(
      explicitSubtitlePreference: appModel.jimakuDefaultLanguage,
      globalDefaultContentLanguage: appModel.defaultContentLanguage,
    );
  }

  /// 点集即进播放器：取流与选线路交给播放页（它有「正在连接视频流」阶段与失败态，
  /// 没可播流也在那里以 `video_online_stream_none` 报出）。
  Future<void> _play(int index) async {
    final AnimeSourceVideoClient? client = _client;
    if (client == null) return;
    // 已下载到本机的集直接播本地文件（普通本地视频行，进度与在线时同一个 bookUid）。
    final String id = client.remoteVideos[index].id;
    if (_downloadedIds.contains(id) && widget.openPlayer == null) {
      final VideoBookRepository repo =
          widget.repositoryOverride ??
          VideoBookRepository(ref.read(appProvider).database);
      await Navigator.of(context).push(
        adaptivePageRoute<void>(
          context: context,
          builder: (BuildContext context) =>
              VideoFushiPage.neutralized(bookUid: id, repo: repo),
        ),
      );
      _reloadResumeIndex();
      return;
    }
    await _openPlayer(client, index);
  }

  Future<void> _openPlayer(AnimeSourceVideoClient client, int index) async {
    final List<RemoteVideoInfo> members = client.remoteVideos;
    final RemoteVideoInfo info = members[index];
    final Future<void> Function(
      BuildContext,
      AnimeSourceVideoClient,
      RemoteVideoInfo,
      int,
    )?
    override = widget.openPlayer;
    if (override != null) {
      await override(context, client, info, index);
      return;
    }
    final VideoBookRepository repo =
        widget.repositoryOverride ??
        VideoBookRepository(ref.read(appProvider).database);
    await Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => VideoFushiPage.neutralizedRemote(
          info: info,
          repo: repo,
          client: client,
          remoteCollectionMembers: members.length > 1 ? members : null,
          initialEpisodeIndex: members.length > 1 ? index : null,
        ),
      ),
    );
    // 播放页退出时已把断点落进 prefs：回来立刻刷新「继续观看」落点。
    _reloadResumeIndex();
  }

  /// 「在网站打开」：源站网页地址（扩展的 `getAnimeUrl`，兜底 baseUrl + url）交给
  /// 系统浏览器。打不开浏览器不算本页错误，只提示。
  Future<void> _openWebsite() async {
    final Uri? url = await resolveMihonAnimeWebUrl(
      runtime: widget.manager.runtime,
      context: widget.sourceContext,
      anime: _anime,
    );
    if (!mounted) return;
    if (url == null) {
      FushiToast.show(
        msg: t.mihon_source_website_unavailable,
        severity: ToastSeverity.warning,
      );
      return;
    }
    try {
      await (widget.openExternal ?? _launchExternal)(url);
    } on Object catch (error) {
      if (!mounted) return;
      FushiToast.show(msg: '$error', severity: ToastSeverity.error);
    }
  }

  static Future<void> _launchExternal(Uri url) async {
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return FushiPageScaffold(
      title: _anime.title,
      subtitle: widget.sourceContext.source.name,
      actions: <Widget>[
        FushiIconButtonControl(
          key: const ValueKey<String>('anime_source_open_website'),
          tooltip: t.mihon_source_website_open,
          onPressed: () => unawaited(_openWebsite()),
          icon: const FushiIcon(Icons.open_in_new),
        ),
        FushiIconButtonControl(
          tooltip: t.refresh,
          onPressed: _loading ? null : () => unawaited(_load()),
          icon: const FushiIcon(Icons.refresh),
        ),
      ],
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final Object? error = _error;
    final int resume = _resumeIndex;
    final bool canPlay = !_loading && _episodes.isNotEmpty;
    return ListView(
      padding: withBottomSafeInset(context, const EdgeInsets.all(16)),
      children: <Widget>[
        OnlineWorkHeader(
          cover: MihonSourceImage(
            runtime: widget.manager.runtime,
            cache: widget.manager.coverCache,
            context: widget.sourceContext,
            url: _anime.coverUrl,
          ),
          title: _anime.title,
          lines: <String?>[_anime.author],
          genres: splitOnlineWorkGenres(_anime.genre),
          description: _anime.description,
          actions: <Widget>[
            FushiFilledButton.icon(
              key: const ValueKey<String>('anime_source_play'),
              onPressed: canPlay
                  ? () => unawaited(_play(resume >= 0 ? resume : 0))
                  : null,
              icon: const FushiIcon(Icons.play_arrow),
              label: Text(
                resume >= 0 && resume < _episodes.length
                    ? '${t.video_continue_watching} · '
                          '${_episodeTitle(_episodes[resume])}'
                    : t.play,
              ),
            ),
            // 「加入」与「移出」各按各的判据，可以同时出现：下载过其中几集后其余集
            // 仍能加入、已入库的作品刷新出新集仍能补；「移出」只删在线行。
            if (_canAddToLibrary)
              FushiOutlinedButton.icon(
                key: const ValueKey<String>('anime_source_library_add'),
                onPressed: !canPlay || _libraryBusy
                    ? null
                    : () => unawaited(_addToLibrary()),
                icon: const FushiIcon(Icons.video_library_outlined),
                label: Text(t.video_online_library_add),
              ),
            if (_canRemoveFromLibrary)
              FushiOutlinedButton.icon(
                key: const ValueKey<String>('anime_source_library_remove'),
                onPressed: _libraryBusy
                    ? null
                    : () => unawaited(_removeFromLibrary()),
                icon: const FushiIcon(Icons.video_library),
                label: Text(t.video_online_library_remove),
              ),
            FushiOutlinedButton.icon(
              key: const ValueKey<String>('anime_source_download_all'),
              onPressed: canPlay ? () => unawaited(_downloadAll()) : null,
              icon: const FushiIcon(Icons.download_outlined),
              label: Text(t.video_online_download_all),
            ),
          ],
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // 错误走统一提示条（MD3 中性底 + error 图标 / Apple tertiaryFill
                // 实色底），不再是一行裸红字。
                FushiInlineNotice(
                  severity: FushiNoticeSeverity.error,
                  message: '$error',
                ),
                MihonCloudflareAction(
                  runtime: widget.manager.runtime,
                  error: error,
                  onVerified: _load,
                ),
              ],
            ),
          ),
        OnlineWorkSectionTitle(t.video_online_episodes_title),
        if (_loading || _episodes.isEmpty)
          OnlineWorkItemsPlaceholder(
            loading: _loading,
            emptyText: t.video_online_episodes_empty,
          )
        else
          for (int index = 0; index < _episodes.length; index++)
            _buildEpisodeRow(context, index),
      ],
    );
  }

  String _episodeTitle(MihonEpisode episode) =>
      episode.name.isNotEmpty ? episode.name : episode.number.toString();

  Widget _buildEpisodeRow(BuildContext context, int index) {
    final MihonEpisode episode = _episodes[index];
    final String? uploaded = episode.uploadedAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(
            episode.uploadedAt,
          ).toLocal().toString().split(' ').first
        : null;
    final String? scanlator = episode.scanlator?.trim();
    final String? id = _client?.remoteVideos[index].id;
    return OnlineWorkItemTile(
      key: ValueKey<String>('anime_episode_${episode.url}'),
      title: _episodeTitle(episode),
      subtitle: <String>[
        if (uploaded != null) uploaded,
        if (scanlator != null && scanlator.isNotEmpty) scanlator,
        if (id != null && _downloadedIds.contains(id))
          t.video_online_downloaded,
      ].join(' · '),
      current: index == _resumeIndex,
      trailing: id == null ? null : _episodeDownloadAction(id),
      onTap: () => unawaited(_play(index)),
    );
  }

  /// 行尾：已下载 = 完成标记；下载中 = 进度环（管理器任务快照）；否则 = 下载按钮。
  Widget _episodeDownloadAction(String id) {
    if (_downloadedIds.contains(id)) {
      return FushiTooltip(
        message: t.video_online_downloaded,
        child: const FushiIcon(Icons.download_done),
      );
    }
    // 只订阅整数百分比，字节级进度回报不整页重建（BUG-2944）。
    final InterconnectDownloadBadgeState? task = _appModelOrNull == null
        ? null
        : ref.watch(
            interconnectDownloadManagerProvider.select(
              (m) => m.badgeStateFor(id),
            ),
          );
    if (task != null && task.status == InterconnectDownloadStatus.running) {
      return SizedBox.square(
        dimension: 24,
        child: FushiCircularProgressIndicator(
          strokeWidth: 2,
          value: task.percent < 0 ? null : task.percent / 100,
        ),
      );
    }
    return FushiIconButtonControl(
      key: ValueKey<String>('anime_download_$id'),
      tooltip: t.video_online_download_episode,
      onPressed: () => unawaited(_download(<String>[id])),
      icon: const FushiIcon(Icons.download_outlined),
    );
  }
}
