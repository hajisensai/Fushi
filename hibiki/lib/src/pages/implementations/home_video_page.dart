import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_feature_flags.dart';
import 'package:hibiki/src/media/video/video_import_dialog.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/tag_filter_sheet.dart';
import 'package:hibiki/src/pages/implementations/tag_picker_page.dart';
import 'package:hibiki/src/pages/implementations/video_hibiki_page.dart';
import 'package:hibiki/utils.dart';

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
  const HomeVideoPage({required this.repo, super.key});

  final VideoBookRepository repo;

  @override
  ConsumerState<HomeVideoPage> createState() => _HomeVideoPageState();
}

class _HomeVideoPageState extends ConsumerState<HomeVideoPage> {
  Future<List<VideoBookRow>>? _future;

  @override
  void initState() {
    super.initState();
    _future = widget.repo.listAll();
  }

  void _refresh() {
    setState(() {
      _future = widget.repo.listAll();
    });
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

  void _open(VideoBookRow book) {
    Navigator.push(
      context,
      adaptivePageRoute<void>(
        builder: (_) =>
            VideoHibikiPage(bookUid: book.bookUid, repo: widget.repo),
      ),
    );
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
    return Scaffold(
      appBar: adaptiveAppBar(
        context: context,
        title: Text(t.nav_video),
        actions: <Widget>[
          if (canImport)
            IconButton(
              tooltip: t.video_import_action,
              icon: const Icon(Icons.add),
              onPressed: _openImport,
            ),
        ],
      ),
      body: Column(
        children: <Widget>[
          _buildTagFilterBar(allTags),
          Expanded(
            child: FutureBuilder<List<VideoBookRow>>(
              future: _future,
              builder: (BuildContext context,
                  AsyncSnapshot<List<VideoBookRow>> snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                final List<VideoBookRow> all =
                    snapshot.data ?? const <VideoBookRow>[];
                final Set<String>? filter =
                    ref.watch(filteredVideoBookUidsProvider).valueOrNull;
                final List<VideoBookRow> books = filter == null
                    ? all
                    : all
                        .where((VideoBookRow b) => filter.contains(b.bookUid))
                        .toList();
                if (all.isEmpty) return _buildEmpty();
                if (books.isEmpty) return _buildFilteredEmpty();
                return _buildGrid(books);
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 标签筛选栏（与书架共用 [selectedTagIdsProvider]）：左侧筛选/管理按钮打开
  /// 共享 [TagFilterSheet]，右侧横向快速切换标签 chip。无标签时整栏隐藏。
  Widget _buildTagFilterBar(List<BookTagRow> tags) {
    if (tags.isEmpty) return const SizedBox.shrink();
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Set<int> selected = ref.watch(selectedTagIdsProvider);
    return SizedBox(
      height: 48,
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: t.tag_filter_title,
            icon: Icon(
              selected.isEmpty ? Icons.sell_outlined : Icons.sell,
              color: selected.isEmpty
                  ? null
                  : Theme.of(context).colorScheme.primary,
            ),
            onPressed: () => adaptiveModalSheet<void>(
              context: context,
              builder: (_) => const TagFilterSheet(),
            ),
          ),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsetsDirectional.only(end: tokens.spacing.page),
              itemCount: tags.length,
              separatorBuilder: (_, __) => SizedBox(width: tokens.spacing.gap),
              itemBuilder: (BuildContext context, int i) {
                final BookTagRow tag = tags[i];
                return Center(
                  child: HibikiSelectableChip(
                    selected: selected.contains(tag.id),
                    avatar: CircleAvatar(
                      backgroundColor: Color(tag.colorValue),
                      radius: 6,
                    ),
                    label: tag.name,
                    onSelected: (bool sel) {
                      final Set<int> next =
                          Set<int>.from(ref.read(selectedTagIdsProvider));
                      if (sel) {
                        next.add(tag.id);
                      } else {
                        next.remove(tag.id);
                      }
                      ref.read(selectedTagIdsProvider.notifier).state = next;
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
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
    return HibikiCard(
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
