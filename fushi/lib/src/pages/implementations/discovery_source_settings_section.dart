import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/media/discovery/discovery_labels.dart';
import 'package:fushi/src/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/discovery/media_discovery_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/source_toggle_section.dart';
import 'package:fushi/utils.dart';

/// 「发现来源」开关区：统一发现页的内置源逐个可停用。
///
/// 停用清单（`discovery_disabled_sources`）从发现页上线起就存在，出厂默认停用
/// sukebei——但**没有任何 UI 写它**，用户既看不到有哪些源，也没法开关。这里补的
/// 就是那个缺口，不新造第二套状态：读写的就是那一个偏好。
///
/// 源列表直接遍历运行期注册表 [MediaDiscoveryService.sources]，而不是在设置层
/// 抄一份 id 清单：抄一份就要靠守卫测试盯着两边别漂，而遍历真身根本不会漂。
class DiscoverySourceSettingsSection extends ConsumerStatefulWidget {
  const DiscoverySourceSettingsSection({super.key});

  @override
  ConsumerState<DiscoverySourceSettingsSection> createState() =>
      _DiscoverySourceSettingsSectionState();
}

class _DiscoverySourceSettingsSectionState
    extends ConsumerState<DiscoverySourceSettingsSection> {
  @override
  Widget build(BuildContext context) {
    final AppModel appModel = ref.watch(appProvider);
    if (!appModel.isPreferencesReady) return const SizedBox.shrink();
    final List<MediaDiscoverySource> sources =
        appModel.mediaDiscoveryService.sources;
    final Set<String> disabled = appModel.discoveryDisabledSourceIds;
    // 与 TorrentSettingsSection(constrainWidth: false) 同一条 16px 左右基线：
    // 设置详情 pane 里本区与它上下相邻，不对齐会一眼看出是两块拼上去的。
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: FushiDesignTokens.of(context).spacing.rowHorizontal,
      ),
      child: Column(
        key: const ValueKey<String>('discovery-source-settings'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SourceSectionHeading(
            title: t.discovery_sources_settings_title,
            hint: t.discovery_sources_settings_hint,
            icon: Icons.travel_explore_outlined,
          ),
          SourceToggleList(
            keyPrefix: 'discovery-source',
            rows: <SourceToggleRow>[
              for (final MediaDiscoverySource source in sources)
                SourceToggleRow(
                  id: source.id,
                  title: source.displayName,
                  subtitle: t.discovery_source_kinds_label(
                    kinds: _kindsLabel(source),
                  ),
                  enabled: !disabled.contains(source.id),
                ),
            ],
            onChanged: (String sourceId, bool enabled) async {
              await appModel.setDiscoverySourceEnabled(sourceId, enabled);
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
    );
  }

  /// 源覆盖的域，按枚举声明序拼成一行——不按 Set 的迭代序，那个序不稳定，
  /// 会让同一台设备上两次打开设置看到不同顺序。
  String _kindsLabel(MediaDiscoverySource source) {
    final Set<DiscoveryMediaKind> kinds = source.capabilities.kinds;
    return DiscoveryMediaKind.values
        .where(kinds.contains)
        .map(discoveryMediaKindLabel)
        .join(' · ');
  }
}
