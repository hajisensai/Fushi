/// Audiobookshelf 条目详情：封面 + 信息 + 「流式播放」。播客列出单集，每集各自流式。
///
/// 「流式播放」= 同一条目（单集）建过书就直接打开；否则先选字幕（服务器上的或本机的），
/// 再在进度对话框里建书（取字幕 / 封面、按音轨偏移切时间轴、生成正文），最后用正常的
/// 阅读器入口打开——阅读器起会话时会认出这本书绑在服务器上，自动改走流式
/// （`AudiobookSessionLauncher`），查词与制卡都在阅读器里。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/audiobook/remote/audiobookshelf_stream_service.dart';
import 'package:fushi/src/media/discovery/audiobookshelf_server_config.dart';
import 'package:fushi/src/media/discovery/sources/audiobookshelf_discovery_source.dart';
import 'package:fushi/src/media/downloads/download_start_result.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/pages/implementations/download_actions.dart'
    show startDiscoveryItemDownload;
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi/src/pages/implementations/audiobookshelf/audiobookshelf_subtitle_dialog.dart';
import 'package:fushi/src/pages/implementations/audiobookshelf/audiobookshelf_ui_helpers.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_api.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:material_ui/material_ui.dart';

class AudiobookshelfItemDetailPage extends ConsumerStatefulWidget {
  const AudiobookshelfItemDetailPage({
    required this.server,
    required this.api,
    required this.item,
    super.key,
  });

  final AudiobookshelfServerConfig server;
  final AudiobookshelfApi api;
  final AudiobookshelfItem item;

  @override
  ConsumerState<AudiobookshelfItemDetailPage> createState() =>
      _AudiobookshelfItemPageState();
}

class _AudiobookshelfItemPageState
    extends ConsumerState<AudiobookshelfItemDetailPage> {
  late Future<AudiobookshelfItemDetail> _detail = _loadDetail();
  bool _busy = false;

  /// 服务器上的收听进度（条目 / 单集）；读不到就是空，页面照常用。
  Map<String, AudiobookshelfMediaProgress> _progress =
      <String, AudiobookshelfMediaProgress>{};

  @override
  void initState() {
    super.initState();
    unawaited(_loadProgress());
  }

  Future<void> _loadProgress() async {
    try {
      final Map<String, AudiobookshelfMediaProgress> latest = await widget.api
          .allMediaProgress();
      if (mounted) setState(() => _progress = latest);
    } catch (_) {}
  }

  AudiobookshelfMediaProgress? _progressOf(String? episodeId) =>
      _progress[audiobookshelfProgressKey(widget.item.id, episodeId)];

  /// 标记已听完 / 未听完（元素为 null = 条目本身）。单条失败不挡其余。
  Future<void> _mark(List<String?> episodeIds, {required bool finished}) async {
    Object? failure;
    for (final String? episodeId in episodeIds) {
      try {
        await widget.api.setFinished(
          widget.item.id,
          episodeId: episodeId,
          finished: finished,
        );
      } catch (e) {
        failure = e;
      }
    }
    if (!mounted) return;
    FushiToast.show(
      msg: failure != null
          ? t.audiobookshelf_mark_failed(
              reason: audiobookshelfDescribeError(failure),
            )
          : finished
          ? t.audiobookshelf_marked_finished
          : t.audiobookshelf_marked_unfinished,
      severity: failure != null ? ToastSeverity.error : ToastSeverity.success,
    );
    await _loadProgress();
  }

  /// 单集菜单（长按 / 右键）：标记已听完 / 未听完，或「这一集及更早的」一起标。
  Future<void> _showEpisodeMenu(
    List<AudiobookshelfEpisode> episodes,
    int index,
  ) async {
    final AudiobookshelfEpisode episode = episodes[index];
    final bool finished = _progressOf(episode.id)?.isFinished ?? false;
    final _EpisodeMark? choice = await showAppDialog<_EpisodeMark>(
      context: context,
      builder: (BuildContext dialogContext) => FushiAlertDialog(
        title: Text(
          episode.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            FushiListItem(
              leading: FushiIcon(
                finished ? FushiIcons.visibilityOff : FushiIcons.check,
              ),
              title: Text(
                finished
                    ? t.audiobookshelf_mark_unfinished
                    : t.audiobookshelf_mark_finished,
              ),
              onTap: () => Navigator.pop(
                dialogContext,
                finished ? _EpisodeMark.unfinished : _EpisodeMark.finished,
              ),
            ),
            if (userConfiguredServersAvailable)
              FushiListItem(
                leading: const FushiIcon(FushiIcons.download),
                title: Text(t.audiobookshelf_item_download),
                onTap: () =>
                    Navigator.pop(dialogContext, _EpisodeMark.download),
              ),
            if (index < episodes.length - 1)
              FushiListItem(
                leading: const FushiIcon(FushiIcons.checklist),
                title: Text(t.audiobookshelf_mark_finished_through),
                onTap: () => Navigator.pop(dialogContext, _EpisodeMark.through),
              ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == _EpisodeMark.download) {
      await _download(episode: episode);
      return;
    }
    await _mark(
      choice == _EpisodeMark.through
          ? <String?>[
              for (final AudiobookshelfEpisode e in episodes.sublist(index))
                e.id,
            ]
          : <String?>[episode.id],
      finished: choice != _EpisodeMark.unfinished,
    );
  }

  AppModel get _appModel => ref.read(appProvider);

  /// 下载整本书（zip）或一集音频，走发现页同一条直链队列（下完自动入库，没有字幕就
  /// 留给「配对」）。这是用户自己服务器的离线副本，入口问
  /// `userConfiguredServersAvailable` 而不是下载中心的 `downloads` 门（2026-10-27 用户
  /// 拍板 iOS 也保留；iOS 上 ABS 源照常登记进发现源注册表，队列解析得到它）。令牌在队列真正开跑时才取（见 [AudiobookshelfDiscoverySource]）。
  Future<void> _download({AudiobookshelfEpisode? episode}) async {
    final AudiobookshelfItem item = widget.item;
    final DiscoveryResourceItem resource = DiscoveryResourceItem(
      sourceId: audiobookshelfSourceIdFor(widget.server.id),
      id: episode == null
          ? item.id
          : audiobookshelfEpisodeResourceId(item.id, episode.id),
      title: episode == null ? item.title : '${item.title} - ${episode.title}',
      kind: DiscoveryMediaKind.audiobook,
      payloadKind: DiscoveryPayloadKind.httpFile,
      sizeBytes: episode == null ? item.sizeBytes : episode.track.sizeBytes,
      coverUrl: widget.api.coverUri(item.id).toString(),
    );
    showDownloadStartNotices(
      await startDiscoveryItemDownload(
        context: context,
        appModel: _appModel,
        item: resource,
      ),
    );
  }

  bool get _isPodcast => widget.item.mediaType == 'podcast';

  Future<AudiobookshelfItemDetail> _loadDetail() =>
      // 播客请求非展开形状：展开的单集清单体积大、慢服务器上会超时。
      widget.api.itemDetail(widget.item.id, expanded: !_isPodcast);

  void _reload() => setState(() => _detail = _loadDetail());

  AudiobookshelfStreamService _service() => AudiobookshelfStreamService(
    db: _appModel.database,
    api: widget.api,
    serverConfigId: widget.server.id,
  );

  /// 流式播放 [episode]（null = 有声书条目本身）。
  Future<void> _stream(
    AudiobookshelfItemDetail detail, {
    AudiobookshelfEpisode? episode,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final AudiobookshelfStreamService service = _service();
      SrtBook? book = await service.findExisting(
        itemId: widget.item.id,
        episodeId: episode?.id,
      );
      if (book != null) {
        // 服务器重扫过就按新偏移重切字幕，再打开。
        await service.refreshExisting(
          book: book,
          detail: detail,
          episode: episode,
        );
      } else {
        if (!mounted) return;
        final AudiobookshelfSubtitleChoice? choice =
            await chooseAudiobookshelfSubtitle(
              context: context,
              detail: detail,
              episode: episode,
            );
        if (choice == null || !mounted) return;
        book = await _create(service, detail, episode, choice);
        if (book == null) return;
      }
      await _openBook(book);
    } catch (e) {
      if (mounted) {
        FushiToast.show(
          msg: t.audiobookshelf_stream_failed(
            reason: audiobookshelfDescribeError(e),
          ),
          severity: ToastSeverity.error,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<SrtBook?> _create(
    AudiobookshelfStreamService service,
    AudiobookshelfItemDetail detail,
    AudiobookshelfEpisode? episode,
    AudiobookshelfSubtitleChoice choice,
  ) async {
    final FushiProgressDialogHandle progress = showFushiProgressDialog(
      context: context,
      title: t.audiobookshelf_stream_preparing,
    );
    try {
      return await service.create(
        item: widget.item,
        detail: detail,
        episode: episode,
        subtitle: choice,
        onProgress: (double fraction, step, String? fileName) {
          progress.progress.value = fraction;
        },
      );
    } finally {
      progress.close();
    }
  }

  Future<void> _openBook(SrtBook book) async {
    final MediaItem? mediaItem = await ReaderFushiSource.instance
        .mediaItemForBookKey(book.bookKey);
    if (mediaItem == null) {
      if (mounted) {
        FushiToast.show(
          msg: t.srt_epub_not_ready,
          severity: ToastSeverity.error,
        );
      }
      return;
    }
    if (!mounted) return;
    await _appModel.openMedia(
      ref: ref,
      mediaSource: mediaItem.getMediaSource(appModel: _appModel),
      item: mediaItem,
    );
    // 听完回来：进度 / 已听完标记按服务器最新的刷新。
    if (mounted) unawaited(_loadProgress());
  }

  @override
  Widget build(BuildContext context) {
    return FushiPageScaffold(
      title: widget.item.title,
      subtitle: widget.item.authorName,
      body: Builder(builder: _buildBody),
    );
  }

  Widget _buildBody(BuildContext context) {
    final double top = MediaQuery.paddingOf(context).top;
    return FutureBuilder<AudiobookshelfItemDetail>(
      future: _detail,
      builder:
          (
            BuildContext context,
            AsyncSnapshot<AudiobookshelfItemDetail> snapshot,
          ) {
            if (snapshot.connectionState != ConnectionState.done) {
              return Padding(
                padding: EdgeInsets.only(top: top),
                child: const FushiLoadingView(),
              );
            }
            final AudiobookshelfItemDetail? detail = snapshot.data;
            if (detail == null) {
              return Padding(
                padding: EdgeInsets.only(top: top),
                child: FushiPlaceholderMessage(
                  icon: FushiIcons.cloudOff,
                  tone: FushiPlaceholderTone.error,
                  message: t.audiobookshelf_browse_load_failed,
                  detail: audiobookshelfDescribeError(
                    snapshot.error ?? 'unknown',
                  ),
                  action: FushiFilledButton.icon(
                    onPressed: _reload,
                    icon: const FushiIcon(FushiIcons.refresh),
                    label: Text(t.retry),
                  ),
                ),
              );
            }
            return _content(context, detail, top);
          },
    );
  }

  Widget _content(
    BuildContext context,
    AudiobookshelfItemDetail detail,
    double top,
  ) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<AudiobookshelfEpisode> episodes =
        audiobookshelfEpisodesNewestFirst(detail.episodes);
    final bool hasAudio = detail.isPodcast
        ? episodes.isNotEmpty
        : detail.tracks.isNotEmpty;

    return FushiEntranceScope(
      child: CustomScrollView(
        slivers: <Widget>[
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.page,
              top + tokens.spacing.gap,
              tokens.spacing.page,
              tokens.spacing.gap,
            ),
            sliver: SliverToBoxAdapter(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      FushiStaggeredEntrance(
                        index: 0,
                        // 用详情里的条目：列表给的是精简字段，没有旁白 / 系列。
                        child: _Header(api: widget.api, item: detail.item),
                      ),
                      if (!hasAudio)
                        FushiStaggeredEntrance(
                          index: 1,
                          child: Padding(
                            padding: EdgeInsets.only(
                              top: tokens.spacing.section,
                            ),
                            child: FushiPlaceholderMessage(
                              icon: FushiIcons.books,
                              message: t.audiobookshelf_item_no_audio,
                            ),
                          ),
                        )
                      else if (!detail.isPodcast)
                        FushiStaggeredEntrance(
                          index: 1,
                          child: Padding(
                            padding: EdgeInsets.only(
                              top: tokens.spacing.section,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                FushiFilledButton.icon(
                                  onPressed: _busy
                                      ? null
                                      : () => _stream(detail),
                                  icon: const FushiIcon(FushiIcons.play),
                                  label: Text(t.audiobookshelf_item_stream),
                                ),
                                if (userConfiguredServersAvailable) ...<Widget>[
                                  SizedBox(height: tokens.spacing.gap),
                                  FushiTextButton.icon(
                                    onPressed: _download,
                                    icon: const FushiIcon(FushiIcons.download),
                                    label: Text(t.audiobookshelf_item_download),
                                  ),
                                ],
                                SizedBox(height: tokens.spacing.gap),
                                _BookProgressRow(
                                  progress: _progressOf(null),
                                  onToggle: (bool finished) => _mark(<String?>[
                                    null,
                                  ], finished: finished),
                                ),
                              ],
                            ),
                          ),
                        )
                      else
                        FushiSectionTitle(
                          t.audiobookshelf_item_episodes,
                          padding: EdgeInsets.only(top: tokens.spacing.section),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (detail.isPodcast && episodes.isNotEmpty)
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                tokens.spacing.page,
                0,
                tokens.spacing.page,
                tokens.spacing.section,
              ),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  fushiStaggeredItemBuilder((BuildContext context, int index) {
                    final AudiobookshelfEpisode episode = episodes[index];
                    return Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 760),
                        child: _EpisodeRow(
                          index: index,
                          count: episodes.length,
                          episode: episode,
                          progress: _progressOf(episode.id),
                          enabled: !_busy,
                          onTap: () => _stream(detail, episode: episode),
                          onMenu: () =>
                              unawaited(_showEpisodeMenu(episodes, index)),
                        ),
                      ),
                    );
                  }),
                  childCount: episodes.length,
                ),
              ),
            )
          else
            SliverToBoxAdapter(child: SizedBox(height: tokens.spacing.section)),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.api, required this.item});

  final AudiobookshelfApi api;
  final AudiobookshelfItem item;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<String> lines = <String>[
      if (item.authorName case final String author) author,
      if (item.narratorName case final String narrator)
        t.discovery_audiobookshelf_item_narrated_by(name: narrator),
      if (item.seriesName case final String series) series,
      audiobookshelfCardSubtitle(item),
    ].where((String line) => line.isNotEmpty).toList();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 140,
          height: 140,
          child: ShelfCoverFrame(
            child: PortraitCoverImage(
              image: AppCachedHttpImage(
                api.coverUri(item.id, width: 400).toString(),
                cacheKey: 'abs:${api.serverUrl}:${item.id}',
              ),
              errorBuilder: (_) =>
                  const ShelfCoverPlaceholder(icon: FushiIcons.brokenImage),
            ),
          ),
        ),
        SizedBox(width: tokens.spacing.card),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(item.title, style: tokens.type.listTitle, maxLines: 3),
              SizedBox(height: tokens.spacing.gap / 2),
              for (final String line in lines)
                Text(line, style: tokens.type.metadata, maxLines: 2),
            ],
          ),
        ),
      ],
    );
  }
}

class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({
    required this.index,
    required this.count,
    required this.episode,
    required this.progress,
    required this.enabled,
    required this.onTap,
    required this.onMenu,
  });

  final int index;
  final int count;
  final AudiobookshelfEpisode episode;
  final AudiobookshelfMediaProgress? progress;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String subtitle = audiobookshelfEpisodeSubtitle(episode);
    final AudiobookshelfMediaProgress? p = progress;
    final bool finished = p?.isFinished ?? false;
    final String progressText = finished || p == null
        ? ''
        : audiobookshelfProgressPercent(p);
    return FushiGroupedListItem(
      index: index,
      count: count,
      onTap: enabled ? onTap : null,
      onLongPress: onMenu,
      onSecondaryTap: onMenu,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.rowHorizontal,
          vertical: tokens.spacing.rowVertical,
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    episode.title,
                    style: tokens.type.listTitle,
                    maxLines: 2,
                  ),
                  if (subtitle.isNotEmpty || progressText.isNotEmpty)
                    Text(
                      <String>[
                        if (subtitle.isNotEmpty) subtitle,
                        if (progressText.isNotEmpty) progressText,
                      ].join(' · '),
                      style: tokens.type.metadata,
                      maxLines: 1,
                    ),
                ],
              ),
            ),
            SizedBox(width: tokens.spacing.gap),
            if (finished) ...<Widget>[
              const FushiIcon(FushiIcons.check),
              SizedBox(width: tokens.spacing.gap),
            ],
            const FushiIcon(FushiIcons.play),
          ],
        ),
      ),
    );
  }
}

/// 单集菜单的选择结果。
enum _EpisodeMark { finished, unfinished, through, download }

/// 有声书的进度行：已听 N% / 已听完，加一个标记按钮。
class _BookProgressRow extends StatelessWidget {
  const _BookProgressRow({required this.progress, required this.onToggle});

  final AudiobookshelfMediaProgress? progress;
  final void Function(bool finished) onToggle;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final AudiobookshelfMediaProgress? p = progress;
    final bool finished = p?.isFinished ?? false;
    final String status = finished
        ? t.audiobookshelf_marked_finished
        : p == null
        ? ''
        : audiobookshelfProgressPercent(p);
    return Row(
      children: <Widget>[
        Expanded(child: Text(status, style: tokens.type.metadata)),
        FushiTextButton.icon(
          onPressed: () => onToggle(!finished),
          icon: FushiIcon(
            finished ? FushiIcons.visibilityOff : FushiIcons.check,
          ),
          label: Text(
            finished
                ? t.audiobookshelf_mark_unfinished
                : t.audiobookshelf_mark_finished,
          ),
        ),
      ],
    );
  }
}
