import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/manga_sources_page.dart'
    show MihonPreferencesDialog;
import 'package:fushi/src/media/manga/mihon/mihon_extensions_page.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime_factory.dart';
import 'package:fushi/src/media/manga/mihon/mihon_source_browse_page.dart';
import 'package:fushi/src/media/manga/mihon/mihon_web_login_page.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/utils.dart';

/// 视频「来源」视图里的在线源入口是否该出现：合规门（iOS 不带在线源宿主）+
/// 运行时平台门（Linux 没有 Mihon 宿主）。两个都过才有入口。
bool get isVideoOnlineSourcesAvailable =>
    StoreRestrictedCapability.onlineVideoSource.isAvailable &&
    MihonRuntimeFactory.isSupported;

/// 视频源扩展（Aniyomi）的管理页：仓库 / 扩展 / 已装源列表。
///
/// 与漫画 `MangaSourcesPage` 的 Mihon 两节同构，但独立成页而不是嵌进视频的
/// `MediaSourcesPage`：后者是 `SingleChildScrollView + Column`，而扩展列表是
/// sliver（按仓库分组懒建，1400+ 条不能一次全建），塞进 Column 要么改通用页的
/// 滚动容器、要么放弃懒建，都不值。视频「来源」视图放一张入口卡进来。
class VideoOnlineSourcesPage extends ConsumerStatefulWidget {
  const VideoOnlineSourcesPage({super.key, this.manager});

  /// 测试注入；生产从 `AppModel.animeMihonManager` 取。
  final MihonManager? manager;

  @override
  ConsumerState<VideoOnlineSourcesPage> createState() =>
      _VideoOnlineSourcesPageState();
}

class _VideoOnlineSourcesPageState
    extends ConsumerState<VideoOnlineSourcesPage> {
  MihonManager? _manager;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final MihonManager? manager =
        widget.manager ??
        (MihonRuntimeFactory.isSupported
            ? ref.read(appProvider).animeMihonManager
            : null);
    if (identical(manager, _manager)) return;
    _manager?.removeListener(_changed);
    _manager = manager?..addListener(_changed);
  }

  @override
  void dispose() {
    _manager?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _openSource(MangaOnlineSourceRow source) {
    final MihonManager manager = _manager!;
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => MihonSourceBrowsePage(
          manager: manager,
          target: MihonInstalledTarget(source),
        ),
      ),
    );
  }

  void _openPreferences(MangaOnlineSourceRow source) {
    showAppDialog<void>(
      context: context,
      builder: (BuildContext context) =>
          MihonPreferencesDialog(manager: _manager!, source: source),
    );
  }

  Future<void> _clearSourceData(MangaOnlineSourceRow source) async {
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog.adaptive(
        title: Text(t.mihon_source_clear_data),
        content: Text(t.mihon_source_clear_data_hint),
        actions: <Widget>[
          adaptiveDialogAction(
            context: dialogContext,
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(t.dialog_cancel),
          ),
          adaptiveDialogAction(
            context: dialogContext,
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(t.dialog_clear),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _manager!.clearSourceData(source);
    } on Object catch (error) {
      if (mounted) {
        FushiToast.show(msg: '$error', severity: ToastSeverity.error);
      }
    }
  }

  Uri? _loginTargetFor(MangaOnlineSourceRow source) =>
      mihonLoginTarget(runtime: _manager?.runtime, baseUrl: source.baseUrl);

  Future<void> _openWebLogin(MangaOnlineSourceRow source) async {
    final bool saved = await openMihonWebLogin(
      context,
      runtime: _manager?.runtime,
      sourceName: source.name,
      baseUrl: source.baseUrl,
    );
    if (!mounted || !saved) return;
    FushiToast.show(msg: t.mihon_source_login_saved);
    setState(() {});
  }

  Future<void> _moveSource(MangaOnlineSourceRow source, int delta) async {
    final MihonManager manager = _manager!;
    final List<MangaOnlineSourceRow> rows = List<MangaOnlineSourceRow>.of(
      manager.sources,
    );
    final int index = rows.indexWhere(
      (MangaOnlineSourceRow row) =>
          row.extensionPackage == source.extensionPackage &&
          row.sourceId == source.sourceId,
    );
    final int target = index + delta;
    if (index < 0 || target < 0 || target >= rows.length) return;
    final MangaOnlineSourceRow other = rows[target];
    await manager.updateSourceSettings(source, sortOrder: other.sortOrder);
    await manager.updateSourceSettings(other, sortOrder: source.sortOrder);
  }

  @override
  Widget build(BuildContext context) {
    final MihonManager? manager = _manager;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final TextStyle? sectionStyle = Theme.of(context).textTheme.titleLarge;
    return FushiPageScaffold(
      title: t.video_online_sources_title,
      body: manager == null
          ? Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                t.mihon_runtime_unavailable,
                textAlign: TextAlign.center,
              ),
            )
          : CustomScrollView(
              slivers: <Widget>[
                SliverPadding(
                  padding: EdgeInsets.symmetric(
                    horizontal: tokens.spacing.page,
                  ),
                  sliver: SliverMainAxisGroup(
                    slivers: <Widget>[
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 16),
                          child: Text(
                            t.video_online_sources_hint,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: Text(
                          t.video_extensions_title,
                          style: sectionStyle,
                        ),
                      ),
                      const SliverToBoxAdapter(child: SizedBox(height: 8)),
                      MihonExtensionsPage(manager: manager, embedded: true),
                      const SliverToBoxAdapter(child: SizedBox(height: 28)),
                      SliverToBoxAdapter(
                        child: Text(
                          t.video_online_sources_title,
                          style: sectionStyle,
                        ),
                      ),
                      const SliverToBoxAdapter(child: SizedBox(height: 8)),
                      if (manager.sources.isEmpty)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: Text(t.video_online_sources_empty),
                          ),
                        )
                      else
                        SliverList.builder(
                          itemCount: manager.sources.length,
                          itemBuilder: (BuildContext context, int index) =>
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: _buildSourceRow(
                                  manager,
                                  manager.sources[index],
                                  index,
                                ),
                              ),
                        ),
                      SliverToBoxAdapter(
                        child: SizedBox(
                          height: withBottomSafeInset(
                            context,
                            const EdgeInsets.only(bottom: 16),
                          ).bottom,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildSourceRow(
    MihonManager manager,
    MangaOnlineSourceRow source,
    int index,
  ) {
    return FushiCard(
      padding: EdgeInsets.zero,
      child: FushiListItem(
        key: ValueKey<String>(
          'video_online_source_${source.extensionPackage}_${source.sourceId}',
        ),
        leading: Switch.adaptive(
          value: source.enabled,
          onChanged: (bool value) =>
              unawaited(manager.updateSourceSettings(source, enabled: value)),
        ),
        title: Text(source.name),
        subtitle: Text(
          '${source.language.toUpperCase()} · ${source.extensionPackage}',
        ),
        onTap: source.enabled ? () => _openSource(source) : null,
        trailing: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            IconButton(
              tooltip: t.sort_by,
              onPressed: index == 0
                  ? null
                  : () => unawaited(_moveSource(source, -1)),
              icon: const Icon(Icons.keyboard_arrow_up),
            ),
            IconButton(
              tooltip: t.sort_by,
              onPressed: index == manager.sources.length - 1
                  ? null
                  : () => unawaited(_moveSource(source, 1)),
              icon: const Icon(Icons.keyboard_arrow_down),
            ),
            if (_loginTargetFor(source) != null)
              IconButton(
                tooltip: t.mihon_source_login,
                onPressed: () => unawaited(_openWebLogin(source)),
                icon: const Icon(Icons.login),
              ),
            IconButton(
              tooltip: t.mihon_source_preferences,
              onPressed: () => _openPreferences(source),
              icon: const Icon(Icons.tune),
            ),
            IconButton(
              tooltip: t.mihon_source_clear_data,
              onPressed: () => unawaited(_clearSourceData(source)),
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
            IconButton(
              tooltip: t.sort_by,
              onPressed: () => unawaited(
                manager.updateSourceSettings(source, pinned: !source.pinned),
              ),
              icon: Icon(
                source.pinned ? Icons.push_pin : Icons.push_pin_outlined,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
