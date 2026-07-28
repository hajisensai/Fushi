import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_manager.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_source_browse_page.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_catalog_view.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/utils.dart';

class MihonSourcesPage extends ConsumerStatefulWidget {
  const MihonSourcesPage({
    super.key,
    this.navigation,
  });

  final Widget? navigation;

  @override
  ConsumerState<MihonSourcesPage> createState() => _MihonSourcesPageState();
}

class _MihonSourcesPageState extends ConsumerState<MihonSourcesPage> {
  MihonManager? _manager;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
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

  @override
  Widget build(BuildContext context) {
    final MihonManager manager = _manager ?? ref.read(appProvider).mihonManager;
    final Set<String> enabledExtensions = manager.installed
        .where((MangaExtensionRow row) => row.enabled)
        .map((MangaExtensionRow row) => row.packageName)
        .toSet();
    final List<MangaOnlineSourceRow> sources = manager.sources
        .where(
          (MangaOnlineSourceRow row) =>
              row.enabled && enabledExtensions.contains(row.extensionPackage),
        )
        .toList(growable: false);
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          if (!isCupertinoPlatform(context))
            HibikiPageHeader(
              title: t.mihon_sources_title,
              bottom: widget.navigation,
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.auto_stories_outlined),
                    title: Text(t.mihon_source_browse_mokuro),
                    subtitle: const Text('mokuro.moe'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _openMokuro,
                  ),
                ),
                if (sources.isEmpty)
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
                for (final MangaOnlineSourceRow source in sources)
                  Card(
                    child: ListTile(
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
              ],
            ),
          ),
        ],
      ),
    );
  }
}
