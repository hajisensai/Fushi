import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi/src/media/manga/mihon/mihon_cloudflare_action.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_source_browse_page.dart';
import 'package:fushi/src/media/manga/mihon/mihon_web_url.dart';
import 'package:fushi/src/media/video/online/anime_source_video_client.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/utils.dart';
import 'package:url_launcher/url_launcher.dart';

/// 视频源扩展的作品页：详情 + 剧集列表 → 内置播放器（起播默认选线路）。
///
/// 与漫画的 `MangaSeriesPage` 不同，本页**不入库**（浏览态零入库，收藏是二期）：
/// 进页拉一次详情与剧集，点集**直接进播放器**——取流、默认选线路（扩展标的
/// `preferred` / 排序第一条）都在播放页的「正在连接视频流」阶段做，多条候选
/// （画质 / hoster）不再在这里弹选择器拦一道，用户进去后在播放器画质菜单里换线路
/// （[AnimeSourceVideoClient] 的 `RemoteVideoStreamVariants` 能力）。播放页拿到整部
/// 作品的集列表当 `remoteCollectionMembers`，看完自动连播下一集。
class AnimeSourceDetailPage extends ConsumerStatefulWidget {
  const AnimeSourceDetailPage({
    required this.manager,
    required this.sourceContext,
    required this.anime,
    super.key,
    this.repositoryOverride,
    this.openPlayer,
    this.openExternal,
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

  @override
  ConsumerState<AnimeSourceDetailPage> createState() =>
      _AnimeSourceDetailPageState();
}

class _AnimeSourceDetailPageState extends ConsumerState<AnimeSourceDetailPage> {
  late MihonAnime _anime = widget.anime;
  List<MihonEpisode> _episodes = const <MihonEpisode>[];
  AnimeSourceVideoClient? _client;
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
        );
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error;
      });
    }
  }

  /// 点集即进播放器：取流与选线路交给播放页（它有「正在连接视频流」阶段与失败态，
  /// 没可播流也在那里以 `video_online_stream_none` 报出）。
  Future<void> _play(int index) async {
    final AnimeSourceVideoClient? client = _client;
    if (client == null) return;
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
        IconButton(
          key: const ValueKey<String>('anime_source_open_website'),
          tooltip: t.mihon_source_website_open,
          onPressed: () => unawaited(_openWebsite()),
          icon: const Icon(Icons.open_in_new),
        ),
        IconButton(
          tooltip: t.refresh,
          onPressed: _loading ? null : () => unawaited(_load()),
          icon: const Icon(Icons.refresh),
        ),
      ],
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Object? error = _error;
    return ListView(
      padding: withBottomSafeInset(context, const EdgeInsets.all(16)),
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 120,
              height: 170,
              child: FushiCard(
                padding: EdgeInsets.zero,
                child: MihonSourceImage(
                  runtime: widget.manager.runtime,
                  cache: widget.manager.coverCache,
                  context: widget.sourceContext,
                  url: _anime.coverUrl,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(_anime.title, style: theme.textTheme.titleLarge),
                  if (_anime.author != null && _anime.author!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        _anime.author!,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  if (_anime.genre != null && _anime.genre!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        _anime.genre!,
                        style: theme.textTheme.bodySmall,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        if (_anime.description != null && _anime.description!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(_anime.description!, style: theme.textTheme.bodyMedium),
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  '$error',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
                MihonCloudflareAction(
                  runtime: widget.manager.runtime,
                  error: error,
                  onVerified: _load,
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 24, bottom: 8),
          child: Text(
            t.video_online_episodes_title,
            style: theme.textTheme.titleMedium,
          ),
        ),
        if (_loading)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: adaptiveIndicator(context: context),
            ),
          )
        else if (_episodes.isEmpty)
          Text(t.video_online_episodes_empty)
        else
          for (int index = 0; index < _episodes.length; index++)
            _buildEpisodeRow(context, index),
      ],
    );
  }

  Widget _buildEpisodeRow(BuildContext context, int index) {
    final MihonEpisode episode = _episodes[index];
    final String? uploaded = episode.uploadedAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(
            episode.uploadedAt,
          ).toLocal().toString().split(' ').first
        : null;
    return FushiCard(
      padding: EdgeInsets.zero,
      child: FushiListItem(
        key: ValueKey<String>('anime_episode_${episode.url}'),
        title: Text(
          episode.name.isNotEmpty ? episode.name : episode.number.toString(),
        ),
        subtitle: uploaded == null
            ? null
            : Text(
                episode.scanlator == null || episode.scanlator!.isEmpty
                    ? uploaded
                    : '$uploaded · ${episode.scanlator}',
              ),
        trailing: const Icon(Icons.play_arrow),
        onTap: () => unawaited(_play(index)),
      ),
    );
  }
}
