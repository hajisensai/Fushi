import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_feature_flags.dart';
import 'package:hibiki/src/media/video/video_import_dialog.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/video_hibiki_page.dart';
import 'package:hibiki/utils.dart';

/// 首页「视频」tab 的内容：已导入视频的库（独立于书架的 EPUB/有声书分区）。
///
/// 仅在实验性视频开关开启时由 [HomePage] 装配进底栏（见 home_page.dart 的
/// [HomeTab.video]）。列出 [VideoBookRepository.listAll] 的视频卡片，点开进
/// [VideoHibikiPage] 播放/查词/制卡；顶栏导入按钮（同样受实验开关门控）打开
/// [VideoImportDialog] 新建导入，与书架的视频导入入口共用同一对话框与仓库。
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

  @override
  Widget build(BuildContext context) {
    final AppModel appModel = ref.watch(appProvider);
    // 导入入口与书架一致：编译期常量或运行时实验开关任一开启即放出。能进到本页
    // 通常意味着实验开关已开，这里仍按同一规则判定，保持单一真相。
    final bool canImport =
        kVideoImportEnabled || appModel.experimentalVideoEnabled;
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
      body: FutureBuilder<List<VideoBookRow>>(
        future: _future,
        builder:
            (BuildContext context, AsyncSnapshot<List<VideoBookRow>> snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final List<VideoBookRow> books =
              snapshot.data ?? const <VideoBookRow>[];
          if (books.isEmpty) {
            return _buildEmpty();
          }
          return _buildGrid(books);
        },
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
    return HibikiCard(
      key: ValueKey<String>('home_video_${book.bookUid}'),
      focusId: HibikiFocusId('home-video-${book.bookUid}'),
      padding: EdgeInsets.zero,
      onTap: () => _open(book),
      onLongPress: () => _open(book),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(child: _buildCover(book)),
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
