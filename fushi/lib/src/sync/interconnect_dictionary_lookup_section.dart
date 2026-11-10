import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

// 「配对与设备」里每台已配对 host 的「用这台服务器查词典」行（设计稿 3）：开关 +
// 「可用词典：托管 N 本 · 上次刷新 …」+ 刷新。开关是按 host 的设备本地设置
// （[FushiClientUrl.lookupEnabled]），同一台 host 的全部地址一起改；只影响远端查词
// 与服务器词典目录，同步 / 配置传输等互联用途不受影响。

/// 把 [hostId]（[remoteDictionaryHostIdOf] 口径）这台 host 的**全部地址**的
/// 「用它查词典」改成 [enabled]，其余地址原样（经 `copyWith`，指纹 / 令牌 / 学习标记
/// 都保留）。没有变化时原样返回 [urls]。
List<FushiClientUrl> withInterconnectHostLookupEnabled(
  List<FushiClientUrl> urls,
  String hostId,
  bool enabled,
) {
  if (!urls.any(
    (FushiClientUrl u) =>
        remoteDictionaryHostIdOf(u) == hostId && u.lookupEnabled != enabled,
  )) {
    return urls;
  }
  return <FushiClientUrl>[
    for (final FushiClientUrl u in urls)
      remoteDictionaryHostIdOf(u) == hostId
          ? u.copyWith(lookupEnabled: enabled)
          : u,
  ];
}

/// 「用这台服务器查词典」的唯一写入口（配对设置页与词典管理页的来源卡片共用）。
/// 这是远端词典查词**唯一**的开关：用户拍板（2026-11-09）删掉了重复的全局「远程
/// 查词」，总闸改成派生值（至少一台 host 开着即为开，见 `AppModel.remoteLookupEnabled`）。
///
/// [mutateUrls] 是调用方串行写配对列表的通道（设置页要同步自己的列表状态）。
Future<void> applyInterconnectHostLookupIntent({
  required String hostId,
  required bool enabled,
  required Future<void> Function(
    List<FushiClientUrl> Function(List<FushiClientUrl> current) transform,
  )
  mutateUrls,
}) => mutateUrls(
  (List<FushiClientUrl> current) =>
      withInterconnectHostLookupEnabled(current, hostId, enabled),
);

/// 设置页「查词 › 词典服务器」那行的副标题：在用的服务器（一台写名字、多台写台数）；
/// 一台都没在用时，有配对就只说没在用，没配对就提示去配对一台 Fushi 服务器。
/// 「在用」与查词闸门同一口径（[remoteDictionaryLookupHostIdsOf]），名字与配对页
/// 「已添加的设备」同一口径（[interconnectPeerRowLabels]）。
String remoteDictionaryServersSummary(List<FushiClientUrl> urls) {
  final List<FushiClientUrl> hosts = interconnectPeerRepresentatives(urls);
  final Set<String> inUse = remoteDictionaryLookupHostIdsOf(urls);
  final List<String> names = <String>[
    for (final FushiClientUrl host in hosts)
      if (inUse.contains(remoteDictionaryHostIdOf(host)))
        interconnectPeerRowLabels(host).title,
  ];
  if (names.length == 1) {
    return t.lookup_dictionary_servers_one_in_use(name: names.single);
  }
  if (names.length > 1) {
    return t.lookup_dictionary_servers_many_in_use(n: names.length);
  }
  return hosts.isEmpty
      ? t.lookup_dictionary_servers_none_paired
      : t.lookup_dictionary_servers_none_in_use;
}

/// 「已添加的设备」一行的标题与地址行：配对记下了设备名时标题是设备名、地址退到
/// 副标题（[url] 非 null）；不知道设备名时标题就是地址、不再重复一行（[url] 为 null）。
({String title, String? url}) interconnectPeerRowLabels(FushiClientUrl peer) {
  final String device = peer.deviceName?.trim() ?? '';
  return device.isEmpty
      ? (title: peer.url, url: null)
      : (title: device, url: peer.url);
}

/// [hostId] 这台 host 此刻是否参与查词：任一地址开着即算开（设置页总是整组写，
/// 混合态只来自升级前的手改数据，宁可显示为开、让用户能一键关掉）。
bool interconnectHostLookupEnabled(List<FushiClientUrl> urls, String hostId) =>
    urls.any(
      (FushiClientUrl u) =>
          remoteDictionaryHostIdOf(u) == hostId && u.lookupEnabled,
    );

/// 一台 host 的服务器词典目录摘要。
@immutable
class InterconnectHostDictionarySummary {
  const InterconnectHostDictionarySummary({
    required this.hosted,
    required this.lastRefreshedAt,
  });

  /// 上次刷新时 host 上还在的词典本数（已缺席的不算）。
  final int hosted;

  /// 上次成功刷新的时刻（目录行 `lastSeenAt` 的最大值，毫秒）；null = 没有目录行。
  final int? lastRefreshedAt;
}

/// 目录行 → 每台 host 的摘要。包含「用它查词典」关掉的 host（行留在库里）。
Map<String, InterconnectHostDictionarySummary>
interconnectHostDictionarySummariesOf(Iterable<RemoteDictionaryMetaRow> rows) {
  final Map<String, int> hosted = <String, int>{};
  final Map<String, int> lastSeen = <String, int>{};
  for (final RemoteDictionaryMetaRow r in rows) {
    hosted[r.hostId] =
        (hosted[r.hostId] ?? 0) + (r.missingSince == null ? 1 : 0);
    final int? seen = lastSeen[r.hostId];
    if (seen == null || r.lastSeenAt > seen) lastSeen[r.hostId] = r.lastSeenAt;
  }
  return <String, InterconnectHostDictionarySummary>{
    for (final String host in hosted.keys)
      host: InterconnectHostDictionarySummary(
        hosted: hosted[host]!,
        lastRefreshedAt: lastSeen[host],
      ),
  };
}

/// 读库算出全部 host 的摘要。
Future<Map<String, InterconnectHostDictionarySummary>>
loadInterconnectHostDictionarySummaries(FushiDatabase db) async =>
    interconnectHostDictionarySummariesOf(
      await db.getAllRemoteDictionaryMetadata(),
    );

/// 每台已配对 host 一组：「用这台服务器查词典」开关 + 可用词典 / 上次刷新 + 刷新。
class InterconnectDictionaryLookupSection extends StatelessWidget {
  const InterconnectDictionaryLookupSection({
    required this.urls,
    required this.summaries,
    required this.refreshingHosts,
    required this.onLookupChanged,
    required this.onRefresh,
    super.key,
  });

  /// 配对列表（全部地址）。按 host 归组后每台一组。
  final List<FushiClientUrl> urls;
  final Map<String, InterconnectHostDictionarySummary> summaries;

  /// 正在刷新目录的 host（刷新钮置灰）。
  final Set<String> refreshingHosts;
  final void Function(String hostId, bool enabled) onLookupChanged;

  /// 刷新某台 host 的目录；null = 没有目录服务（刷新钮不给）。
  final void Function(String hostId)? onRefresh;

  @override
  Widget build(BuildContext context) {
    final double gap = FushiDesignTokens.of(context).spacing.gap;
    final List<FushiClientUrl> hosts = interconnectPeerRepresentatives(urls);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final FushiClientUrl host in hosts)
          Padding(
            padding: EdgeInsets.only(bottom: gap),
            child: _buildHost(context, host),
          ),
      ],
    );
  }

  Widget _buildHost(BuildContext context, FushiClientUrl host) {
    final String hostId = remoteDictionaryHostIdOf(host);
    final String name = (host.deviceName?.trim().isNotEmpty ?? false)
        ? host.deviceName!.trim()
        : host.url;
    final InterconnectHostDictionarySummary? summary = summaries[hostId];
    final int? refreshed = summary?.lastRefreshedAt;
    final String refreshedLabel = refreshed == null
        ? t.dict_auto_update_never
        : DateTime.fromMillisecondsSinceEpoch(
            refreshed,
          ).toLocal().toString().split('.').first;
    final void Function(String hostId)? refresh = onRefresh;
    return AdaptiveSettingsSection(
      key: ValueKey<String>('interconnect-lookup-host-$hostId'),
      title: name,
      children: <Widget>[
        AdaptiveSettingsSwitchRow(
          key: ValueKey<String>('interconnect-lookup-switch-$hostId'),
          title: t.interconnect_lookup_use_server,
          subtitle: t.interconnect_lookup_use_server_desc,
          icon: FushiIcons.dictionary,
          showIcon: true,
          value: interconnectHostLookupEnabled(urls, hostId),
          onChanged: (bool value) => onLookupChanged(hostId, value),
        ),
        AdaptiveSettingsRow(
          key: ValueKey<String>('interconnect-lookup-summary-$hostId'),
          title: t.interconnect_dictionaries_available(
            n: summary?.hosted ?? 0,
            time: refreshedLabel,
          ),
          icon: FushiIcons.schedule,
          showIcon: true,
          trailing: refresh == null
              ? null
              : FushiIconButton(
                  key: ValueKey<String>('interconnect-lookup-refresh-$hostId'),
                  icon: FushiIcons.refresh,
                  tooltip: t.interconnect_dictionaries_refresh,
                  enabled: !refreshingHosts.contains(hostId),
                  onTap: () => refresh(hostId),
                ),
        ),
      ],
    );
  }
}
