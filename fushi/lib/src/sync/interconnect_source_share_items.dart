/// host 侧「选择要共享的来源」：逐项勾选哪些服务器来源 / 插件发给「我的设备」
/// （拍板台 wOMR4_Er7s 原文「凭据由用户逐项勾选，不能默认全量下发」）。默认一条都不勾。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/sync/interconnect_source_share_sync.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi_engine/sync/interconnect_source_share.dart';
import 'package:material_ui/material_ui.dart';

/// 一种来源给人看的名字（OPDS / AList / Kavita / OpenSubsonic 是专名，不翻译）。
String sourceShareKindLabel(String kind) => switch (kind) {
  'opds' => 'OPDS',
  'alist' => 'AList',
  'kavita' => 'Kavita',
  'subsonic' => 'OpenSubsonic',
  'mediaServer' => t.sync_interconnect_source_share_kind_media_server,
  'musicPlugin' => t.sync_interconnect_source_share_kind_music_plugin,
  'trackingPlugin' => t.sync_interconnect_source_share_kind_tracking_plugin,
  _ => kind,
};

/// 本机可共享来源的逐项开关列表。
class InterconnectSourceShareItemsList extends StatefulWidget {
  const InterconnectSourceShareItemsList({required this.appModel, super.key});

  final AppModel appModel;

  @override
  State<InterconnectSourceShareItemsList> createState() =>
      _InterconnectSourceShareItemsListState();
}

class _InterconnectSourceShareItemsListState
    extends State<InterconnectSourceShareItemsList> {
  List<InterconnectSharedSource>? _sources;
  Set<String> _selected = <String>{};

  SyncRepository get _repo => SyncRepository(widget.appModel.database);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final AppInterconnectSourceShareHost host = AppInterconnectSourceShareHost(
      db: widget.appModel.database,
      enabled: () async => true,
      isOwnerDevicePeer: (String _) async => false,
      pluginStores: widget.appModel.sourceSharePluginStoresOf,
    );
    final InterconnectSourceShareCatalog all = await host.shareableSources();
    final Set<String> selected = await _repo
        .getInterconnectSourceShareHostItems();
    if (!mounted) return;
    setState(() {
      _sources = all.sources;
      _selected = selected;
    });
  }

  Future<void> _toggle(String key, bool shared) async {
    setState(() {
      if (shared) {
        _selected = <String>{..._selected, key};
      } else {
        _selected = <String>{..._selected}..remove(key);
      }
    });
    await _repo.setInterconnectSourceShareHostItem(key, shared: shared);
  }

  @override
  Widget build(BuildContext context) {
    final List<InterconnectSharedSource>? sources = _sources;
    if (sources == null) return const SizedBox.shrink();
    if (sources.isEmpty) {
      return AdaptiveSettingsRow(
        title: t.sync_interconnect_source_share_items_empty,
      );
    }
    return FushiEntranceScope(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final (int i, InterconnectSharedSource s) in sources.indexed)
            FushiStaggeredEntrance(
              key: ValueKey<String>(s.key),
              index: i,
              child: AdaptiveSettingsSwitchRow(
                title: s.label,
                subtitle: s.unavailable
                    ? '${sourceShareKindLabel(s.kind)} · '
                          '${t.sync_interconnect_source_share_item_unavailable}'
                    : sourceShareKindLabel(s.kind),
                value: _selected.contains(s.key),
                onChanged: (bool v) => _toggle(s.key, v),
              ),
            ),
        ],
      ),
    );
  }
}
