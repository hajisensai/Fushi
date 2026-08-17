import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_package_store.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_runtime.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_source_browse_page.dart';
import 'package:fushi/src/media/manga/discovery/manga_discovery_models.dart';
import 'package:fushi/src/media/manga/discovery/manga_discovery_page.dart';
import 'package:fushi/src/media/manga/discovery/manga_source_matcher.dart';
import 'package:fushi/src/media/manga/manga_global_search_page.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime_factory.dart';
import 'package:fushi/src/media/manga/mihon/mihon_source_browse_page.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/utils.dart';

/// 发现条目详情页：AniList 元数据 + **全自动来源匹配**（用户决策 B）。
///
/// 打开即在全部已启用来源（Mihon 在线源 + Aidoku 包）里按标题模糊匹配，命中
/// 列表按分数排序展示；点一条直接进对应来源的漫画详情页（章节可读）。没有任何
/// 命中时给「搜索全部来源」兜底入口（预填首选标题的全局搜索页）。
///
/// 平台差异只体现在有哪些来源上：无扩展宿主的平台匹配区自然是空表 + 兜底入口。
class MangaDiscoveryDetailPage extends ConsumerStatefulWidget {
  const MangaDiscoveryDetailPage({
    required this.entry,
    super.key,
    this.matchSourcesOverride,
  });

  final MangaDiscoveryEntry entry;

  /// 测试注入：给定时跳过平台来源发现，直接用这些来源做匹配。
  final List<MangaMatchSource>? matchSourcesOverride;

  @override
  ConsumerState<MangaDiscoveryDetailPage> createState() =>
      _MangaDiscoveryDetailPageState();
}

/// Mihon 命中的回带载荷：打开详情页所需的最小上下文。
class _MihonMatchPayload {
  const _MihonMatchPayload(this.sourceContext, this.manga);

  final MihonSourceContext sourceContext;
  final MihonManga manga;
}

/// Aidoku 命中的回带载荷。
class _AidokuMatchPayload {
  const _AidokuMatchPayload(this.package, this.manga);

  final AidokuInstalledPackage package;
  final Map<String, Object?> manga;
}

class _MangaDiscoveryDetailPageState
    extends ConsumerState<MangaDiscoveryDetailPage> {
  List<MangaSourceMatch>? _matches;
  bool _matching = false;
  bool _started = false;

  MihonManager? _mihonManager;
  List<MangaOnlineSourceRow> _mihonSources = const <MangaOnlineSourceRow>[];
  List<AidokuInstalledPackage> _aidokuPackages =
      const <AidokuInstalledPackage>[];
  AidokuRuntime? _aidokuRuntime;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    unawaited(_startMatching());
  }

  /// 收集当前平台上「已启用」的两类来源，与 `MangaBrowsePage` 同一口径：
  /// Mihon 要求扩展与在线源都启用；Aidoku 要求包启用。
  Future<List<MangaMatchSource>> _collectSources() async {
    final List<MangaMatchSource>? override = widget.matchSourcesOverride;
    if (override != null) return override;
    final List<MangaMatchSource> sources = <MangaMatchSource>[];
    if (AidokuRuntimeFactory.isSupported) {
      try {
        final List<AidokuInstalledPackage> packages =
            await (await AidokuPackageStore.open()).listInstalled();
        _aidokuPackages = packages
            .where((AidokuInstalledPackage package) => package.enabled)
            .toList(growable: false);
        final AidokuRuntime runtime =
            _aidokuRuntime ??= AidokuRuntimeFactory.create();
        for (final AidokuInstalledPackage package in _aidokuPackages) {
          sources.add(
            MangaMatchSource(
              id: 'aidoku:${package.id}',
              name: package.name,
              language:
                  package.languages.isEmpty ? '' : package.languages.first,
              search: (String query) => _searchAidoku(runtime, package, query),
            ),
          );
        }
      } on Object {
        // Aidoku 存储打不开只影响 Aidoku 侧来源，不拦 Mihon 匹配。
      }
    }
    if (MihonRuntimeFactory.isSupported) {
      final MihonManager manager = ref.read(appProvider).mihonManager;
      _mihonManager = manager;
      final Set<String> enabledExtensions = manager.installed
          .where((MangaExtensionRow row) => row.enabled)
          .map((MangaExtensionRow row) => row.packageName)
          .toSet();
      _mihonSources = manager.sources
          .where(
            (MangaOnlineSourceRow row) =>
                row.enabled && enabledExtensions.contains(row.extensionPackage),
          )
          .toList(growable: false);
      for (final MangaOnlineSourceRow row in _mihonSources) {
        sources.add(
          MangaMatchSource(
            id: 'mihon:${row.extensionPackage}:${row.sourceId}',
            name: row.name,
            language: row.language,
            search: (String query) => _searchMihon(manager, row, query),
          ),
        );
      }
    }
    return sources;
  }

  Future<List<MangaMatchHit>> _searchMihon(
    MihonManager manager,
    MangaOnlineSourceRow row,
    String query,
  ) async {
    final MihonSourceContext sourceContext =
        await manager.contextForSource(row);
    final MihonMangaPage page = await manager.runtime.search(
      sourceContext.extension,
      sourceContext.source,
      page: 1,
      query: query,
      preferences: sourceContext.preferences,
    );
    return <MangaMatchHit>[
      for (final MihonManga manga in page.items)
        MangaMatchHit(
          title: manga.title,
          payload: _MihonMatchPayload(sourceContext, manga),
        ),
    ];
  }

  Future<List<MangaMatchHit>> _searchAidoku(
    AidokuRuntime runtime,
    AidokuInstalledPackage package,
    String query,
  ) async {
    final Map<String, Object?> result = await runtime.search(
      package.packagePath,
      query: query,
      page: 1,
    );
    final List<MangaMatchHit> hits = <MangaMatchHit>[];
    for (final Object? node
        in result['entries'] as List<Object?>? ?? const <Object?>[]) {
      if (node is! Map<Object?, Object?>) continue;
      final Map<String, Object?> manga = node.cast<String, Object?>();
      if (manga['key']?.toString().isEmpty ?? true) continue;
      hits.add(
        MangaMatchHit(
          title: manga['title']?.toString() ?? manga['key'].toString(),
          payload: _AidokuMatchPayload(package, manga),
        ),
      );
    }
    return hits;
  }

  Future<void> _startMatching() async {
    setState(() {
      _matching = true;
      _matches = null;
    });
    final List<MangaSourceMatch> matches = await matchMangaAcrossSources(
      entry: widget.entry,
      sources: await _collectSources(),
    );
    if (!mounted) return;
    setState(() {
      _matches = matches;
      _matching = false;
    });
  }

  void _openMatch(MangaSourceMatch match) {
    switch (match.hit.payload) {
      case final _MihonMatchPayload payload:
        final MihonManager? manager = _mihonManager;
        if (manager == null) return;
        Navigator.of(context).push(
          adaptivePageRoute<void>(
            context: context,
            builder: (BuildContext context) => MihonMangaDetailPage(
              manager: manager,
              sourceContext: payload.sourceContext,
              manga: payload.manga,
            ),
          ),
        );
      case final _AidokuMatchPayload payload:
        final AidokuRuntime? runtime = _aidokuRuntime;
        if (runtime == null) return;
        Navigator.of(context).push(
          adaptivePageRoute<void>(
            context: context,
            builder: (BuildContext context) => AidokuMangaDetailPage(
              package: payload.package,
              runtime: runtime,
              manga: payload.manga,
              sourceBaseUrl: null,
            ),
          ),
        );
    }
  }

  void _openGlobalSearch() {
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => MangaGlobalSearchPage(
          mihonManager: _mihonManager,
          mihonSources: _mihonSources,
          aidokuPackages: _aidokuPackages,
          initialQuery: widget.entry.preferredTitle,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final MangaDiscoveryEntry entry = widget.entry;
    return FushiPageScaffold(
      title: entry.preferredTitle,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _buildHero(entry),
          const SizedBox(height: 16),
          _buildMatchesSection(),
          if (entry.description?.isNotEmpty ?? false) ...<Widget>[
            const SizedBox(height: 16),
            Text(
              entry.description!,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHero(MangaDiscoveryEntry entry) {
    final ThemeData theme = Theme.of(context);
    final List<String> subtitles = <String>[
      for (final String? title in <String?>[
        entry.titleRomaji,
        entry.titleEnglish,
      ])
        if (title != null && title.isNotEmpty && title != entry.preferredTitle)
          title,
    ];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 130,
          height: 185,
          child: ClipRRect(
            borderRadius: FushiDesignTokens.of(context).radii.cardRadius,
            child: MangaDiscoveryCover(url: entry.coverUrl),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(entry.preferredTitle, style: theme.textTheme.titleLarge),
              for (final String subtitle in subtitles)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  if (entry.averageScore != null)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(
                          Icons.star_rate_rounded,
                          size: 16,
                          color: theme.colorScheme.primary,
                        ),
                        Text(
                          entry.averageScore!.toStringAsFixed(1),
                          style: theme.textTheme.labelMedium,
                        ),
                      ],
                    ),
                  if (_statusLabel(entry.status) != null)
                    Text(
                      _statusLabel(entry.status)!,
                      style: theme.textTheme.labelMedium,
                    ),
                ],
              ),
              if (entry.genres.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    for (final String genre in entry.genres)
                      FushiTagChip(label: genre),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  String? _statusLabel(String? status) => switch (status) {
        'RELEASING' => t.manga_discovery_status_releasing,
        'FINISHED' => t.manga_discovery_status_finished,
        'HIATUS' => t.manga_discovery_status_hiatus,
        'CANCELLED' => t.manga_discovery_status_cancelled,
        'NOT_YET_RELEASED' => t.manga_discovery_status_not_yet_released,
        _ => null,
      };

  Widget _buildMatchesSection() {
    final ThemeData theme = Theme.of(context);
    final List<MangaSourceMatch>? matches = _matches;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                t.manga_discovery_match_section,
                style: theme.textTheme.titleMedium,
              ),
            ),
            TextButton.icon(
              key: const ValueKey<String>('manga_discovery_global_search'),
              onPressed: _matching ? null : _openGlobalSearch,
              icon: const Icon(Icons.travel_explore, size: 18),
              label: Text(t.manga_global_search_title),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (_matching)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: <Widget>[
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Text(t.manga_discovery_match_running),
              ],
            ),
          )
        else if (matches == null || matches.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              t.manga_discovery_match_none,
              style: TextStyle(color: theme.colorScheme.outline),
            ),
          )
        else
          for (final MangaSourceMatch match in matches)
            FushiCard(
              padding: EdgeInsets.zero,
              child: FushiListItem(
                leading: CircleAvatar(
                  child: Text(
                    match.source.language.isEmpty
                        ? '?'
                        : match.source.language.toUpperCase(),
                    style: theme.textTheme.labelSmall,
                  ),
                ),
                title: Text(match.hit.title),
                subtitle: Text(
                  '${match.source.name} · '
                  '${(match.score * 100).round()}%',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openMatch(match),
              ),
            ),
      ],
    );
  }
}
