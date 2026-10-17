import 'dart:async';
import 'package:fushi/src/media/manga/mihon/mihon_cloudflare_action.dart';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';

import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/manga_global_search_runner.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_source_browse_page.dart';
import 'package:fushi/src/media/online/online_source_error_text.dart';
import 'package:fushi/utils.dart';

/// 一次跨**所有已启用来源**搜索同一个书名的页面（Mihon 在线源）。
///
/// 每个来源独立成一段：各自并发发起搜索、各自更新状态，一个源慢或失败都不拖累其余。
/// 被 Cloudflare 拦下的源会被标成「受 Cloudflare 保护」而不是崩掉整页。
///
/// 平台差异只体现在**有哪些源**上：Mihon 仅桌面/安卓有宿主。调用方
/// （`MangaDiscoveryPage`）负责把当前平台上「已启用」的源传进来，本页不自己发现，
/// 方便测试注入。
class MangaGlobalSearchPage extends StatefulWidget {
  const MangaGlobalSearchPage({
    required this.mihonManager,
    required this.mihonSources,
    super.key,
    this.initialQuery,
    this.onOpenSources,
  });

  /// Mihon 宿主。不支持的平台传 `null`（此时 [mihonSources] 必为空）。
  final MihonManager? mihonManager;

  /// 一个源都没有时空态按钮的去处：把用户带到「浏览 › 来源 › 漫画」（2026-09-27
  /// 起来源都在那里装 / 启用）。**弹掉本页这一步由宿主自己做**（浏览页 /
  /// 库页壳各自以自己的路由为界 popUntil），本页不碰导航栈——本页上面可能还压着
  /// 别的路由，也可能是别人推的第二个入口。为 null 时只显示文案不显示按钮：
  /// 调用方没有可去的「来源」。
  final VoidCallback? onOpenSources;

  /// 已启用、且扩展也启用的 Mihon 在线源。
  final List<MangaOnlineSourceRow> mihonSources;

  final String? initialQuery;

  @override
  State<MangaGlobalSearchPage> createState() => _MangaGlobalSearchPageState();
}

class _MangaGlobalSearchPageState extends State<MangaGlobalSearchPage> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final MihonSourceImageLoadQueue _imageQueue = MihonSourceImageLoadQueue(
    maxConcurrent: 4,
  );

  List<MangaSourceSearchRun> _runs = const <MangaSourceSearchRun>[];
  int _generation = 0;
  bool _searched = false;

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
    _searchFocus.dispose();
    super.dispose();
  }

  List<MangaGlobalSource> _sources() => <MangaGlobalSource>[
    for (final MangaOnlineSourceRow row in widget.mihonSources)
      MihonGlobalSource(row),
  ];

  Future<void> _search() async {
    final String query = _searchController.text.trim();
    if (query.isEmpty) return;
    final int generation = ++_generation;
    final List<MangaSourceSearchRun> runs = _sources()
        .map(MangaSourceSearchRun.new)
        .toList(growable: false);
    setState(() {
      _searched = true;
      _runs = runs;
    });
    // 逐源扇出/限流/CF 分型在 runner（与统一发现框架共用有界并发原语）。
    await MangaGlobalSearchRunner(mihonManager: widget.mihonManager).search(
      runs: runs,
      query: query,
      isCancelled: () => !mounted || generation != _generation,
      onRunUpdated: () {
        if (mounted && generation == _generation) setState(() {});
      },
    );
  }

  Future<void> _retrySource(MangaSourceSearchRun run) async {
    final int generation = _generation;
    if (!mounted || !_runs.contains(run)) return;
    setState(() {
      run.status = MangaSearchRunStatus.loading;
      run.error = null;
    });
    await MangaGlobalSearchRunner(mihonManager: widget.mihonManager).search(
      runs: <MangaSourceSearchRun>[run],
      query: _searchController.text.trim(),
      isCancelled: () => !mounted || generation != _generation,
      onRunUpdated: () {
        if (mounted && generation == _generation) setState(() {});
      },
    );
  }

  Widget _sourceError(MangaSourceSearchRun run, String message) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      _SectionMessage(message),
      if (run.source is MihonGlobalSource)
        MihonCloudflareAction(
          runtime: widget.mihonManager?.runtime,
          error: run.error,
          onVerified: () => _retrySource(run),
        ),
    ],
  );

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

  @override
  Widget build(BuildContext context) {
    return FushiPageScaffold(
      title: t.manga_global_search_title,
      headerBottom: Padding(
        padding: const EdgeInsets.only(top: 8),
        // 2026-10 体验优化：统一为 FushiSearchField；仍是「提交才搜」（全源扇出
        // 代价高，不做边打边搜），onChanged 空转。
        child: FushiSearchField(
          fieldKey: const ValueKey<String>('manga_global_search_field'),
          focusId: const FushiFocusId('manga-global-search'),
          controller: _searchController,
          focusNode: _searchFocus,
          hintText: t.manga_global_search_hint,
          onChanged: (String _) {},
          onSubmitted: (String _) => unawaited(_search()),
          onClear: _searchController.clear,
        ),
      ),
      // 页头浮在正文上（extendBodyBehindHeader 默认开）：正文用 body 子树里的
      // context 构建，才读得到脚手架下发的顶部让位。
      body: Builder(builder: _buildBody),
    );
  }

  Widget _buildBody(BuildContext context) {
    // 2026-10 体验优化：无源 / 未搜索两种占位统一 FushiPlaceholderMessage。
    if (_sources().isEmpty) {
      final VoidCallback? onOpenSources = widget.onOpenSources;
      final Widget placeholder = FushiPlaceholderMessage(
        icon: Icons.travel_explore_outlined,
        message: t.manga_global_search_no_sources,
        action: onOpenSources == null
            ? null
            : FushiFilledButton.tonalIcon(
                key: const ValueKey<String>(
                  'manga_global_search_open_sources',
                ),
                onPressed: onOpenSources,
                // 「导入」的图标（与书架空态引导同一个）。拼图块 extension_outlined
                // 恰恰是本 bug 的病根：漫画库里没有叫「扩展」的入口。
                icon: const FushiIcon(Icons.library_add_outlined),
                label: Text(t.manga_global_search_open_sources),
              ),
      );
      return SafeArea(bottom: false, child: placeholder);
    }
    if (!_searched) {
      return SafeArea(
        bottom: false,
        child: FushiPlaceholderMessage(
          icon: Icons.search,
          message: t.manga_global_search_prompt,
        ),
      );
    }
    return ListView.builder(
      // BUG-2440：scaffold 的 body 不再扣底部安全区，最后一个源的结果块得靠这里
      // 补出手势条那一段，否则静止时被压住。
      padding: withBottomSafeInset(
        context,
        EdgeInsets.only(top: 8 + MediaQuery.paddingOf(context).top, bottom: 8),
      ),
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
      child: FushiCircularProgressIndicator(strokeWidth: 2),
    ),
    _ => const SizedBox.shrink(),
  };

  Widget _buildSectionBody(MangaSourceSearchRun run) {
    switch (run.status) {
      case MangaSearchRunStatus.loading:
        // 2026-10 体验优化：原先是 200dp 的纯空白，看着像「这个源什么都没有」。
        return SizedBox(
          height: 200,
          child: Center(child: adaptiveIndicator(context: context)),
        );
      case MangaSearchRunStatus.cloudflare:
        return _sourceError(run, t.manga_source_cloudflare_blocked);
      case MangaSearchRunStatus.error:
        final Object? error = run.error;
        return _sourceError(
          run,
          error == null
              ? t.online_source_error_generic
              : describeOnlineSourceError(error),
        );
      case MangaSearchRunStatus.empty:
        return _SectionMessage(t.mihon_source_no_results);
      case MangaSearchRunStatus.done:
        return _buildResultsStrip(run);
    }
  }

  Widget _buildResultsStrip(MangaSourceSearchRun run) {
    final int count = switch (run.source) {
      MihonGlobalSource() => run.mihonItems.length,
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

  /// 2026-10 体验优化：原 28dp 圆章装不下 `zh-hans` / `pt-br` 这类码，字被
  /// 挤出圆外；改成随文字伸缩的药丸，单行不换。
  @override
  Widget build(BuildContext context) {
    // 中性灰底：语言码只是元信息，不该抢主色（Apple 设计系统下更是禁止彩色
    // 底块），所以不用 secondaryContainer 的 tonal 色块。
    return FushiTag(
      text: language.toUpperCase(),
      tone: FushiTagTone.neutral,
      dense: true,
    );
  }
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
