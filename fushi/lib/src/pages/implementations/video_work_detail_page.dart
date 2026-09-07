import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:fushi/src/media/collections/collection_episode_slot.dart';
import 'package:fushi/src/media/media_cover_source.dart';
import 'package:fushi/src/media/video/cover_ui/landscape_cover_image.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_credit_repository.dart';
import 'package:fushi/src/media/video/cover_ui/video_specs_panel.dart';
import 'package:fushi/src/media/video/video_specs_service.dart';
import 'package:fushi/src/media/video/stream_video_launch.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/pages/implementations/media_collection_detail_page.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

/// Stable reference to a canonical video work. A work is owned by either a
/// collection (episodic TV) or one VideoBook (standalone movie).
class VideoWorkRef {
  const VideoWorkRef.collection(this.collectionId) : bookUid = null;
  const VideoWorkRef.book(this.bookUid) : collectionId = null;

  final int? collectionId;
  final String? bookUid;
}

/// Unified work-level route. Collection works retain the mature episode and
/// management surface; standalone works use the same canonical v77 data.
class VideoWorkDetailPage extends StatelessWidget {
  const VideoWorkDetailPage({
    required this.database,
    this.videoSpecs,
    required this.repository,
    required this.workRef,
    required this.onChanged,
    this.remote,
    this.onDeleteMembersMedia,
    super.key,
  });

  final FushiDatabase database;

  /// 视频规格服务（v95）；构造注入，理由同 [MediaCollectionDetailPage.videoSpecs]。
  /// null = 不显示规格。
  final VideoSpecsService? videoSpecs;
  final VideoBookRepository repository;
  final VideoWorkRef workRef;
  final VoidCallback onChanged;

  /// 远端上下文：合集成员里「只在对端」的集靠它列出 / 流播 / 取封面。null = 纯本地
  /// 视图（调用方没有互联 client），与远端支持引入前逐字节相同。
  final CollectionRemoteContext? remote;

  final Future<void> Function(List<VideoBookRow> members)? onDeleteMembersMedia;

  @override
  Widget build(BuildContext context) {
    final int? collectionId = workRef.collectionId;
    if (collectionId != null) {
      return FutureBuilder<MediaCollectionRow?>(
        future: database.getMediaCollectionById(collectionId),
        builder: (BuildContext context,
            AsyncSnapshot<MediaCollectionRow?> snapshot) {
          final MediaCollectionRow? collection = snapshot.data;
          if (snapshot.connectionState != ConnectionState.done) {
            // BUG-2230：同上 —— 加载态与它下面的 `collection == null` 终态口径一致，
            // 都带 AppBar。future 悬挂时这里就是用户能看到的全部界面。
            return Scaffold(
              appBar: AppBar(),
              body: Center(child: adaptiveIndicator(context: context)),
            );
          }
          if (collection == null) {
            return Scaffold(
              appBar: AppBar(),
              body: Center(
                child: Text(t.video_load_failed_not_found),
              ),
            );
          }
          return MediaCollectionDetailPage(
            database: database,
            videoSpecs: videoSpecs,
            collection: collection,
            // 成员解析走共享的 [loadCollectionEpisodeSlots]：合集清单是跨端 union，
            // 「本机没有这一行」不等于「这一集不存在」（BUG-1704）。
            loadEpisodes: () => loadCollectionEpisodeSlots(
              repository: repository,
              collectionId: collection.id,
              loadRemoteVideos: remote?.loadRemoteVideos,
            ),
            remote: remote,
            onOpenEpisode: (VideoBookRow episode) {
              Navigator.push<void>(
                context,
                adaptivePageRoute<void>(
                  context: context,
                  builder: (_) => VideoFushiPage.neutralized(
                    bookUid: episode.bookUid,
                    repo: repository,
                    playlistCollectionId: collection.id,
                  ),
                ),
              );
            },
            onChanged: onChanged,
            onDeleteMembersMedia: onDeleteMembersMedia,
          );
        },
      );
    }
    return _StandaloneVideoWorkDetail(
      database: database,
      videoSpecs: videoSpecs,
      repository: repository,
      bookUid: workRef.bookUid!,
      onChanged: onChanged,
    );
  }
}

class _StandaloneVideoWorkDetail extends StatefulWidget {
  const _StandaloneVideoWorkDetail({
    required this.database,
    required this.videoSpecs,
    required this.repository,
    required this.bookUid,
    required this.onChanged,
  });

  final FushiDatabase database;
  final VideoSpecsService? videoSpecs;
  final VideoBookRepository repository;
  final String bookUid;
  final VoidCallback onChanged;

  @override
  State<_StandaloneVideoWorkDetail> createState() =>
      _StandaloneVideoWorkDetailState();
}

class _StandaloneVideoWorkDetailState
    extends State<_StandaloneVideoWorkDetail> {
  VideoBookRow? _book;
  VideoMetadataWorkRow? _work;
  VideoMetadataWorkCredits? _credits;
  List<VideoMetadataTermRow> _terms = const <VideoMetadataTermRow>[];
  List<VideoMetadataExtraRow> _extras = const <VideoMetadataExtraRow>[];
  List<VideoMetadataImageRow> _images = const <VideoMetadataImageRow>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // BUG-2230：`_load` 是 fire-and-forget 的，异常必须有归宿 —— 它连着 6 次 DB 读，
    // 任意一次抛出（并发下 sqlite BUSY 等）从前都会让 `_loading` 永远为 true，
    // 页面卡在转圈上。现在落到 `book == null` 的终态（带 AppBar，可退出）。
    unawaited(_loadGuarded());
  }

  /// [_load] 的异常边界：失败时收敛到「未找到」终态，而不是永久加载态。
  Future<void> _loadGuarded() async {
    try {
      await _load();
    } catch (e, st) {
      debugPrint('VideoWorkDetailPage load failed: $e\n$st');
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _load() async {
    final VideoBookRow? book =
        await widget.repository.getByBookUid(widget.bookUid);
    final VideoMetadataWorkRow? work =
        await widget.database.getVideoMetadataWorkByBook(widget.bookUid);
    final VideoMetadataWorkCredits? credits =
        await VideoMetadataCreditRepository(widget.database)
            .forBook(widget.bookUid);
    final List<VideoMetadataTermRow> terms = work == null
        ? const <VideoMetadataTermRow>[]
        : await widget.database.getVideoMetadataTermsForWork(work.id);
    final List<VideoMetadataExtraRow> extras = work == null
        ? const <VideoMetadataExtraRow>[]
        : await widget.database.getVideoMetadataExtras(work.id);
    final List<VideoMetadataImageRow> images = work == null
        ? const <VideoMetadataImageRow>[]
        : await widget.database.getVideoMetadataImages(workId: work.id);
    if (!mounted) return;
    setState(() {
      _book = book;
      _work = work;
      _credits = credits;
      _terms = terms;
      _extras = extras;
      _images = images;
      _loading = false;
    });
  }

  ImageProvider? _image(String kind) {
    for (final VideoMetadataImageRow image in _images) {
      if (image.kind != kind) continue;
      final String? path = image.localPath;
      if (path != null && File(path).existsSync()) return FileImage(File(path));
      if (image.remoteUrl.isNotEmpty) {
        return CachedNetworkImageProvider(image.remoteUrl);
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      // BUG-2230：加载态与它的兄弟终态（下面 `book == null` 分支）口径必须一致 ——
      // 都带 AppBar（= 返回键）。桌面端没有系统返回键，`_load` 若久久不返回，
      // 无顶栏的转圈就是一个没有出口的页面。
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: adaptiveIndicator(context: context)),
      );
    }
    final VideoBookRow? book = _book;
    if (book == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: Text(t.video_load_failed_not_found)),
      );
    }
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final VideoMetadataWorkRow? work = _work;
    final ImageProvider? poster = _image('poster') ??
        resolveMediaCoverImage(
            kind: MediaKind.video, localPath: book.coverPath);
    final ImageProvider? backdrop = _image('backdrop') ?? poster;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(backgroundColor: Colors.transparent),
      body: ListView(
        padding: EdgeInsets.zero,
        children: <Widget>[
          SizedBox(
            height:
                (MediaQuery.sizeOf(context).height * 0.62).clamp(400.0, 620.0),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                if (backdrop != null)
                  LandscapeCoverImage(
                    image: backdrop,
                    overlays: const <Widget>[
                      DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: <Color>[
                              Color(0x22000000),
                              Color(0xE8000000),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    tokens.spacing.page,
                    kToolbarHeight + tokens.spacing.page,
                    tokens.spacing.page,
                    tokens.spacing.section,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      if (poster != null)
                        SizedBox(
                          width: 210,
                          child: AspectRatio(
                            aspectRatio: 2 / 3,
                            child: ClipRRect(
                              borderRadius: FushiBorderRadius.card,
                              child: PortraitCoverImage(image: poster),
                            ),
                          ),
                        ),
                      if (poster != null)
                        SizedBox(width: tokens.spacing.section),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              work?.title ?? book.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .displaySmall
                                  ?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800,
                                  ),
                            ),
                            if (work?.originalTitle case final String title)
                              Text(
                                title,
                                style: const TextStyle(color: Colors.white70),
                              ),
                            const SizedBox(height: 10),
                            Text(
                              <String>[
                                if (work?.year != null) '${work!.year}',
                                if (work?.status?.isNotEmpty == true)
                                  work!.status!,
                                if (work?.rating != null)
                                  '★ ${work!.rating!.toStringAsFixed(1)}',
                                if (work?.runtimeMinutes != null)
                                  '${work!.runtimeMinutes} min',
                              ].join(' · '),
                              style: const TextStyle(color: Colors.white70),
                            ),
                            const SizedBox(height: 16),
                            FilledButton.icon(
                              onPressed: () => _playBook(book),
                              icon: const Icon(Icons.play_arrow_rounded),
                              label: Text(book.lastPositionMs > 0
                                  ? t.video_continue_watching
                                  : t.collection_play),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (work?.overview?.trim().isNotEmpty == true)
            Padding(
              padding: EdgeInsets.all(tokens.spacing.page),
              child: SelectableText(
                work!.overview!,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      height: 1.55,
                    ),
              ),
            ),
          // v95：技术规格。这一页是「一个文件 = 一部作品」，规格无歧义，摊开显示。
          // 探不到时整块不占位（VideoSpecsPanel 内部返回 shrink）。
          Padding(
            padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
            child: VideoSpecsPanel(
              service: widget.videoSpecs,
              filePath: book.videoPath,
            ),
          ),
          _buildTerms(tokens),
          _buildCredits(tokens),
          _buildExtras(tokens),
          SizedBox(height: tokens.spacing.page),
        ],
      ),
    );
  }

  Widget _buildTerms(FushiDesignTokens tokens) {
    if (_terms.isEmpty && (_credits?.identities.isEmpty ?? true)) {
      return const SizedBox.shrink();
    }
    final Map<String, List<String>> grouped = <String, List<String>>{};
    for (final VideoMetadataTermRow term in _terms) {
      grouped.putIfAbsent(term.kind, () => <String>[]).add(term.name);
    }
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          for (final MapEntry<String, List<String>> entry in grouped.entries)
            Chip(label: Text('${entry.key}: ${entry.value.join(' · ')}')),
          for (final VideoMetadataIdentitySummary id
              in _credits?.identities ?? const <VideoMetadataIdentitySummary>[])
            Chip(label: Text('${id.provider.toUpperCase()}: ${id.externalId}')),
        ],
      ),
    );
  }

  Widget _buildCredits(FushiDesignTokens tokens) {
    final List<VideoMetadataCreditSummary> credits =
        _credits?.credits ?? const <VideoMetadataCreditSummary>[];
    if (credits.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.section,
        tokens.spacing.page,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(t.video_work_cast_crew,
              style: Theme.of(context).textTheme.titleLarge),
          SizedBox(height: tokens.spacing.card),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final VideoMetadataCreditSummary credit in credits)
                Chip(
                  avatar: Icon(
                    credit.creditKind == 'voice_actor'
                        ? Icons.record_voice_over_outlined
                        : Icons.person_outline,
                    size: 18,
                  ),
                  label: Text(credit.displayName),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildExtras(FushiDesignTokens tokens) {
    if (_extras.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.section,
        tokens.spacing.page,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(t.video_work_trailers,
              style: Theme.of(context).textTheme.titleLarge),
          SizedBox(height: tokens.spacing.card),
          for (final VideoMetadataExtraRow extra in _extras)
            FushiListItem(
              padding: EdgeInsets.zero,
              leading: const Icon(Icons.play_circle_outline),
              title: Text(extra.title),
              subtitle: Text(extra.kind),
              onTap: () => unawaited(_playExtra(extra)),
            ),
        ],
      ),
    );
  }

  void _playBook(VideoBookRow book) {
    Navigator.push<void>(
      context,
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => VideoFushiPage.neutralized(
          bookUid: book.bookUid,
          repo: widget.repository,
        ),
      ),
    );
  }

  Future<void> _playExtra(VideoMetadataExtraRow extra) async {
    if (extra.bookUid != null) {
      final VideoBookRow? local =
          await widget.repository.getByBookUid(extra.bookUid!);
      if (local != null && mounted) _playBook(local);
      return;
    }
    if (extra.remoteUrl == null) return;
    try {
      final launch = await buildOnlineVideoExtraLaunch(
        id: extra.extraKey,
        title: extra.title,
        url: extra.remoteUrl!,
      );
      if (!mounted) return;
      await Navigator.push<void>(
        context,
        adaptivePageRoute<void>(
          context: context,
          builder: (_) => VideoFushiPage.neutralizedRemote(
            info: launch.info,
            repo: widget.repository,
            client: launch.client,
          ),
        ),
      );
    } on Object {
      if (mounted) FushiToast.show(msg: t.video_load_failed_generic);
    }
  }
}
