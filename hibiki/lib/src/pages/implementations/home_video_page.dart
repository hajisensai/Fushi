import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/media/drag_drop/card_drop_registry.dart';
import 'package:hibiki/src/media/drag_drop/drop_classification.dart';
import 'package:hibiki/src/media/drag_drop/drop_decision.dart';
import 'package:hibiki/src/media/drag_drop/hibiki_file_drop_target.dart';
import 'package:hibiki/src/media/video/m3u8_playlist.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_feature_flags.dart';
import 'package:hibiki/src/media/video/video_import_dialog.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/book_drag_target.dart';
import 'package:hibiki/src/pages/implementations/tag_filter_bar.dart';
import 'package:hibiki/src/pages/implementations/tag_filter_sheet.dart';
import 'package:hibiki/src/pages/implementations/tag_picker_page.dart';
import 'package:hibiki/src/pages/implementations/video_hibiki_page.dart';
import 'package:hibiki/src/pages/implementations/video_statistics_page.dart';
import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/remote_cover_headers.dart';
import 'package:hibiki/src/sync/remote_video_client.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/utils.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 首页「视频」tab 的内容：已导入视频的库（独立于书架的 EPUB/有声书分区）。
///
/// 仅在实验性视频开关开启时由 [HomePage] 装配进底栏（见 home_page.dart 的
/// [HomeTab.video]）。列出 [VideoBookRepository.listAll] 的视频卡片，点开进
/// [VideoHibikiPage] 播放/查词/制卡；顶栏导入按钮（同样受实验开关门控）打开
/// [VideoImportDialog] 新建导入，与书架的视频导入入口共用同一对话框与仓库。
///
/// 标签：视频书与书架（EPUB/SRT）**共用同一套标签系统**（共享 `BookTags` 标签池
/// + `video_book_tag_mappings` 映射）。顶部有标签筛选栏（共享 [selectedTagIdsProvider]，
/// 与书架联动），卡片渲染所挂标签，长按弹菜单（编辑标签 / 设置封面 / 删除）。
class HomeVideoPage extends ConsumerStatefulWidget {
  const HomeVideoPage({
    required this.repo,
    this.remoteVideoClientLoader,
    this.remoteVideoDownloadDestination,
    super.key,
  });

  final VideoBookRepository repo;
  final Future<RemoteVideoClient?> Function()? remoteVideoClientLoader;
  final Future<File> Function(RemoteVideoInfo video)?
      remoteVideoDownloadDestination;

  @override
  ConsumerState<HomeVideoPage> createState() => _HomeVideoPageState();
}

class _HomeVideoPageState extends ConsumerState<HomeVideoPage> {
  Future<List<VideoBookRow>>? _future;
  Future<_RemoteVideoState?>? _remoteFuture;
  RemoteVideoClient? _remoteVideoClient;

  /// 视频卡片拖放命中注册表：每张 [CardDropZone] 注册自身几何，拖放时按屏幕坐标
  /// 命中查找目标视频卡（字幕外挂到该视频）。范型=VideoBookRow。
  final CardDropRegistry<VideoBookRow> _cardDropRegistry =
      CardDropRegistry<VideoBookRow>();

  @override
  void initState() {
    super.initState();
    _future = widget.repo.listAll();
    _remoteFuture = _loadRemoteVideos();
  }

  void _refresh() {
    setState(() {
      _future = widget.repo.listAll();
      _remoteFuture = _loadRemoteVideos();
    });
  }

  Future<RemoteVideoClient?> _resolveRemoteVideoClient() async {
    final Future<RemoteVideoClient?> Function()? injected =
        widget.remoteVideoClientLoader;
    if (injected != null) return injected();

    final AppModel appModel = ref.read(appProvider);
    final SyncRepository syncRepo = SyncRepository(appModel.database);
    if (await syncRepo.getBackendType() != SyncBackendType.hibikiServer) {
      return null;
    }
    final HibikiClientSyncBackend backend = HibikiClientSyncBackend.instance;
    if (!await backend.restoreAuth(syncRepo)) return null;
    return backend;
  }

  Future<_RemoteVideoState?> _loadRemoteVideos() async {
    final RemoteVideoClient? client = await _resolveRemoteVideoClient();
    _remoteVideoClient = client;
    if (client == null) return null;
    try {
      final List<RemoteVideoInfo> videos = await client.listRemoteVideos();
      return _RemoteVideoState(videos: videos);
    } catch (e) {
      debugPrint('[home-video] remote video list failed: $e');
      return const _RemoteVideoState(
        videos: <RemoteVideoInfo>[],
        failed: true,
      );
    }
  }

  /// 标签改动（加/删/换书）后刷新：失效共享标签 provider + 重载视频列表。
  void _refreshAfterTagChange() {
    ref.invalidate(videoBookTagMapProvider);
    ref.invalidate(filteredVideoBookUidsProvider);
    ref.invalidate(allTagsProvider);
    _refresh();
  }

  Future<void> _openImport() async {
    final String? bookUid = await showAppDialog<String>(
      context: context,
      builder: (_) => VideoImportDialog(repo: widget.repo),
    );
    if (bookUid != null) _refresh();
  }

  /// 拖放到视频 tab 时的处理：分类文件 → 局部坐标转屏幕坐标命中卡片 → 决策意图。
  ///
  /// [localPosition] 为相对 [HibikiFileDropTarget] 的局部坐标，需经本页 RenderBox
  /// 转屏幕坐标后再交给注册表命中（注册表存的是屏幕坐标矩形）。
  void _handleVideoDrop(List<String> paths, Offset localPosition) {
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;

    final DroppedFiles files = classifyDroppedFiles(paths);
    final RenderObject? ro = context.findRenderObject();
    Offset global = localPosition;
    if (ro is RenderBox && ro.attached) {
      global = ro.localToGlobal(localPosition);
    }
    final VideoBookRow? hit = _cardDropRegistry.hitTest(global);
    final DropIntent intent = decideDropIntent(
      surface: DropSurface.video,
      files: files,
      cardHit: hit != null,
    );
    switch (intent) {
      case DropIntent.importNewVideo:
        _openVideoImportPrefilled(
          videoPath: files.videos.first,
          subtitlePath:
              files.subtitles.isNotEmpty ? files.subtitles.first : null,
        );
      case DropIntent.importNewPlaylist:
        _openPlaylistImportPrefilled(playlistPath: files.playlists.first);
      case DropIntent.attachToVideoCard:
        _openVideoImportPrefilled(
          videoPath: hit!.videoPath,
          subtitlePath: files.subtitles.first,
        );
      case DropIntent.needCardTarget:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.drag_drop_need_card_target)),
        );
      case DropIntent.importNewBook:
      case DropIntent.attachToBookCard:
      case DropIntent.ignore:
        break;
    }
  }

  /// 复用 [VideoImportDialog] 打开方式，预填视频/字幕路径。新建导入与「附加字幕到
  /// 已有视频」走同一路径：对话框按文件名派生 bookUid，对同一视频幂等覆盖 cue，
  /// 用户确认后保存，关闭后刷新列表。
  Future<void> _openVideoImportPrefilled({
    required String videoPath,
    String? subtitlePath,
  }) async {
    final String? bookUid = await showAppDialog<String>(
      context: context,
      builder: (_) => VideoImportDialog(
        repo: widget.repo,
        initialVideoPath: videoPath,
        initialSubtitlePath: subtitlePath,
      ),
    );
    if (bookUid != null) _refresh();
  }

  /// 拖入 m3u8/m3u 播放列表：打开 [VideoImportDialog] 并预填 playlist 路径，对话框
  /// 自动解析多集落库（与手动点「播放列表」按钮同一路径），关闭后刷新列表。
  Future<void> _openPlaylistImportPrefilled({
    required String playlistPath,
  }) async {
    final String? bookUid = await showAppDialog<String>(
      context: context,
      builder: (_) => VideoImportDialog(
        repo: widget.repo,
        initialPlaylistPath: playlistPath,
      ),
    );
    if (bookUid != null) _refresh();
  }

  void _openStatistics() {
    Navigator.push(
      context,
      adaptivePageRoute<void>(builder: (_) => const VideoStatisticsPage()),
    );
  }

  void _open(VideoBookRow book) {
    Navigator.push(
      context,
      adaptivePageRoute<void>(
        builder: (_) => VideoHibikiPage.neutralized(
            bookUid: book.bookUid, repo: widget.repo),
      ),
    );
  }

  void _openRemote(RemoteVideoInfo video) {
    final RemoteVideoClient? client = _remoteVideoClient;
    if (client == null) return;
    Navigator.push(
      context,
      adaptivePageRoute<void>(
        builder: (_) => VideoHibikiPage.neutralizedRemote(
          info: video,
          repo: widget.repo,
          client: client,
        ),
      ),
    );
  }

  Future<void> _downloadRemote(RemoteVideoInfo video) async {
    final RemoteVideoClient? client = _remoteVideoClient;
    if (client == null) return;
    final File dest = await _remoteDownloadDestination(video);
    try {
      await client.downloadRemoteVideo(video.id, dest);
    } catch (e) {
      debugPrint('[home-video] remote video download failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.remote_video_download_failed)),
      );
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(t.remote_video_downloaded)),
    );
  }

  Future<File> _remoteDownloadDestination(RemoteVideoInfo video) async {
    final Future<File> Function(RemoteVideoInfo video)? injected =
        widget.remoteVideoDownloadDestination;
    if (injected != null) return injected(video);
    final Directory docs = await getApplicationDocumentsDirectory();
    final Directory dir = Directory(p.join(docs.path, 'remote_videos'));
    await dir.create(recursive: true);
    final String safeTitle =
        video.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final String fileName =
        safeTitle.toLowerCase().endsWith('.mp4') ? safeTitle : '$safeTitle.mp4';
    return File(p.join(dir.path, fileName));
  }

  // ── 长按菜单 ──────────────────────────────────────────────────────

  /// 长按视频卡：弹底部菜单（编辑标签 / 设置封面 / 删除）。这是修复
  /// 「视频长按没菜单」的入口——此前 onLongPress 与 onTap 同样只是打开播放页。
  void _showVideoMenu(VideoBookRow book) {
    showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.sell_outlined),
              title: Text(t.tag_label),
              onTap: () {
                Navigator.pop(ctx);
                _editTags(book);
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: Text(t.video_rename),
              onTap: () {
                Navigator.pop(ctx);
                _renameVideo(book);
              },
            ),
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: Text(t.srt_import_pick_cover),
              onTap: () {
                Navigator.pop(ctx);
                _pickCover(book);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(ctx).colorScheme.error),
              title: Text(
                t.dialog_delete,
                style: TextStyle(color: Theme.of(ctx).colorScheme.error),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _confirmDelete(book);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editTags(VideoBookRow book) async {
    await Navigator.push(
      context,
      adaptivePageRoute<void>(
        builder: (_) => TagPickerPage(videoBookUid: book.bookUid),
      ),
    );
    if (mounted) _refreshAfterTagChange();
  }

  Future<void> _addTagToVideoBook(String bookUid, BookTagRow tag) async {
    final Map<String, List<BookTagRow>>? existing =
        ref.read(videoBookTagMapProvider).valueOrNull;
    final bool alreadyHas =
        existing?[bookUid]?.any((BookTagRow t) => t.id == tag.id) ?? false;
    if (alreadyHas) {
      HibikiToast.show(msg: t.tag_already_on_book(name: tag.name));
      return;
    }

    await ref.read(appProvider).database.addTagToVideoBook(bookUid, tag.id);
    ref.invalidate(videoBookTagMapProvider);
    ref.invalidate(filteredVideoBookUidsProvider);
    if (mounted) {
      HibikiToast.show(msg: t.tag_added_to_book(name: tag.name));
    }
  }

  /// 设置封面：选图 → 经共享 [setVideoCoverFromPickedFile]（拷盘 + 驱逐旧缓存 +
  /// 落库）→ 刷新。与书架视频卡的换封面共用同一入口，封面与自动截图同目录。
  Future<void> _pickCover(VideoBookRow book) async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.image,
    );
    final String? pickedPath = result?.files.first.path;
    if (pickedPath == null || !mounted) return;
    await setVideoCoverFromPickedFile(
      repo: widget.repo,
      bookUid: book.bookUid,
      pickedPath: pickedPath,
    );
    if (mounted) _refresh();
  }

  /// 重命名视频/播放列表（C 需求③）：弹输入框预填当前标题 → 落库 → 刷新列表。
  /// 空白标题不提交（保持原名）。
  Future<void> _renameVideo(VideoBookRow book) async {
    final TextEditingController controller =
        TextEditingController(text: book.title);
    final String? newTitle = await showAppDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(t.video_rename),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: t.video_rename_hint),
          onSubmitted: (String v) => Navigator.pop(ctx, v),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t.dialog_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text(t.dialog_save),
          ),
        ],
      ),
    );
    controller.dispose();
    final String? trimmed = newTitle?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == book.title) return;
    await widget.repo.updateTitle(book.bookUid, trimmed);
    if (mounted) _refresh();
  }

  Future<void> _confirmDelete(VideoBookRow book) async {
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(t.video_delete_title),
        content: Text(t.video_delete_confirm(title: book.title)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.dialog_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              t.dialog_delete,
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.repo.deleteVideoBook(book.bookUid);
    if (mounted) _refreshAfterTagChange();
  }

  @override
  Widget build(BuildContext context) {
    final AppModel appModel = ref.watch(appProvider);
    // 导入入口与书架一致：编译期常量或运行时实验开关任一开启即放出。能进到本页
    // 通常意味着实验开关已开，这里仍按同一规则判定，保持单一真相。
    final bool canImport =
        kVideoImportEnabled || appModel.experimentalVideoEnabled;
    final List<BookTagRow> allTags =
        ref.watch(allTagsProvider).valueOrNull ?? const <BookTagRow>[];
    // 页头/布局与书架 [reader_hibiki_history_page]、词典 [home_dictionary_page]
    // 统一：不再用自带 Scaffold + adaptiveAppBar（小标题 + 标准 IconButton），改成
    // DesktopContentLayout + HibikiPageHeader（大标题 + HibikiIconButton），三个
    // 首页 tab 的标题字号与动作按钮位置因此完全一致。外层 Scaffold 由 HomePage 提供。
    return HibikiFileDropTarget(
      onDrop: _handleVideoDrop,
      child: CardDropScope<VideoBookRow>(
        registry: _cardDropRegistry,
        child: DesktopContentLayout(
          kind: DesktopContentKind.readerShelf,
          child: Column(
            children: <Widget>[
              if (!isCupertinoPlatform(context)) _buildPageHeader(canImport),
              _buildExperimentalBanner(context),
              _buildTagFilterBar(allTags),
              Expanded(
                child: _buildVideoLibraryBody(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVideoLibraryBody() {
    return FutureBuilder<List<VideoBookRow>>(
      future: _future,
      builder: (BuildContext context, AsyncSnapshot<List<VideoBookRow>> snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final List<VideoBookRow> all = snap.data ?? const <VideoBookRow>[];
        final Set<String>? filter =
            ref.watch(filteredVideoBookUidsProvider).valueOrNull;
        final List<VideoBookRow> books = filter == null
            ? all
            : all
                .where((VideoBookRow b) => filter.contains(b.bookUid))
                .toList();
        return FutureBuilder<_RemoteVideoState?>(
          future: _remoteFuture,
          builder: (BuildContext context,
              AsyncSnapshot<_RemoteVideoState?> remoteSnap) {
            final Widget local = all.isEmpty
                ? _buildEmpty()
                : books.isEmpty
                    ? _buildFilteredEmpty()
                    : _buildGrid(books);
            final Widget remote =
                _buildRemoteVideoSection(remoteSnap.data, remoteSnap);
            if (remote is SizedBox && remote.height == 0) return local;
            return Column(
              children: <Widget>[
                remote,
                Expanded(child: local),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildRemoteVideoSection(
    _RemoteVideoState? state,
    AsyncSnapshot<_RemoteVideoState?> snapshot,
  ) {
    if (snapshot.connectionState != ConnectionState.done) {
      return const SizedBox(
        height: 3,
        child: LinearProgressIndicator(),
      );
    }
    if (state == null) return const SizedBox.shrink();

    final ColorScheme colors = Theme.of(context).colorScheme;
    final List<RemoteVideoInfo> videos = state.videos;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.devices_other_outlined,
                  size: 18, color: colors.primary),
              const SizedBox(width: 8),
              Text(
                t.remote_video_interconnect,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(width: 10),
              Text(
                t.remote_video_paired_device,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ),
          if (state.failed)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                t.remote_video_load_failed,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: colors.error),
              ),
            )
          else if (videos.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            SizedBox(
              height: 200,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: videos.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (BuildContext context, int index) =>
                    _buildRemoteVideoCard(videos[index]),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRemoteVideoCard(RemoteVideoInfo video) {
    final String safeKey = _safeRemoteKey(video.id);
    return SizedBox(
      width: 260,
      child: HibikiCard(
        key: ValueKey<String>('remote_video_card_$safeKey'),
        focusId: HibikiFocusId('home-video-remote-$safeKey'),
        padding: EdgeInsets.zero,
        onTap: () => _openRemote(video),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  _buildRemoteVideoCover(video),
                  Positioned(
                    top: 6,
                    right: 6,
                    child: IconButton.filledTonal(
                      key: ValueKey<String>('remote_video_download_$safeKey'),
                      tooltip: t.remote_video_download,
                      iconSize: 18,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.download_outlined),
                      onPressed: () => _downloadRemote(video),
                    ),
                  ),
                  if (video.hasSubtitle)
                    Positioned(
                      top: 6,
                      left: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.62),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.subtitles_outlined,
                          size: 14,
                          color: Colors.white,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Text(
                video.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRemoteVideoCover(RemoteVideoInfo video) {
    final String safeKey = _safeRemoteKey(video.id);
    final String? coverPath = video.coverPath;
    if (coverPath != null && File(coverPath).existsSync()) {
      return Image.file(
        File(coverPath),
        key: ValueKey<String>('remote_video_cover_$safeKey'),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _coverPlaceholder(),
      );
    }
    final String? coverUrl = video.coverUrl;
    if (coverUrl != null && coverUrl.isNotEmpty) {
      return Image.network(
        coverUrl,
        key: ValueKey<String>('remote_video_cover_$safeKey'),
        headers: remoteCoverHeadersFor(_remoteVideoClient),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _coverPlaceholder(),
      );
    }
    return _coverPlaceholder();
  }

  String _safeRemoteKey(String id) =>
      id.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');

  /// 页头：与书架/词典统一，用 [HibikiPageHeader] 大标题 + [HibikiIconButton] 动作
  /// （统计 + 导入），保证标题字号与按钮位置三 tab 一致。与书架一致仅在非 Cupertino
  /// 渲染（Cupertino 走平台导航，由 HomePage 外壳承担）。
  Widget _buildPageHeader(bool canImport) {
    return HibikiPageHeader(
      title: t.nav_video,
      actions: <Widget>[
        HibikiIconButton(
          tooltip: t.video_statistics,
          icon: Icons.bar_chart_outlined,
          onTap: _openStatistics,
        ),
        if (canImport)
          HibikiIconButton(
            tooltip: t.video_import_action,
            icon: Icons.add,
            onTap: _openImport,
          ),
      ],
    );
  }

  /// 视频功能毕业为常驻 tab，但播放/查词/制卡仍为实验性：页头下方常驻一条提示
  /// 横幅，与底栏图标的小圆点徽标呼应。用 secondaryContainer 调性，不抢内容焦点。
  Widget _buildExperimentalBanner(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: colors.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.science_outlined,
            size: 18,
            color: colors.onSecondaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              t.video_experimental_banner,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSecondaryContainer,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  /// 标签筛选栏：与书架完全一致——复用 [HibikiTagFilterBar]（内联 chip 点选筛选、
  /// 长按拖拽重排、末尾「管理标签」齿轮）。共享 [selectedTagIdsProvider] 与书架联动；
  /// 视频 tab 无批量选择，故不传 onToggleSelectionMode。无标签时整栏隐藏。
  Widget _buildTagFilterBar(List<BookTagRow> tags) {
    if (tags.isEmpty) return const SizedBox.shrink();
    return HibikiTagFilterBar(
      tags: tags,
      onToggleFilter: _toggleFilter,
      onReorder: _reorderTags,
      onTagsChanged: () => ref.invalidate(videoBookTagMapProvider),
    );
  }

  void _toggleFilter(int tagId) {
    final Set<int> next = Set<int>.from(ref.read(selectedTagIdsProvider));
    if (next.contains(tagId)) {
      next.remove(tagId);
    } else {
      next.add(tagId);
    }
    ref.read(selectedTagIdsProvider.notifier).state = next;
  }

  Future<void> _reorderTags(int oldIndex, int newIndex) async {
    final List<BookTagRow>? tags = ref.read(allTagsProvider).valueOrNull;
    if (tags == null) return;
    final List<BookTagRow> reordered = List<BookTagRow>.from(tags);
    final BookTagRow item = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, item);
    final List<int> orderedIds = reordered.map((BookTagRow t) => t.id).toList();
    await ref.read(appProvider).database.reorderTags(orderedIds);
    ref.invalidate(allTagsProvider);
  }

  Widget _buildEmpty() {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.movie_outlined, size: 56, color: colors.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            t.video_library_empty,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildFilteredEmpty() {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.filter_list_off, size: 56, color: colors.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            t.tag_no_books_for_filter,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildGrid(List<VideoBookRow> books) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return GridView.builder(
      padding: EdgeInsets.all(tokens.spacing.card),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 280,
        mainAxisExtent: 200,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: books.length,
      itemBuilder: (BuildContext context, int i) => _buildCard(books[i]),
    );
  }

  Widget _buildCard(VideoBookRow book) {
    final List<BookTagRow> tags =
        ref.watch(videoBookTagMapProvider).valueOrNull?[book.bookUid] ??
            const <BookTagRow>[];
    final int episodeCount = playlistEpisodeCount(book.playlistJson);
    final Widget card = BookDragTarget(
      bookId: book.bookUid,
      onTagDropped: (BookTagRow tag) => _addTagToVideoBook(book.bookUid, tag),
      child: HibikiCard(
        key: ValueKey<String>('home_video_${book.bookUid}'),
        focusId: HibikiFocusId('home-video-${book.bookUid}'),
        padding: EdgeInsets.zero,
        onTap: () => _open(book),
        onLongPress: () => _showVideoMenu(book),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  _buildCover(book),
                  if (tags.isNotEmpty)
                    Positioned(
                      top: 6,
                      left: 6,
                      child: _buildTagLabels(tags),
                    ),
                  // 播放列表角标（≥2 集才算播放列表）：右上角「▶ N」徽标，与单视频
                  // 一眼区分（C 需求②）。
                  if (episodeCount >= 2)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: _buildPlaylistBadge(episodeCount),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Text(
                book.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
    return CardDropZone<VideoBookRow>(
      meta: book,
      child: card,
    );
  }

  /// 播放列表角标：右上角半透明胶囊「▶ N集」，与单视频卡一眼区分（C 需求②）。
  Widget _buildPlaylistBadge(int episodeCount) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.playlist_play, size: 14, color: Colors.white),
          const SizedBox(width: 3),
          Text(
            t.video_playlist_episodes(count: episodeCount),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  /// 卡片标签层：最多显示前 3 个 chip，超出折叠成「+N」（与书架卡风格一致）。
  Widget _buildTagLabels(List<BookTagRow> tags) {
    const int maxVisible = 3;
    final List<BookTagRow> visible = tags.take(maxVisible).toList();
    final int overflow = tags.length - visible.length;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final BookTagRow tag in visible)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: HibikiTagChip(label: tag.name, color: Color(tag.colorValue)),
          ),
        if (overflow > 0) HibikiTagChip(label: '+$overflow'),
      ],
    );
  }

  Widget _buildCover(VideoBookRow book) {
    final String? cover = book.coverPath;
    if (cover != null && File(cover).existsSync()) {
      return Image.file(
        File(cover),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _coverPlaceholder(),
      );
    }
    return _coverPlaceholder();
  }

  Widget _coverPlaceholder() {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colors.surfaceContainer,
      child: Center(
        child: Icon(Icons.movie_outlined,
            size: 40, color: colors.onSurfaceVariant),
      ),
    );
  }
}

class _RemoteVideoState {
  const _RemoteVideoState({
    required this.videos,
    this.failed = false,
  });

  final List<RemoteVideoInfo> videos;
  final bool failed;
}
