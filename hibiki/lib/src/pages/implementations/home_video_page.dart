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
import 'package:hibiki/src/media/video/video_subtitle_attach.dart';
import 'package:hibiki/src/media/video/video_feature_flags.dart';
import 'package:hibiki/src/media/video/video_import_dialog.dart';
import 'package:hibiki/src/media/video/video_mpv_config.dart';
import 'package:hibiki/src/media/video/video_shader_downloader.dart';
import 'package:hibiki/src/media/video/video_shader_manager.dart';
import 'package:hibiki/src/media/video/video_shader_tier.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/book_drag_target.dart';
import 'package:hibiki/src/pages/implementations/collections_page.dart';
import 'package:hibiki/src/pages/implementations/tag_filter_bar.dart';
import 'package:hibiki/src/pages/implementations/tag_filter_sheet.dart';
import 'package:hibiki/src/pages/implementations/tag_picker_page.dart';
import 'package:hibiki/src/pages/implementations/video_hibiki_page.dart';
import 'package:hibiki/src/pages/implementations/video_statistics_page.dart';
import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/remote_download_progress_badge.dart';
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

  /// 正在下载中的远端视频（key = [RemoteVideoInfo.id]）。值为进度分数 0..1；
  /// 收到首个 onProgress 前为 null（不确定进度）。下载期间用它在卡片上替换下载
  /// 按钮为进度指示（#3：远端下载全程有进行中反馈，不再 await 完才弹一次提示）。
  final Map<String, double?> _downloadingVideos = <String, double?>{};

  /// 视频卡片拖放命中注册表：每张 [CardDropZone] 注册自身几何，拖放时按屏幕坐标
  /// 命中查找目标视频卡（字幕外挂到该视频）。范型=VideoBookRow。
  final CardDropRegistry<VideoBookRow> _cardDropRegistry =
      CardDropRegistry<VideoBookRow>();

  /// 批量选择模式（与书架 tab 对齐）。开启后卡片点击切换勾选、长按/拖放禁用，
  /// 底部弹批量操作栏（打标签 / 删除）。视频书是扁平 bookUid（不像书架有
  /// epub `mediaIdentifier` + `srt_` 双类前缀），故选择集直接用 bookUid 字符串。
  bool _selectionMode = false;
  final Set<String> _selectedUids = <String>{};

  /// 当前可见（过滤后）的本地视频列表，供全选 / 反选用。
  List<VideoBookRow> _visibleVideos = const <VideoBookRow>[];

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
      // #6: 远端与本地是同一视频时（同 bookUid）不在「配对设备」区重复展示。
      final List<VideoBookRow> localVideos = await widget.repo.listAll();
      final Set<String> localUids =
          localVideos.map((VideoBookRow r) => r.bookUid).toSet();
      return _RemoteVideoState(
        videos: dedupeRemoteVideos(remote: videos, localBookUids: localUids),
      );
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

  // ── 批量选择（与书架 tab 对齐）────────────────────────────────────
  // 书架 [reader_hibiki_history_page] 早有这套（_selectionMode / _selectedKeys /
  // 批量打标签 + 删除）；视频 tab 共用同一 [HibikiTagFilterBar]（其 selectionMode /
  // onToggleSelectionMode 入参书架已用、视频此前没传）。这里给视频补上 wiring，
  // 批量操作语义对齐书架（批量打标签 + 批量删除），但因视频书是扁平 bookUid，
  // 选择集与 picker 比书架简单一层（无 epub/srt 双类分支）。

  void _toggleSelectionMode() {
    setState(() {
      _selectionMode = !_selectionMode;
      _selectedUids.clear();
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedUids.clear();
    });
  }

  void _toggleSelection(String bookUid) {
    setState(() {
      if (!_selectedUids.remove(bookUid)) {
        _selectedUids.add(bookUid);
      }
    });
  }

  void _selectAllVisible() {
    setState(() {
      for (final VideoBookRow book in _visibleVideos) {
        _selectedUids.add(book.bookUid);
      }
    });
  }

  void _invertSelection() {
    setState(() {
      final Set<String> all = <String>{
        for (final VideoBookRow book in _visibleVideos) book.bookUid,
      };
      final Set<String> inverted = all.difference(_selectedUids);
      _selectedUids
        ..clear()
        ..addAll(inverted);
    });
  }

  /// 批量删除选中视频书：确认 → 逐个 [VideoBookRepository.deleteVideoBook] →
  /// 刷新列表/标签映射 → 退出选择态 → toast。
  Future<void> _batchDeleteConfirm() async {
    final int count = _selectedUids.length;
    if (count == 0) return;
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(t.dialog_delete),
        content: Text(t.batch_delete_confirm(n: count)),
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

    final Set<String> toDelete = Set<String>.of(_selectedUids);
    final List<VideoBookRow> deletedBooks = <VideoBookRow>[];
    for (final String bookUid in toDelete) {
      final VideoBookRow? book = await widget.repo.getByBookUid(bookUid);
      if (book == null) continue;
      await widget.repo.deleteVideoBook(bookUid);
      deletedBooks.add(book);
    }
    final int deleted = deletedBooks.length;
    if (!mounted) return;
    _exitSelectionMode();
    _refreshAfterTagChange();
    await _waitForVideoCardsToUnmount();
    for (final VideoBookRow book in deletedBooks) {
      await widget.repo.reclaimDeletedVideoBookAssets(
        deletedBookUid: book.bookUid,
        deletedCoverPath: book.coverPath,
        deletedSubtitlePath: book.subtitleSource,
        deletedVideoPath: book.videoPath,
      );
    }
    if (deleted > 0) {
      await widget.repo.compactAfterVideoDeleteBestEffort();
    }
    if (!mounted) return;
    HibikiToast.show(msg: t.batch_delete_success(n: deleted));
  }

  Future<void> _waitForVideoCardsToUnmount() async {
    final Future<List<VideoBookRow>>? future = _future;
    if (future != null) {
      try {
        await future;
      } catch (_) {
        // Refresh failures are surfaced by the FutureBuilder; deletion cleanup
        // stays best-effort and should still run.
      }
    }
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
  }

  /// 批量打标签：弹 [_VideoBatchTagPickerDialog]（每个标签三态：保持/添加/移除），
  /// 应用到所有选中视频书（经 [HibikiDatabase.addTagToVideoBook] /
  /// [HibikiDatabase.removeTagFromVideoBook]），关闭后刷新映射。
  Future<void> _batchShowTagPicker() async {
    if (_selectedUids.isEmpty) return;
    final List<BookTagRow>? allTags = ref.read(allTagsProvider).valueOrNull;
    if (allTags == null || allTags.isEmpty) {
      HibikiToast.show(msg: t.tag_no_tags_hint);
      return;
    }
    await showAppDialog<void>(
      context: context,
      builder: (_) => _VideoBatchTagPickerDialog(
        allTags: allTags,
        selectedUids: Set<String>.of(_selectedUids),
        database: ref.read(appProvider).database,
      ),
    );
    if (!mounted) return;
    _refreshAfterTagChange();
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
        // 字幕拖到具体视频卡：直接挂到那张卡所代表的**现有**视频书（不重新导入）。
        // 旧实现走 _openVideoImportPrefilled→VideoImportDialog._doImport，对已存在
        // 视频重算 singleVideoBookUid 触发同名去重、建 `video/<name> (2)` 重复条目，
        // 字幕没挂到原视频（TODO-079 根因）。
        _attachSubtitleToVideoCard(hit!, files.subtitles.first);
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

  /// 复用 [VideoImportDialog] 打开方式，预填视频/字幕路径（**新建导入**用）。对话框
  /// 按文件名派生 bookUid，用户确认后保存，关闭后刷新列表。「把字幕挂到已有视频卡」
  /// 不走这里——它会对已存在视频重算 bookUid 触发同名去重建重复条目（TODO-079），
  /// 改走 [_attachSubtitleToVideoCard] 直接对命中卡 bookUid 落库。
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

  /// 把拖到某张视频卡上的外挂字幕挂到**那张卡代表的现有视频书**（TODO-079）。
  ///
  /// 经 [attachSubtitleToVideoBook]：拷盘到 `<appDocs>/video_subtitles/` → 解析 cue →
  /// 对命中卡 `book.bookUid` 原子 saveSubtitleSelection（源指针 + cue），下次进播放页
  /// 直接 `loadCues` 命中。不新建视频书、不去重加后缀（修掉旧重复导入路径的 bug）。
  /// 按结果给 SnackBar 反馈；播放列表卡无单一字幕语义，提示进播放页按集挂。
  Future<void> _attachSubtitleToVideoCard(
    VideoBookRow book,
    String subtitlePath,
  ) async {
    final SubtitleAttachResult result = await attachSubtitleToVideoBook(
      repo: widget.repo,
      book: book,
      subtitlePath: subtitlePath,
    );
    if (!mounted) return;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String message;
    switch (result.outcome) {
      case SubtitleAttachOutcome.attached:
        message = t.video_subtitle_attached_to_video(
          title: book.title,
          count: result.cueCount,
        );
        _refresh();
      case SubtitleAttachOutcome.playlistNeedsPlayer:
        message = t.video_subtitle_attach_playlist_hint;
      case SubtitleAttachOutcome.unsupported:
        message = t.video_subtitle_import_unsupported;
      case SubtitleAttachOutcome.copyFailed:
        message = t.video_subtitle_import_failed;
      case SubtitleAttachOutcome.emptyCues:
        message = t.video_subtitle_load_failed(label: result.label);
    }
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  void _openStatistics() {
    Navigator.push(
      context,
      adaptivePageRoute<void>(builder: (_) => const VideoStatisticsPage()),
    );
  }

  /// 打开收藏夹页（书签 + 收藏句子，含视频来源的收藏句子，TODO-047 ③a）。与书架页头
  /// 的收藏夹入口同一 [CollectionsPage]——视频与书架共用一个收藏夹，按来源区分展示。
  void _openCollections() {
    Navigator.push(
      context,
      adaptivePageRoute<void>(builder: (_) => const CollectionsPage()),
    );
  }

  Future<void> _open(VideoBookRow book) async {
    await _showAnime4kFirstUsePromptIfNeeded();
    if (!mounted) return;
    Navigator.push(
      context,
      adaptivePageRoute<void>(
        builder: (_) => VideoHibikiPage.neutralized(
            bookUid: book.bookUid, repo: widget.repo),
      ),
    );
  }

  Future<void> _openRemote(RemoteVideoInfo video) async {
    final RemoteVideoClient? client = _remoteVideoClient;
    if (client == null) return;
    // 打开远端播放页后再弹首次着色器提示（而非提示阻塞导航）：远端入口的契约是
    // 「点击立即建立远端流」（home_video_remote_interconnect_test），把一次性的着色器
    // 提示放到 await 导航前会让远端串流请求永远不发出（TODO-026 回归）。提示是纯信息
    // 性的（只置 videoAnime4kPromptShown），叠加在已打开的播放页之上即可，不必先于导航。
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
    await _showAnime4kFirstUsePromptIfNeeded();
  }

  Future<void> _showAnime4kFirstUsePromptIfNeeded() async {
    final AppModel appModel = ref.read(appProvider);
    if (appModel.prefsRepo.videoAnime4kPromptShown) return;
    await appModel.prefsRepo.setVideoAnime4kPromptShown();
    if (!mounted) return;
    // 首次打开视频的提示：除「知道了」外给一个「一键下载并启用」按钮（用户诉求 4），
    // 点它即下载推荐画质着色器（「中」档 = Anime4K Fast）并启用，不必自己摸进设置。
    final bool? download = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(t.video_shader_first_use_title),
        content: Text(t.video_shader_first_use_body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.dialog_close),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.video_shader_first_use_download),
          ),
        ],
      ),
    );
    if (download == true && mounted) {
      await _downloadAndEnableDefaultShaderTier();
    }
  }

  /// 一键下载并启用「中」档（Anime4K Fast）：下载预设文件到着色器目录，再原子写
  /// mpv 内置缩放开关（开）+ 启用集（中档着色器），即下次打开视频生效。带 SnackBar 反馈。
  ///
  /// 不弹复杂进度对话框（首次提示场景从简）：下载用阻塞 await，开始/结束各一条提示。
  Future<void> _downloadAndEnableDefaultShaderTier() async {
    final AppModel appModel = ref.read(appProvider);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(content: Text(t.video_shader_downloading)));
    const VideoShaderTier tier = VideoShaderTier.medium;
    final Anime4kPreset? preset = shaderTierSpec(tier).preset;
    if (preset == null) return;
    Anime4kDownloadResult? result;
    try {
      result = await downloadAnime4kFiles(preset);
    } catch (_) {
      result = null;
    }
    if (!mounted) return;
    if (result == null || result.downloaded.isEmpty) {
      messenger.showSnackBar(
          SnackBar(content: Text(t.video_shader_download_failed)));
      return;
    }
    // 从目录现有文件按该档叠加顺序过滤出有序启用集。
    final List<String> present = await listShaderFiles();
    final List<String> enabled = orderedEnabledForTier(tier, present.toSet());
    final VideoMpvConfig cfg =
        VideoMpvConfig.decode(appModel.videoMpvConfig).copyWith(
      highQuality: true,
    );
    await appModel.setVideoMpvConfig(VideoMpvConfig.encode(cfg));
    await appModel.setVideoShadersEnabled(encodeEnabledShaders(enabled));
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(
      content: Text(result.allOk
          ? t.video_shader_download_done(count: result.downloaded.length)
          : t.video_shader_download_partial(
              ok: result.downloaded.length, failed: result.failed.length)),
    ));
  }

  Future<void> _downloadRemote(RemoteVideoInfo video) async {
    final RemoteVideoClient? client = _remoteVideoClient;
    // #3: 服务不可达 / 未鉴权时给明确提示，不再静默 return（用户点了像没反应）。
    if (client == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.remote_video_unavailable)),
      );
      return;
    }
    // 同一视频已在下载中：忽略重复点击。
    if (_downloadingVideos.containsKey(video.id)) return;
    // #3: 标记下载中（先置不确定进度），卡片立刻显示进行中反馈。
    setState(() => _downloadingVideos[video.id] = null);
    try {
      final File dest = await _remoteDownloadDestination(video);
      await client.downloadRemoteVideo(
        video.id,
        dest,
        onProgress: (double progress) {
          if (!mounted) return;
          setState(() => _downloadingVideos[video.id] = progress);
        },
      );
    } catch (e) {
      debugPrint('[home-video] remote video download failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.remote_video_download_failed)),
      );
      return;
    } finally {
      if (mounted) {
        setState(() => _downloadingVideos.remove(video.id));
      } else {
        _downloadingVideos.remove(video.id);
      }
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
      HibikiToast.show(msg: t.tag_added_to_video(name: tag.name));
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
    final String? deletedCoverPath = book.coverPath;
    final String? deletedSubtitlePath = book.subtitleSource;
    final String deletedVideoPath = book.videoPath;
    await widget.repo.deleteVideoBook(book.bookUid);
    if (mounted) {
      _refreshAfterTagChange();
      await _waitForVideoCardsToUnmount();
    }
    await widget.repo.reclaimDeletedVideoBookAssets(
      deletedBookUid: book.bookUid,
      deletedCoverPath: deletedCoverPath,
      deletedSubtitlePath: deletedSubtitlePath,
      deletedVideoPath: deletedVideoPath,
    );
    await widget.repo.compactAfterVideoDeleteBestEffort();
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
    // BUG-250: 视频 tab 的批量选择模式（[_selectionMode]）和书架一样活在 tab
    // 内容里、不是独立 route。顶层 HomePage 的 PopScope 对它无感，返回键会直接
    // 退出 App，而不是退出选择模式。这里用嵌套 PopScope 拦截：选择模式开启时
    // canPop=false，返回先退出选择模式（与书架 / 查词 tab 一致）。
    return PopScope(
      canPop: !_selectionMode,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        if (_selectionMode) _exitSelectionMode();
      },
      child: HibikiFileDropTarget(
        onDrop: _handleVideoDrop,
        child: CardDropScope<VideoBookRow>(
          registry: _cardDropRegistry,
          child: DesktopContentLayout(
            kind: DesktopContentKind.readerShelf,
            child: Column(
              children: <Widget>[
                if (!isCupertinoPlatform(context)) _buildPageHeader(canImport),
                _buildTagFilterBar(allTags),
                Expanded(
                  child: _buildVideoLibraryBody(),
                ),
                if (_selectionMode) _buildBatchActionBar(),
              ],
            ),
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
        // 记录当前可见（已过滤）的本地视频，供批量「全选 / 反选」用。同步赋字段
        // （不 setState），仅在批量操作回调时读取。
        _visibleVideos = books;
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
                    child: _downloadingVideos.containsKey(video.id)
                        ? RemoteDownloadProgressBadge(
                            key: ValueKey<String>(
                                'remote_video_downloading_$safeKey'),
                            progress: _downloadingVideos[video.id],
                            tooltip: t.remote_video_downloading,
                          )
                        : IconButton.filledTonal(
                            key: ValueKey<String>(
                                'remote_video_download_$safeKey'),
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
        // 图标顺序与书架完全一致：导入 → 收藏夹 → 统计。书架
        // [reader_hibiki_history_page._buildPageHeader] 把导入按钮放在第一位
        // （buildBookImportButton），收藏夹、统计紧随其后；视频 tab 照此对齐
        // （TODO-162：此前视频把导入放在末尾，与书架不一致）。视频导入仍受
        // [canImport] 门控（仅视频 tab 才有导入入口），这里只调整位置不改门控。
        if (canImport)
          HibikiIconButton(
            tooltip: t.video_import_action,
            icon: Icons.add,
            onTap: _openImport,
          ),
        HibikiIconButton(
          tooltip: t.collections,
          icon: Icons.collections_bookmark_outlined,
          onTap: _openCollections,
        ),
        HibikiIconButton(
          tooltip: t.video_statistics,
          icon: Icons.bar_chart_outlined,
          onTap: _openStatistics,
        ),
      ],
    );
  }

  /// 标签筛选栏：与书架完全一致——复用 [HibikiTagFilterBar]（内联 chip 点选筛选、
  /// 长按拖拽重排、末尾「管理标签」齿轮 + 「批量选择」动作）。共享
  /// [selectedTagIdsProvider] 与书架联动；批量选择动作经 [onToggleSelectionMode]
  /// 与书架对齐（TODO-063：此前视频 tab 没传，缺了「标签设置旁的选择」）。
  ///
  /// 渲染条件：与书架 [reader_hibiki_history_page._buildTagBar] 一致——**永远渲染
  /// 整栏**（不再「无标签隐藏」），批量选择按钮才能常驻露出（否则空标签库点不到
  /// 批量入口、无法批量删除）。组件内部「管理标签」齿轮仍只在有标签时显示，故无
  /// 标签时整栏只剩「批量选择」按钮。
  Widget _buildTagFilterBar(List<BookTagRow> tags) {
    return HibikiTagFilterBar(
      tags: tags,
      onToggleFilter: _toggleFilter,
      onReorder: _reorderTags,
      selectionMode: _selectionMode,
      onToggleSelectionMode: _toggleSelectionMode,
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
    final bool selected = _selectedUids.contains(book.bookUid);
    final HibikiCard hibikiCard = HibikiCard(
      key: ValueKey<String>('home_video_${book.bookUid}'),
      focusId: HibikiFocusId('home-video-${book.bookUid}'),
      padding: EdgeInsets.zero,
      selected: selected,
      // 选择态：点击切换勾选、长按禁用（与书架 _buildBookCard 一致）。
      onTap: _selectionMode
          ? () => _toggleSelection(book.bookUid)
          : () => _open(book),
      onLongPress: _selectionMode ? null : () => _showVideoMenu(book),
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
                if (_selectionMode)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: _buildSelectionCheck(selected),
                  ),
                if (selected)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withValues(alpha: 0.12),
                        ),
                      ),
                    ),
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
    );
    // 选择态下禁用标签拖放命中（避免选卡时误触拖标签）。
    final Widget card = _selectionMode
        ? hibikiCard
        : BookDragTarget(
            bookId: book.bookUid,
            onTagDropped: (BookTagRow tag) =>
                _addTagToVideoBook(book.bookUid, tag),
            child: hibikiCard,
          );
    return CardDropZone<VideoBookRow>(
      meta: book,
      child: card,
    );
  }

  /// 批量选择勾选标记：选中实心对勾，未选空心圆（与书架 _buildBookCard 一致）。
  Widget _buildSelectionCheck(bool selected) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color selectionColor = tokens.surfaces.primary;
    return IgnorePointer(
      child: Container(
        decoration: BoxDecoration(
          color: selected
              ? selectionColor
              : tokens.surfaces.page.withValues(alpha: 0.7),
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? selectionColor : tokens.surfaces.outline,
            width: 1.5,
          ),
        ),
        padding: EdgeInsets.all(tokens.spacing.gap / 4),
        child: Icon(
          Icons.check,
          size: tokens.spacing.gap * 1.75,
          color: selected
              ? Theme.of(context).colorScheme.onPrimary
              : Colors.transparent,
        ),
      ),
    );
  }

  /// 批量操作栏（底部，仅选择态显示）：选中计数 + 全选 / 反选 + 打标签 + 删除。
  /// 与书架 [reader_hibiki_history_page._buildBatchActionBar] 对齐。
  Widget _buildBatchActionBar() {
    final ThemeData theme = Theme.of(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Material(
      elevation: 6,
      color: theme.colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: tokens.spacing.card - tokens.spacing.gap / 2,
            vertical: tokens.spacing.gap,
          ),
          child: Row(
            children: <Widget>[
              Text(
                t.batch_selected_count(n: _selectedUids.length),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(width: tokens.spacing.gap),
              TextButton(
                onPressed: _selectAllVisible,
                child: Text(t.batch_select_all),
              ),
              TextButton(
                onPressed: _invertSelection,
                child: Text(t.batch_invert_selection),
              ),
              const Spacer(),
              HibikiIconButton(
                enabled: _selectedUids.isNotEmpty,
                onTap: _batchShowTagPicker,
                icon: Icons.sell_outlined,
                tooltip: t.tag_label,
              ),
              SizedBox(width: tokens.spacing.gap / 2),
              HibikiIconButton(
                enabled: _selectedUids.isNotEmpty,
                onTap: _batchDeleteConfirm,
                icon: Icons.delete_outline,
                tooltip: t.dialog_delete,
                enabledColor: theme.colorScheme.error,
              ),
            ],
          ),
        ),
      ),
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

/// 视频批量打标签的三态意图：保持不变 / 添加该标签 / 移除该标签。
enum _VideoBatchTagIntent { keep, add, remove }

/// 视频 tab 批量打标签对话框（TODO-063）。对一组选中视频书（扁平 bookUid）逐标签
/// 设三态意图，应用时对每个 bookUid 调 [HibikiDatabase.addTagToVideoBook] /
/// [HibikiDatabase.removeTagFromVideoBook]。与书架的 `_BatchTagPickerDialog` 同语义，
/// 但视频是单一 uid 集合（无 epub `mediaIdentifier` + `srt_` 双类分支），故独立、更简单。
class _VideoBatchTagPickerDialog extends StatefulWidget {
  const _VideoBatchTagPickerDialog({
    required this.allTags,
    required this.selectedUids,
    required this.database,
  });

  final List<BookTagRow> allTags;
  final Set<String> selectedUids;
  final HibikiDatabase database;

  @override
  State<_VideoBatchTagPickerDialog> createState() =>
      _VideoBatchTagPickerDialogState();
}

class _VideoBatchTagPickerDialogState
    extends State<_VideoBatchTagPickerDialog> {
  final Set<int> _addTagIds = <int>{};
  final Set<int> _removeTagIds = <int>{};

  Future<void> _apply() async {
    final HibikiDatabase db = widget.database;

    for (final int tagId in _addTagIds) {
      for (final String bookUid in widget.selectedUids) {
        await db.addTagToVideoBook(bookUid, tagId);
      }
    }
    for (final int tagId in _removeTagIds) {
      for (final String bookUid in widget.selectedUids) {
        await db.removeTagFromVideoBook(bookUid, tagId);
      }
    }

    if (!mounted) return;
    for (final int tagId in _addTagIds) {
      final BookTagRow tag =
          widget.allTags.firstWhere((BookTagRow row) => row.id == tagId);
      HibikiToast.show(
        msg: t.batch_tag_added(name: tag.name, n: widget.selectedUids.length),
      );
    }
    for (final int tagId in _removeTagIds) {
      final BookTagRow tag =
          widget.allTags.firstWhere((BookTagRow row) => row.id == tagId);
      HibikiToast.show(
        msg: t.batch_tag_removed(name: tag.name, n: widget.selectedUids.length),
      );
    }
    Navigator.pop(context);
  }

  void _setTagIntent(BookTagRow tag, _VideoBatchTagIntent intent) {
    setState(() {
      _addTagIds.remove(tag.id);
      _removeTagIds.remove(tag.id);
      switch (intent) {
        case _VideoBatchTagIntent.keep:
          break;
        case _VideoBatchTagIntent.add:
          _addTagIds.add(tag.id);
        case _VideoBatchTagIntent.remove:
          _removeTagIds.add(tag.id);
      }
    });
  }

  _VideoBatchTagIntent _tagIntent(BookTagRow tag) {
    if (_addTagIds.contains(tag.id)) return _VideoBatchTagIntent.add;
    if (_removeTagIds.contains(tag.id)) return _VideoBatchTagIntent.remove;
    return _VideoBatchTagIntent.keep;
  }

  @override
  Widget build(BuildContext context) {
    final bool canApply = _addTagIds.isNotEmpty || _removeTagIds.isNotEmpty;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return HibikiDialogFrame(
      maxWidth: 520,
      maxHeightFactor: 0.86,
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: t.batch_tag_title,
        leadingIcon: Icons.sell_outlined,
        scrollable: true,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: ListView.builder(
          shrinkWrap: true,
          itemCount: widget.allTags.length,
          itemBuilder: (BuildContext _, int i) {
            final BookTagRow tag = widget.allTags[i];
            return _VideoBatchTagIntentRow(
              tag: tag,
              selected: _tagIntent(tag),
              onChanged: (_VideoBatchTagIntent intent) =>
                  _setTagIntent(tag, intent),
            );
          },
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context),
              child: Text(t.dialog_cancel),
            ),
            adaptiveDialogAction(
              context: context,
              isDefaultAction: true,
              onPressed: canApply ? _apply : null,
              child: Text(t.batch_tag_apply),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单行：标签名 + 三态 segmented（保持 / 添加 / 移除）。Material 图标统一（视频
/// tab 无需 Cupertino 分支）。
class _VideoBatchTagIntentRow extends StatelessWidget {
  const _VideoBatchTagIntentRow({
    required this.tag,
    required this.selected,
    required this.onChanged,
  });

  final BookTagRow tag;
  final _VideoBatchTagIntent selected;
  final ValueChanged<_VideoBatchTagIntent> onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color tagColor = Color(tag.colorValue);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return AdaptiveSettingsRow(
      title: tag.name,
      icon: Icons.sell_outlined,
      controlBelow: true,
      trailing: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            DecoratedBox(
              decoration: BoxDecoration(
                color: tagColor,
                shape: BoxShape.circle,
              ),
              child: const SizedBox(width: 12, height: 12),
            ),
            SizedBox(width: tokens.spacing.gap + tokens.spacing.gap / 2),
            Flexible(
              child: adaptiveSegmentedButton<_VideoBatchTagIntent>(
                context: context,
                segments: <ButtonSegment<_VideoBatchTagIntent>>[
                  ButtonSegment<_VideoBatchTagIntent>(
                    value: _VideoBatchTagIntent.keep,
                    tooltip: t.batch_tag_keep,
                    icon: const Icon(Icons.horizontal_rule_outlined, size: 16),
                  ),
                  ButtonSegment<_VideoBatchTagIntent>(
                    value: _VideoBatchTagIntent.add,
                    tooltip: t.batch_tag_add,
                    icon: const Icon(Icons.add, size: 16),
                  ),
                  ButtonSegment<_VideoBatchTagIntent>(
                    value: _VideoBatchTagIntent.remove,
                    tooltip: t.batch_tag_remove,
                    icon: Icon(
                      Icons.remove,
                      size: 16,
                      color: selected == _VideoBatchTagIntent.remove
                          ? theme.colorScheme.error
                          : null,
                    ),
                  ),
                ],
                selected: <_VideoBatchTagIntent>{selected},
                onSelectionChanged: (Set<_VideoBatchTagIntent> values) {
                  if (values.isNotEmpty) onChanged(values.first);
                },
                style: kSettingsSegmentedStyle,
              ),
            ),
          ],
        ),
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
