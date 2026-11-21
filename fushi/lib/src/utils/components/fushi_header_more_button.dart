/// 库页页头的「⋯」按钮（设计稿 #video V2 / #music M1：顶栏只平铺高频动作，低频
/// 动作收进「⋯」）。视频库与曲库共用这一件。
///
/// 点开是 [showFushiMenu]，与页头自适应收纳的「⋯」同一个菜单组件、同一种项形态；
/// 按钮恒外露（[FushiIconButton.alwaysVisible]）。最窄位置被页头整体收进它自己的
/// 「⋯」时，菜单锚在那颗代派发的按钮上（[FushiActionOrigin]）。
library;

import 'dart:async' show FutureOr;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart'
    show showFushiMenu;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 「⋯」菜单里的一项。
@immutable
class FushiHeaderMoreEntry {
  const FushiHeaderMoreEntry({
    required this.key,
    required this.icon,
    required this.label,
    required this.onSelected,
    this.enabled = true,
  });

  /// 菜单项 key（测试 / 焦点驱动定位用）。
  final Key key;
  final IconData icon;
  final String label;
  final FutureOr<void> Function() onSelected;
  final bool enabled;
}

/// 页头「⋯」按钮：点开一张列出 [entries] 的菜单。
class FushiHeaderMoreButton extends StatelessWidget {
  const FushiHeaderMoreButton({
    required this.entries,
    required this.buttonKey,
    this.leadingEntries = const <FushiHeaderMoreEntry>[],
    super.key,
  });

  final List<FushiHeaderMoreEntry> entries;

  /// 排在 [entries] 前面、用分隔线隔开的一组：页头自适应收纳
  /// （[fushiResolveHeaderActions]）放不下的外露动作合进这颗「⋯」，而不是再生
  /// 一颗并排的「⋯」（设计稿 11-20 #16「顶栏两个 ⋮」）。
  final List<FushiHeaderMoreEntry> leadingEntries;

  /// 同一颗按钮再并进一组 [leading]（排在已有的 [leadingEntries] 前面）。
  FushiHeaderMoreButton withLeadingEntries(
    List<FushiHeaderMoreEntry> leading,
  ) => FushiHeaderMoreButton(
    key: key,
    buttonKey: buttonKey,
    entries: entries,
    leadingEntries: <FushiHeaderMoreEntry>[...leading, ...leadingEntries],
  );

  /// 按钮本体的 key（测试 / 焦点驱动定位用，如 `video-library-more`）。
  final Key buttonKey;

  @override
  Widget build(BuildContext context) => Builder(
    builder: (BuildContext anchorContext) => FushiIconButton(
      key: buttonKey,
      icon: FushiIcons.more,
      tooltip: t.common_more_actions,
      alwaysVisible: true,
      onTap: () => _open(FushiActionOrigin.current ?? anchorContext),
    ),
  );

  Future<void> _open(BuildContext anchorContext) async {
    final RenderObject? box = anchorContext.findRenderObject();
    final RenderObject? overlayBox = Navigator.of(
      anchorContext,
    ).overlay?.context.findRenderObject();
    if (box is! RenderBox || overlayBox is! RenderBox) return;
    final RelativeRect position = RelativeRect.fromRect(
      Rect.fromPoints(
        box.localToGlobal(Offset.zero, ancestor: overlayBox),
        box.localToGlobal(
          box.size.bottomRight(Offset.zero),
          ancestor: overlayBox,
        ),
      ),
      Offset.zero & overlayBox.size,
    );
    final FushiHeaderMoreEntry? choice =
        await showFushiMenu<FushiHeaderMoreEntry>(
          context: anchorContext,
          position: position,
          items: <PopupMenuEntry<FushiHeaderMoreEntry>>[
            for (final FushiHeaderMoreEntry entry in leadingEntries)
              _item(entry),
            if (leadingEntries.isNotEmpty && entries.isNotEmpty)
              const PopupMenuDivider(
                key: ValueKey<String>('fushi-header-more-divider'),
              ),
            for (final FushiHeaderMoreEntry entry in entries) _item(entry),
          ],
        );
    if (choice == null) return;
    // 菜单项代派发的动作，触发控件记成「⋯」（筛选面板等据此锚定 / 还焦点）。
    if (!anchorContext.mounted) {
      await choice.onSelected();
      return;
    }
    await FushiActionOrigin.dispatch(anchorContext, choice.onSelected);
  }

  static PopupMenuItem<FushiHeaderMoreEntry> _item(
    FushiHeaderMoreEntry entry,
  ) => PopupMenuItem<FushiHeaderMoreEntry>(
    key: entry.key,
    value: entry,
    enabled: entry.enabled,
    child: Row(
      children: <Widget>[
        FushiIcon(entry.icon, size: 20),
        const SizedBox(width: 12),
        Expanded(child: Text(entry.label)),
      ],
    ),
  );
}
