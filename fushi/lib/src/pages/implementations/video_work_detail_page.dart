import 'dart:async';
import 'dart:io';
import 'package:fushi_engine/media/video/bluray/bluray_source.dart';

import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/collections/collection_detail_layout.dart';
import 'package:fushi/src/media/collections/collection_episode_slot.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/media/media_cover_source.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_credit_repository.dart';
import 'package:fushi/src/media/video/metadata/video_credit_rail.dart';
import 'package:fushi/src/media/video/metadata/video_country_display.dart';
import 'package:fushi/src/media/video/cover_ui/video_specs_panel.dart';
import 'package:fushi/src/media/video/video_specs_service.dart';
import 'package:fushi/src/media/video/stream_video_launch.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/pages/implementations/media_collection_detail_page.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
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
class VideoWorkDetailPage extends StatefulWidget {
  const VideoWorkDetailPage({
    required this.database,
    this.videoSpecs,
    required this.repository,
    required this.workRef,
    required this.onChanged,
    this.remote,
    this.onDeleteMembersMedia,
    this.deleteMembersLocalFilesSubtitle,
    this.deleteMembersStatisticsSubtitle,
    this.onRescrapeCollection,
    this.onChooseTmdbOrdering,
    this.onPickOnlineCover,
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

  final Future<void> Function(
    List<VideoBookRow> members,
    bool deleteLocalFiles,
    bool deleteStatistics,
  )?
  onDeleteMembersMedia;

  /// 透传给 [MediaCollectionDetailPage.deleteMembersLocalFilesSubtitle]：
  /// 「同时删除其中的视频」之下的二级「同时删除本地文件」勾选说明。
  final String? deleteMembersLocalFilesSubtitle;

  /// 透传给 [MediaCollectionDetailPage.deleteMembersStatisticsSubtitle]。
  final String? deleteMembersStatisticsSubtitle;

  /// 透传给合集详情页的「重新刮削资料与封面」（刮削 controller 归 HomePage，
  /// 由库页注入）。null = 不渲染该菜单项。
  final Future<void> Function(MediaCollectionRow collection)?
  onRescrapeCollection;

  /// 透传给合集详情页的「TMDB 集编排」（备选排序）。null = 不渲染该菜单项。
  final Future<void> Function(MediaCollectionRow collection)?
  onChooseTmdbOrdering;

  /// 透传给合集详情页的「在线搜索封面」（BUG-2999）。null = 不渲染该菜单项。
  final Future<File?> Function(String workTitle)? onPickOnlineCover;

  @override
  State<VideoWorkDetailPage> createState() => _VideoWorkDetailPageState();
}

class _VideoWorkDetailPageState extends State<VideoWorkDetailPage> {
  /// 合集行查询。**必须持久化在 State 里，不能写在 build 里现取**（BUG-2010）：
  /// 写在 build 里 = 每次重建都换一个新 Future，FutureBuilder 认出 future 变了就
  /// 丢弃旧 snapshot 退回 waiting，整页落回加载指示器；更糟的是下面的
  /// [MediaCollectionDetailPage] 会被当成新子树重建，它自己的 `_loading` 一并复
  /// 位 → 剧集列表整份重查。而重建源不受本页控制：app 一拉到前台就走
  /// `AppLifecycleState.resumed` → 重取系统调色板 → 通知主题 → 全树重建，于是
  /// 「切回 Fushi 就闪一下」。future 的身份必须只由 (collectionId, database) 决定。
  ///
  /// 独立作品（[VideoWorkRef.book]）没有合集行要查，此处恒 null。
  Future<MediaCollectionRow?>? _collectionFuture;

  @override
  void initState() {
    super.initState();
    _collectionFuture = _loadCollection();
  }

  @override
  void didUpdateWidget(covariant VideoWorkDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workRef.collectionId != widget.workRef.collectionId ||
        oldWidget.database != widget.database) {
      _collectionFuture = _loadCollection();
    }
  }

  Future<MediaCollectionRow?>? _loadCollection() {
    final int? collectionId = widget.workRef.collectionId;
    if (collectionId == null) return null;
    return widget.database.getMediaCollectionById(collectionId);
  }

  @override
  Widget build(BuildContext context) {
    final int? collectionId = widget.workRef.collectionId;
    if (collectionId != null) {
      return FutureBuilder<MediaCollectionRow?>(
        future: _collectionFuture,
        builder:
            (
              BuildContext context,
              AsyncSnapshot<MediaCollectionRow?> snapshot,
            ) {
              final MediaCollectionRow? collection = snapshot.data;
              if (snapshot.connectionState != ConnectionState.done) {
                // BUG-2230：同上 —— 加载态与它下面的 `collection == null` 终态口径一致，
                // 都带 AppBar。future 悬挂时这里就是用户能看到的全部界面。
                return Scaffold(
                  appBar: FushiAppBar(),
                  body: Center(child: adaptiveIndicator(context: context)),
                );
              }
              if (collection == null) {
                return Scaffold(
                  appBar: FushiAppBar(),
                  body: Center(child: Text(t.video_load_failed_not_found)),
                );
              }
              return MediaCollectionDetailPage(
                database: widget.database,
                videoSpecs: widget.videoSpecs,
                collection: collection,
                // 成员解析走共享的 [loadCollectionEpisodeSlots]：合集清单是跨端 union，
                // 「本机没有这一行」不等于「这一集不存在」（BUG-1704）。
                loadEpisodes: () => loadCollectionEpisodeSlots(
                  repository: widget.repository,
                  collectionId: collection.id,
                  loadRemoteVideos: widget.remote?.loadRemoteVideos,
                ),
                remote: widget.remote,
                onOpenEpisode: (VideoBookRow episode) {
                  Navigator.push<void>(
                    context,
                    adaptivePageRoute<void>(
                      context: context,
                      builder: (_) => VideoFushiPage.neutralized(
                        bookUid: episode.bookUid,
                        repo: widget.repository,
                        playlistCollectionId: collection.id,
                      ),
                    ),
                  );
                },
                onOpenDiscMenu: (VideoBookRow episode) {
                  Navigator.push<void>(
                    context,
                    adaptivePageRoute<void>(
                      context: context,
                      builder: (_) => VideoFushiPage.neutralized(
                        bookUid: episode.bookUid,
                        repo: widget.repository,
                        playlistCollectionId: collection.id,
                        openBlurayMenu: true,
                      ),
                    ),
                  );
                },
                onChanged: widget.onChanged,
                onDeleteMembersMedia: widget.onDeleteMembersMedia,
                deleteMembersLocalFilesSubtitle:
                    widget.deleteMembersLocalFilesSubtitle,
                deleteMembersStatisticsSubtitle:
                    widget.deleteMembersStatisticsSubtitle,
                onRescrapeCollection: widget.onRescrapeCollection,
                onChooseTmdbOrdering: widget.onChooseTmdbOrdering,
                onPickOnlineCover: widget.onPickOnlineCover,
              );
            },
      );
    }
    return _StandaloneVideoWorkDetail(
      database: widget.database,
      videoSpecs: widget.videoSpecs,
      repository: widget.repository,
      bookUid: widget.workRef.bookUid!,
      onChanged: widget.onChanged,
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
      // 同 web_video：给了用户归宿就不能把诊断扔了（release 版 debugPrint 落空）。
      ErrorLogService.instance.log('video_work_detail', 'load failed: $e', st);
      debugPrint('VideoWorkDetailPage load failed: $e\n$st');
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _load() async {
    final VideoBookRow? book = await widget.repository.getByBookUid(
      widget.bookUid,
    );
    final VideoMetadataWorkRow? work = await widget.database
        .getVideoMetadataWorkByBook(widget.bookUid);
    final VideoMetadataWorkCredits? credits =
        await VideoMetadataCreditRepository(
          widget.database,
        ).forBook(widget.bookUid);
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
        return AppCachedHttpImage(image.remoteUrl);
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      // BUG-2230：加载态与它的兄弟终态（下面 `book == null` 分支）口径必须一致 ——
      // 都带 AppBar（= 返回键）。桌面端没有系统返回键，`_load` 若久久不返回，
      // 无顶栏的骨架就是一个没有出口的页面。
      return Scaffold(
        appBar: FushiAppBar(),
        body: const MediaDetailSkeleton(rows: 3),
      );
    }
    final VideoBookRow? book = _book;
    if (book == null) {
      return Scaffold(
        appBar: FushiAppBar(),
        body: FushiPlaceholderMessage(
          icon: FushiIcons.searchOff,
          tone: FushiPlaceholderTone.error,
          message: t.video_load_failed_not_found,
        ),
      );
    }
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final VideoMetadataWorkRow? work = _work;
    final ImageProvider? poster =
        _image('poster') ??
        _image('cover') ??
        resolveMediaCoverImage(
          kind: MediaKind.video,
          localPath: book.coverPath,
        );
    final ImageProvider? fanart = _image('backdrop');
    final String title = work?.title ?? book.title;
    final String? originalTitle = work?.originalTitle;
    final String? status = work?.status?.trim();
    final double? rating = work?.rating;
    final int? runtime = work?.runtimeMinutes;
    // M3E 作品详情：宽屏两栏（左 hero sticky、右规格 / 资料 / 人物 / 附件），
    // 窄屏单列。大背景 fanart 优先、没有就拿海报模糊垫底（与系列详情同一判据）。
    return Scaffold(
      // 背景铺满到窗口顶端（浮动顶栏下不留整宽底带），让位由布局处理。
      extendBodyBehindAppBar: true,
      appBar: FushiAppBar(),
      body: FushiEntranceScope(
        child: MediaDetailLayout(
          backdrop: collectionHeroBackdropImage(
            backdrop: fanart,
            cover: poster,
          ),
          backdropBlur: collectionHeroBackdropBlur(backdrop: fanart),
          bottomPadding: tokens.spacing.page,
          header: CollectionDetailHero(
            backdrop: fanart,
            cover: poster,
            title: title,
            originalTitle: originalTitle == title ? null : originalTitle,
            airDate: work?.premiereDate,
            chips: <MediaDetailChip>[
              if (work?.year case final int year)
                MediaDetailChip('$year', icon: FushiIcons.calendar),
              if (status != null && status.isNotEmpty)
                MediaDetailChip(status, tone: MediaDetailChipTone.secondary),
              if (rating != null && rating > 0)
                MediaDetailChip(
                  '★ ${rating.toStringAsFixed(1)}',
                  tone: MediaDetailChipTone.primary,
                ),
              if (runtime != null && runtime > 0)
                MediaDetailChip(
                  t.video_runtime_minutes(n: runtime),
                  icon: FushiIcons.timer,
                ),
            ],
            summary: work?.overview,
            playLabel: book.lastPositionMs > 0
                ? t.video_continue_watching
                : t.collection_play,
            playButtonKey: const ValueKey<String>('video-work-play'),
            onPlay: () => _playBook(book),
            secondaryActions: <Widget>[
              if (blurayDiscRootForPlaylistPath(book.videoPath) != null)
                MediaDetailSecondaryButton(
                  buttonKey: const ValueKey<String>('video-work-disc-menu'),
                  icon: FushiIcons.toc,
                  label: t.video_disc_open_menu,
                  onPressed: () => _playBook(book, openBlurayMenu: true),
                ),
            ],
          ),
          slivers: <Widget>[
            // v95：技术规格。这一页是「一个文件 = 一部作品」，规格无歧义，摊开
            // 显示。探不到时整块不占位（VideoSpecsPanel 内部返回 shrink）。
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  tokens.spacing.page,
                  tokens.spacing.section,
                  tokens.spacing.page,
                  0,
                ),
                child: VideoSpecsPanel(
                  service: widget.videoSpecs,
                  filePath: book.videoPath,
                ),
              ),
            ),
            SliverToBoxAdapter(child: _buildTerms(tokens)),
            SliverToBoxAdapter(child: _buildCredits(tokens)),
            SliverToBoxAdapter(child: _buildExtras(tokens)),
          ],
        ),
      ),
    );
  }

  /// 作品资料（类型 / 关键词 / 制作公司 / 地区 / 外部编号）：区块标题 + 元信息
  /// chip 行。
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          MediaDetailSectionHeader(t.video_work_details),
          MediaDetailChipRow(
            chips: <MediaDetailChip>[
              for (final MapEntry<String, List<String>> entry
                  in grouped.entries)
                MediaDetailChip(
                  _termChipText(entry.key, entry.value),
                  tone: MediaDetailChipTone.secondary,
                ),
              for (final VideoMetadataIdentitySummary id
                  in _credits?.identities ??
                      const <VideoMetadataIdentitySummary>[])
                MediaDetailChip(
                  '${id.provider.toUpperCase()}: ${id.externalId}',
                  icon: FushiIcons.link,
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 2026-10 体验优化：term 的 `kind` 是存储值（genre / keyword / studio /
  /// country），不能直接拼进 UI。与合集详情页 `_buildWorkDetailsSection` 同一套
  /// 本地化标签；不认识的 kind 只显示值，不把原始 kind 漏给用户。
  String _termChipText(String kind, List<String> names) {
    final String? label = switch (kind) {
      'genre' => t.video_work_genres,
      'keyword' => t.video_work_keywords,
      'studio' => t.video_work_studios,
      'country' => t.video_work_countries,
      _ => null,
    };
    final List<String> values = kind == 'country'
        ? formatVideoCountriesForDisplay(names)
        : names;
    final String joined = values.join(' · ');
    return label == null ? joined : '$label: $joined';
  }

  /// 与合集详情页同一份人物表（圆形头像横滑）：配音 / 演职人员分两条。此前这里
  /// 只画文字 Chip，照片无论刮到没刮到都不显示（BUG-2612）。
  Widget _buildCredits(FushiDesignTokens tokens) {
    final List<VideoMetadataCreditSummary> all =
        _credits?.credits ?? const <VideoMetadataCreditSummary>[];
    final List<VideoMetadataCreditSummary> voice = all
        .where(
          (VideoMetadataCreditSummary credit) =>
              credit.creditKind == 'voice_actor',
        )
        .toList(growable: false);
    final List<VideoMetadataCreditSummary> crew = all
        .where(
          (VideoMetadataCreditSummary credit) =>
              credit.creditKind != 'voice_actor',
        )
        .toList(growable: false);
    if (voice.isEmpty && crew.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (voice.isNotEmpty)
          VideoCreditRail(
            title: t.video_work_voice_roles,
            credits: voice,
            tokens: tokens,
          ),
        if (crew.isNotEmpty)
          VideoCreditRail(
            title: t.video_work_cast_crew,
            credits: crew,
            tokens: tokens,
          ),
      ],
    );
  }

  Widget _buildExtras(FushiDesignTokens tokens) {
    if (_extras.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // 2026-10 体验优化：按合集详情页口径拆成「预告片 / 花絮」两组，
          // 不再把原始 kind（trailer / featurette …）当副标题直接显示。
          for (final (String title, List<VideoMetadataExtraRow> rows)
              in <(String, List<VideoMetadataExtraRow>)>[
                (t.video_work_trailers, _extras.where(_isTrailer).toList()),
                (
                  t.video_work_extras,
                  _extras
                      .where((VideoMetadataExtraRow e) => !_isTrailer(e))
                      .toList(),
                ),
              ])
            if (rows.isNotEmpty) ...<Widget>[
              MediaDetailSectionHeader(title, count: rows.length),
              for (int i = 0; i < rows.length; i++)
                MediaDetailItemRow(
                  index: i,
                  count: rows.length,
                  title: rows[i].title,
                  leading: FushiIcon(
                    FushiIcons.playCircle,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  onTap: () => unawaited(_playExtra(rows[i])),
                ),
            ],
        ],
      ),
    );
  }

  /// 与合集详情页同一判据：trailer / teaser 归「预告片」，其余归「花絮」。
  static bool _isTrailer(VideoMetadataExtraRow extra) =>
      extra.kind == 'trailer' || extra.kind == 'teaser';

  void _playBook(VideoBookRow book, {bool openBlurayMenu = false}) {
    Navigator.push<void>(
      context,
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => VideoFushiPage.neutralized(
          bookUid: book.bookUid,
          repo: widget.repository,
          openBlurayMenu: openBlurayMenu,
        ),
      ),
    );
  }

  Future<void> _playExtra(VideoMetadataExtraRow extra) async {
    if (extra.bookUid != null) {
      final VideoBookRow? local = await widget.repository.getByBookUid(
        extra.bookUid!,
      );
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
