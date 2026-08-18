import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_package_store.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_reader_chapter.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_runtime.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_source_browse_page.dart';
import 'package:fushi/src/media/manga/manga_global_search_runner.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_source_browse_page.dart';
import 'package:fushi/utils.dart';

/// 一次跨**所有已启用来源**搜索同一个书名的页面（Mihon 在线源 + Aidoku 已装包）。
///
/// 每个来源独立成一段：各自并发发起搜索、各自更新状态，一个源慢或失败都不拖累其余。
/// Cloudflare 保护的 Aidoku 源（MangaFire 等）headless 运行时解不了 JS 挑战，会被
/// 标成「受 Cloudflare 保护」而不是崩掉整页——点进单源浏览页时同理。
///
/// 平台差异只体现在**有哪些源**上：Mihon 仅桌面/安卓有宿主，Aidoku 只在 macOS/iOS
/// 有宿主。调用方（`MangaDiscoveryPage`）负责把当前平台上「已启用」的两类源传进来，
/// 本页不自己发现，方便测试注入。
class MangaGlobalSearchPage extends StatefulWidget {
  const MangaGlobalSearchPage({
    required this.mihonManager,
    required this.mihonSources,
    required this.aidokuPackages,
    super.key,
    this.aidokuRuntime,
    this.initialQuery,
  });

  /// Mihon 宿主。不支持的平台传 `null`（此时 [mihonSources] 必为空）。
  final MihonManager? mihonManager;

  /// 已启用、且扩展也启用的 Mihon 在线源。
  final List<MangaOnlineSourceRow> mihonSources;

  /// 已启用的 Aidoku 已装包。
  final List<AidokuInstalledPackage> aidokuPackages;

  /// Aidoku 运行时。为空时按平台创建；测试注入假运行时。
  final AidokuRuntime? aidokuRuntime;

  final String? initialQuery;

  @override
  State<MangaGlobalSearchPage> createState() => _MangaGlobalSearchPageState();
}

class _MangaGlobalSearchPageState extends State<MangaGlobalSearchPage> {
  final TextEditingController _searchController = TextEditingController();
  final MihonSourceImageLoadQueue _imageQueue =
      MihonSourceImageLoadQueue(maxConcurrent: 4);

  List<MangaSourceSearchRun> _runs = const <MangaSourceSearchRun>[];
  int _generation = 0;
  bool _searched = false;
  AidokuRuntime? _aidokuRuntime;

  @override
  void initState() {
    super.initState();
    final String? initial = widget.initialQuery?.trim();
    if (initial != null && initial.isNotEmpty) {
      _searchController.text = initial;
      unawaited(_search());
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<MangaGlobalSource> _sources() => <MangaGlobalSource>[
        for (final AidokuInstalledPackage package in widget.aidokuPackages)
          AidokuGlobalSource(package),
        for (final MangaOnlineSourceRow row in widget.mihonSources)
          MihonGlobalSource(row),
      ];

  /// 懒创建 Aidoku 运行时：无 Aidoku 源、或平台不支持时永不创建。
  AidokuRuntime? _resolveAidokuRuntime() {
    if (widget.aidokuRuntime != null) return widget.aidokuRuntime;
    if (widget.aidokuPackages.isEmpty) return null;
    if (!AidokuRuntimeFactory.isSupported) return null;
    return _aidokuRuntime ??= AidokuRuntimeFactory.create();
  }

  Future<void> _search() async {
    final String query = _searchController.text.trim();
    if (query.isEmpty) return;
    final int generation = ++_generation;
    final List<MangaSourceSearchRun> runs =
        _sources().map(MangaSourceSearchRun.new).toList(growable: false);
    setState(() {
      _searched = true;
      _runs = runs;
    });
    // 逐源扇出/限流/CF 分型在 runner（与统一发现框架共用有界并发原语）。
    await MangaGlobalSearchRunner(
      mihonManager: widget.mihonManager,
      resolveAidokuRuntime: _resolveAidokuRuntime,
    ).search(
      runs: runs,
      query: query,
      isCancelled: () => !mounted || generation != _generation,
      onRunUpdated: () {
        if (mounted && generation == _generation) setState(() {});
      },
    );
  }

  void _openMihon(MangaSourceSearchRun run, MihonManga manga) {
    final MihonSourceContext? sourceContext = run.mihonContext;
    final MihonManager? manager = widget.mihonManager;
    if (sourceContext == null || manager == null) return;
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => MihonMangaDetailPage(
          manager: manager,
          sourceContext: sourceContext,
          manga: manga,
        ),
      ),
    );
  }

  void _openAidoku(
    AidokuInstalledPackage package,
    Map<String, Object?> manga,
  ) {
    final AidokuRuntime? runtime = _resolveAidokuRuntime();
    if (runtime == null) return;
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => AidokuMangaDetailPage(
          package: package,
          runtime: runtime,
          manga: manga,
          sourceBaseUrl: null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FushiPageScaffold(
      title: t.manga_global_search_title,
      headerBottom: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: TextField(
          key: const ValueKey<String>('manga_global_search_field'),
          controller: _searchController,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: t.manga_global_search_hint,
            prefixIcon: const Icon(Icons.search),
          ),
          onSubmitted: (String _) => unawaited(_search()),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_sources().isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            t.manga_global_search_no_sources,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (!_searched) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            t.manga_global_search_prompt,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _runs.length,
      itemBuilder: (BuildContext context, int index) =>
          _buildSection(_runs[index]),
    );
  }

  Widget _buildSection(MangaSourceSearchRun run) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: <Widget>[
                if (run.source.language.isNotEmpty) ...<Widget>[
                  _LanguageChip(run.source.language),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    run.source.name,
                    style: Theme.of(context).textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                _statusTrailing(run),
              ],
            ),
          ),
          const SizedBox(height: 8),
          _buildSectionBody(run),
        ],
      ),
    );
  }

  Widget _statusTrailing(MangaSourceSearchRun run) => switch (run.status) {
        MangaSearchRunStatus.loading => const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        _ => const SizedBox.shrink(),
      };

  Widget _buildSectionBody(MangaSourceSearchRun run) {
    switch (run.status) {
      case MangaSearchRunStatus.loading:
        return const SizedBox(height: 200);
      case MangaSearchRunStatus.cloudflare:
        return _SectionMessage(t.manga_source_cloudflare_blocked);
      case MangaSearchRunStatus.error:
        return _SectionMessage('${run.error}');
      case MangaSearchRunStatus.empty:
        return _SectionMessage(t.mihon_source_no_results);
      case MangaSearchRunStatus.done:
        return _buildResultsStrip(run);
    }
  }

  Widget _buildResultsStrip(MangaSourceSearchRun run) {
    final int count = switch (run.source) {
      MihonGlobalSource() => run.mihonItems.length,
      AidokuGlobalSource() => run.aidokuItems.length,
    };
    // 桌面端默认 dragDevices 不含 mouse，横向滚动区必须包 HorizontalDragScrollable
    // 才能用鼠标左键拖动平移（横向滚动守卫）。
    return SizedBox(
      height: 210,
      child: HorizontalDragScrollable(
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: count,
          itemBuilder: (BuildContext context, int index) =>
              _buildHit(run, index),
        ),
      ),
    );
  }

  Widget _buildHit(MangaSourceSearchRun run, int index) {
    final Widget cover;
    final String title;
    final VoidCallback onTap;
    switch (run.source) {
      case MihonGlobalSource():
        final MihonManga manga = run.mihonItems[index];
        title = manga.title;
        cover = MihonSourceImage(
          runtime: widget.mihonManager!.runtime,
          cache: widget.mihonManager!.coverCache,
          context: run.mihonContext!,
          url: manga.coverUrl,
          loadQueue: _imageQueue,
        );
        onTap = () => _openMihon(run, manga);
      case AidokuGlobalSource(:final AidokuInstalledPackage package):
        final Map<String, Object?> manga = run.aidokuItems[index];
        title = manga['title']?.toString() ?? manga['key'].toString();
        cover = _AidokuStripCover(url: manga['cover']?.toString());
        onTap = () => _openAidoku(package, manga);
    }
    return SizedBox(
      width: 130,
      child: Padding(
        padding: const EdgeInsets.only(right: 12),
        child: FushiCard(
          padding: EdgeInsets.zero,
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(child: cover),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LanguageChip extends StatelessWidget {
  const _LanguageChip(this.language);

  final String language;

  @override
  Widget build(BuildContext context) => CircleAvatar(
        radius: 14,
        child: Text(
          language.toUpperCase(),
          style: Theme.of(context).textTheme.labelSmall,
        ),
      );
}

class _SectionMessage extends StatelessWidget {
  const _SectionMessage(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Text(
          message,
          style: TextStyle(color: Theme.of(context).colorScheme.outline),
        ),
      );
}

/// Aidoku 搜索结果封面。裸 `Image.network` + 浏览器 UA，与单源浏览页同一策略。
class _AidokuStripCover extends StatelessWidget {
  const _AidokuStripCover({required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final String value = url?.trim() ?? '';
    if (value.isEmpty) {
      return const ColoredBox(
        color: Color(0x11000000),
        child: Center(child: Icon(Icons.image_not_supported_outlined)),
      );
    }
    return Image.network(
      value,
      fit: BoxFit.cover,
      headers: const <String, String>{'User-Agent': kAidokuBrowserUserAgent},
      errorBuilder: (_, __, ___) => const ColoredBox(
        color: Color(0x11000000),
        child: Center(child: Icon(Icons.broken_image_outlined)),
      ),
    );
  }
}
