/// 设置页「服务器列表」的可展开行：收起时一行摘要（名称 + 副标题），点击展开
/// 编辑面板。照抄 `jellyfin_settings_widget.dart` 的 `_buildServerRow`（分段卡片 +
/// 弹簧转箭头 + `AnimatedSize` 展开），供 Kavita / Audiobookshelf 设置区共用。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

class SettingsServerExpandableRow extends StatelessWidget {
  const SettingsServerExpandableRow({
    super.key,
    required this.index,
    required this.count,
    required this.title,
    required this.subtitle,
    required this.expanded,
    required this.onToggle,
    required this.panel,
    this.rowKey,
  });

  final int index;
  final int count;
  final String title;
  final String subtitle;
  final bool expanded;
  final VoidCallback onToggle;

  /// 展开后显示的面板内容。
  final List<Widget> panel;

  /// 摘要行（可点击的那一行）的 key，测试用来展开。
  final Key? rowKey;

  @override
  Widget build(BuildContext context) {
    final FushiMotionScheme motion = context.fushiMotion;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: FushiStaggeredEntrance(
        index: index,
        child: FushiGroupedListItem(
          index: index,
          count: count,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FushiListItem(
                key: rowKey,
                leading: const FushiListLeadingIcon(
                  FushiIcons.server,
                  shape: FushiLeadingShape.cookie,
                ),
                title: Text(title),
                subtitle: subtitle.isEmpty ? null : Text(subtitle),
                trailing: AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: motion.spatialFast.duration,
                  curve: motion.spatialFast.curve,
                  child: const FushiIcon(FushiIcons.expandMore),
                ),
                onTap: onToggle,
              ),
              AnimatedSize(
                duration: motion.spatialDefault.duration,
                curve: motion.spatialDefault.curve,
                alignment: Alignment.topCenter,
                child: !expanded
                    ? const SizedBox(width: double.infinity)
                    : Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: panel,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
