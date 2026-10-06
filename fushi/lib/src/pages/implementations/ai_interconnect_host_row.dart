import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/pages/implementations/module_settings_view.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 「设置 › AI › AI 下视频」里的「经 Fushi 互联交给电脑办」一行。
///
/// 这不是一项新偏好：AI 下视频是否交给已配对的电脑，自 PR #1749 起就由「下载执行
/// 设备」（`download_execution_host`）决定（`home_page.dart` 的
/// `_openAiVideoAcquisition` → `resolveDownloadExecution`）。此前它只在「下载」设置
/// 页出现，AI 设置页完全看不到互联这条路，用户以为没有这个选项。这里写的是**同一个**
/// 偏好键，两处显示同一份真相。
///
/// 已配对：本机 / 各台 host 的下拉，与下载页同一份候选（同一台 host 的多条地址只列
/// 一次）。未配对：不像下载页那样整行不渲染，而是给一行可见说明，点了去「互联」配对
/// （互联模块被关掉时只留说明，不推一个空页面）。
class AiInterconnectHostRow extends StatefulWidget {
  const AiInterconnectHostRow({required this.appModel, super.key});

  final AppModel appModel;

  @override
  State<AiInterconnectHostRow> createState() => _AiInterconnectHostRowState();
}

class _AiInterconnectHostRowState extends State<AiInterconnectHostRow> {
  /// 已配对且启用的 host 代表（每台一条）。
  List<FushiClientUrl> _pairedHosts = const <FushiClientUrl>[];

  /// 全部已启用地址（含同一台 host 的多条），用于把偏好里的地址归到它的 host。
  List<FushiClientUrl> _pairedUrls = const <FushiClientUrl>[];

  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPairedHosts());
  }

  Future<void> _loadPairedHosts() async {
    final AppModel appModel = widget.appModel;
    // 配对清单在 DB 的 preferences 表里；库没开就是没有 host。
    if (!appModel.isDatabaseReady) {
      if (mounted) setState(() => _loaded = true);
      return;
    }
    final List<FushiClientUrl> enabled =
        (await SyncRepository(appModel.database).getFushiClientUrls())
            .where((FushiClientUrl u) => u.enabled)
            .toList(growable: false);
    if (!mounted) return;
    setState(() {
      _pairedUrls = enabled;
      _pairedHosts = interconnectPeerRepresentatives(enabled);
      _loaded = true;
    });
  }

  /// 偏好里的执行设备归到所属 host；已解绑的不在这里自愈（下载页与解析侧各有
  /// 一层兜底），只按「本机」显示。
  String _selectedValue() {
    final String url = widget.appModel.prefsRepo.downloadExecutionHostUrl;
    if (url.isEmpty) return '';
    final FushiClientUrl? host = interconnectPeerRepresentativeOf(
      _pairedUrls,
      url,
    );
    return host?.url ?? '';
  }

  bool get _interconnectVisible => isSettingsDestinationVisible(
    SettingsDestinationId.interconnect,
    widget.appModel.moduleVisibility,
  );

  Future<void> _openInterconnectSettings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => Scaffold(
          body: SafeArea(
            child: ModuleSettingsView.route(
              destinationId: SettingsDestinationId.interconnect,
              title: t.settings_destination_interconnect,
            ),
          ),
        ),
      ),
    );
    // 从互联页回来可能刚配好一台：重新读配对清单。
    if (mounted) unawaited(_loadPairedHosts());
  }

  @override
  Widget build(BuildContext context) {
    if (_loaded && _pairedHosts.isNotEmpty) {
      return AdaptiveSettingsPickerRow<String>(
        key: const ValueKey<String>('ai-interconnect-host'),
        title: t.ai_interconnect_host_title,
        subtitle: t.ai_interconnect_host_hint,
        icon: FushiIcons.devices,
        showIcon: true,
        controlBelow: true,
        selected: _selectedValue(),
        options: <AdaptiveSettingsPickerOption<String>>[
          AdaptiveSettingsPickerOption<String>(
            value: '',
            label: t.download_target_local,
          ),
          for (final FushiClientUrl host in _pairedHosts)
            AdaptiveSettingsPickerOption<String>(
              value: host.url,
              label: t.download_target_remote(
                device: host.deviceName ?? host.url,
              ),
            ),
        ],
        onChanged: (String value) async {
          await widget.appModel.prefsRepo.setDownloadExecutionHostUrl(value);
          if (mounted) setState(() {});
        },
      );
    }
    final bool canPair = _interconnectVisible;
    return AdaptiveSettingsRow(
      key: const ValueKey<String>('ai-interconnect-host-unpaired'),
      title: t.ai_interconnect_host_title,
      subtitle: t.ai_interconnect_host_unpaired,
      icon: FushiIcons.devices,
      showIcon: true,
      trailing: canPair
          ? FushiIcon(
              FushiIcons.chevronRight,
              size: 20,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            )
          : null,
      onTap: canPair ? () => unawaited(_openInterconnectSettings()) : null,
    );
  }
}
