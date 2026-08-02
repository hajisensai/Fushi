import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_manager.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_runtime_factory.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_source_browse_page.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_catalog_view.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_source_row.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/utils.dart';

/// 漫画库「浏览」视图：可浏览内容的**在线来源清单**。
///
/// 内置的 mokuro.moe 目录在第一行；已启用的 Mihon 在线来源与它**并列**排在
/// 后面（用户口径：扩展来的在线源不另开 tab，与 mokuro.moe 同处「浏览」）。
///
/// mokuro.moe 与扩展源遵守**同一条**可见性规则（BUG-1431）：在「来源」视图里被
/// 关掉的源不出现在这里。此前 mokuro.moe 那个开关只让它的目录页显示成禁用态，
/// 行却照旧列着——同一节里两种开关语义，用户没法解释。
///
/// 平台差异只体现在**内容**上，不体现在结构上：iOS / Linux 没有扩展宿主
/// （[MihonRuntimeFactory.isSupported] 为 false），这一页仍然存在、仍然在同一个
/// tab 位置，只是列表里只有 mokuro.moe 一行。注意 `AppModel.mihonManager` 在
/// 不支持的平台上会抛 [UnsupportedError]，所以任何读它的路径都必须先过
/// [MihonRuntimeFactory.isSupported] 这道门。
class MangaBrowsePage extends ConsumerStatefulWidget {
  const MangaBrowsePage({
    super.key,
    this.navigation,
  });

  /// 库页视图导航条（由 `MediaLibraryShell` 传入，作为页头主内容）。
  final Widget? navigation;

  @override
  ConsumerState<MangaBrowsePage> createState() => _MangaBrowsePageState();
}

class _MangaBrowsePageState extends ConsumerState<MangaBrowsePage> {
  MihonManager? _manager;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!MihonRuntimeFactory.isSupported) return;
    final MihonManager manager = ref.read(appProvider).mihonManager;
    if (identical(manager, _manager)) return;
    _manager?.removeListener(_changed);
    _manager = manager..addListener(_changed);
  }

  @override
  void dispose() {
    _manager?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _openMokuro() {
    final AppModel appModel = ref.read(appProvider);
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => HibikiPageScaffold(
          title: t.mihon_source_browse_mokuro,
          body: MokuroMoeCatalogView(
            db: appModel.database,
            embedded: true,
          ),
        ),
      ),
    );
  }

  void _openSource(MangaOnlineSourceRow source) {
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => MihonSourceBrowsePage(
          manager: _manager!,
          source: source,
        ),
      ),
    );
  }

  /// 已启用扩展提供的、且用户没有停用的在线来源。不支持扩展的平台恒为空表。
  List<MangaOnlineSourceRow> _enabledSources() {
    final MihonManager? manager = _manager;
    if (manager == null) return const <MangaOnlineSourceRow>[];
    final Set<String> enabledExtensions = manager.installed
        .where((MangaExtensionRow row) => row.enabled)
        .map((MangaExtensionRow row) => row.packageName)
        .toSet();
    return manager.sources
        .where(
          (MangaOnlineSourceRow row) =>
              row.enabled && enabledExtensions.contains(row.extensionPackage),
        )
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final List<MangaOnlineSourceRow> sources = _enabledSources();
    // watch（不是 read）：偏好改动经 PreferencesRepository -> AppModel 转发过来，
    // 本页在库页壳里是 Offstage 保活的，不 watch 就永远停在旧值上。
    final bool mokuroEnabled = isMokuroMoeSourceEnabled(ref.watch(appProvider));
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          if (!isCupertinoPlatform(context))
            HibikiPageHeader(
              title: t.library_view_browse,
              bottom: widget.navigation,
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                if (mokuroEnabled)
                  HibikiCard(
                    padding: EdgeInsets.zero,
                    child: HibikiListItem(
                      leading: const Icon(Icons.auto_stories_outlined),
                      title: Text(t.mihon_source_browse_mokuro),
                      subtitle: const Text('mokuro.moe'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _openMokuro,
                    ),
                  ),
                for (final MangaOnlineSourceRow source in sources)
                  HibikiCard(
                    padding: EdgeInsets.zero,
                    child: HibikiListItem(
                      leading: CircleAvatar(
                        child: Text(
                          source.language.isEmpty
                              ? '?'
                              : source.language.toUpperCase(),
                        ),
                      ),
                      title: Text(source.name),
                      subtitle: Text(
                        source.baseUrl.isEmpty
                            ? source.extensionPackage
                            : source.baseUrl,
                      ),
                      trailing: source.pinned
                          ? const Icon(Icons.push_pin_outlined)
                          : const Icon(Icons.chevron_right),
                      onTap: () => _openSource(source),
                    ),
                  ),
                if (MihonRuntimeFactory.isSupported && sources.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 32,
                    ),
                    child: Text(
                      t.mihon_source_empty,
                      textAlign: TextAlign.center,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
