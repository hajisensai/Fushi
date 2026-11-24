/// 复习页顶部的复习库切换（拍板台 design-srs-shared-library 方案 a，组合阶段 4，设计 §4.1
/// 「复习页：默认显示共享库；存在独立库时顶部多一个库切换（不新增导航入口）」）。
///
/// 只在有两份以上复习库（共享库 + 某些组合拆出的独立库）时由牌组列表放进页头横幅；切换只改
/// 复习页此刻看的库（[srsLibraryChoiceProvider]），不改制卡落点——制卡仍落激活配置解析出的那份库
/// （[SrsLibraries.activeUid]）。选回激活配置的库 = 清掉选择、跟着激活配置走。
///
/// 只收数据与回调、不读 provider：复习库 provider 在 `srs_providers.dart`（AppModel 所在的 import 环里），
/// 本控件直接 watch 它会把自己拉进环（`import_cycle_guard_test.dart`）。牌组列表负责 watch 与写选择。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/srs/srs_library.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptiveSegmentedButton;
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';

/// 复习库分段的显示名：共享库写「共享复习库」，独立库写拆出它的组合名（组合已不在时退回 uid）。
String srsLibraryEntryLabel(SrsLibraryEntry entry) =>
    entry.shared ? t.srs_library_shared : (entry.ownerName ?? entry.uid);

/// 复习库切换条（见库文档）。少于两份库时不占位。
class SrsLibrarySwitcher extends StatelessWidget {
  const SrsLibrarySwitcher({
    super.key,
    required this.libraries,
    required this.onChoiceChanged,
  });

  /// 此刻的复习库解析结果。
  final SrsLibraries libraries;

  /// 用户切了库：新的选择（写进 [srsLibraryChoiceProvider]）；null = 跟着激活配置。
  final ValueChanged<String?> onChoiceChanged;

  @override
  Widget build(BuildContext context) {
    if (!libraries.switchable) return const SizedBox.shrink();
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Semantics(
      container: true,
      label: t.srs_library_switch_label,
      child: Row(
        children: <Widget>[
          Text(
            t.srs_library_switch_label,
            style: Theme.of(context).textTheme.labelLarge,
          ),
          SizedBox(width: tokens.spacing.gap),
          Expanded(
            // 组合名可能很长、库可能不止两三份：横向滚动，分段按内容取宽（无界宽，见
            // [adaptiveSegmentedButton]）。
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: adaptiveSegmentedButton<String>(
                context: context,
                segments: <ButtonSegment<String>>[
                  for (final SrsLibraryEntry e in libraries.entries)
                    ButtonSegment<String>(
                      value: e.uid,
                      label: Text(srsLibraryEntryLabel(e)),
                    ),
                ],
                selected: <String>{libraries.viewedUid},
                onSelectionChanged: (Set<String> next) {
                  if (next.isEmpty) return;
                  final String uid = next.first;
                  // 选回激活配置的库 = 跟着激活配置走（切配置时随之换库）。
                  onChoiceChanged(uid == libraries.activeUid ? null : uid);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
