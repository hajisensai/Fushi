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

  AppModel get _appModel => ref.read(appProvider);

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
                            child: FushiFilledButton.icon(
                              onPressed: _busy ? null : () => _stream(detail),
                              icon: const FushiIcon(FushiIcons.play),
                              label: Text(t.audiobookshelf_item_stream),
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
                          enabled: !_busy,
                          onTap: () => _stream(detail, episode: episode),
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
    required this.enabled,
    required this.onTap,
  });

  final int index;
  final int count;
  final AudiobookshelfEpisode episode;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String subtitle = audiobookshelfEpisodeSubtitle(episode);
    return FushiGroupedListItem(
      index: index,
      count: count,
      onTap: enabled ? onTap : null,
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
                  if (subtitle.isNotEmpty)
                    Text(subtitle, style: tokens.type.metadata, maxLines: 1),
                ],
              ),
            ),
            SizedBox(width: tokens.spacing.gap),
            const FushiIcon(FushiIcons.play),
          ],
        ),
      ),
    );
  }
}
