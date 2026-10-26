import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/web_browser/web_browser_prefs.dart';

/// 菜单里的一行：图标 + 文案 + 点击动作。[selected] 给开关类（桌面版网页）。
@immutable
class WebBrowserMenuItem {
  const WebBrowserMenuItem({
    required this.id,
    required this.icon,
    required this.label,
    required this.onSelected,
    this.selected = false,
    this.enabled = true,
  });

  final String id;
  final IconData icon;
  final String label;
  final VoidCallback onSelected;
  final bool selected;
  final bool enabled;
}

/// 「⋯」菜单 / 标签右键菜单里的一段：一组行，或一个自绘控件（文字大小、标签页
/// 样式分段）。段与段之间画分隔线。
sealed class WebBrowserMenuSection {
  const WebBrowserMenuSection();
}

class WebBrowserMenuItems extends WebBrowserMenuSection {
  const WebBrowserMenuItems(this.items);
  final List<WebBrowserMenuItem> items;
}

class WebBrowserMenuWidget extends WebBrowserMenuSection {
  const WebBrowserMenuWidget({
    required this.id,
    required this.builder,
    this.height = 72,
  });

  final String id;
  final WidgetBuilder builder;
  final double height;
}

/// 按段弹出菜单（两套设计系统同一个 [showFushiMenu]）。选中的行在菜单关掉后再执行。
Future<void> showWebBrowserMenu({
  required BuildContext context,
  required List<WebBrowserMenuSection> sections,
  Offset? globalPosition,
  BuildContext? anchor,
}) async {
  final List<PopupMenuEntry<String>> entries = <PopupMenuEntry<String>>[];
  final Map<String, VoidCallback> actions = <String, VoidCallback>{};
  for (final WebBrowserMenuSection section in sections) {
    final bool empty = switch (section) {
      WebBrowserMenuItems(:final List<WebBrowserMenuItem> items) =>
        items.isEmpty,
      WebBrowserMenuWidget() => false,
    };
    if (empty) continue;
    if (entries.isNotEmpty) entries.add(const PopupMenuDivider());
    switch (section) {
      case WebBrowserMenuItems(:final List<WebBrowserMenuItem> items):
        for (final WebBrowserMenuItem item in items) {
          actions[item.id] = item.onSelected;
          entries.add(
            FushiPopupMenuItem<String>(
              key: ValueKey<String>('web-browser-menu-${item.id}'),
              value: item.id,
              label: item.label,
              icon: item.icon,
              selected: item.selected,
              enabled: item.enabled,
            ),
          );
        }
      case WebBrowserMenuWidget(
        :final String id,
        :final WidgetBuilder builder,
        :final double height,
      ):
        entries.add(
          _WidgetMenuEntry<String>(
            key: ValueKey<String>('web-browser-menu-$id'),
            height: height,
            builder: builder,
          ),
        );
    }
  }
  if (entries.isEmpty) return;
  final RelativeRect position;
  final RenderBox overlay =
      Overlay.of(context).context.findRenderObject()! as RenderBox;
  if (globalPosition != null) {
    final Offset local = overlay.globalToLocal(globalPosition);
    position = RelativeRect.fromRect(
      local & const Size(1, 1),
      Offset.zero & overlay.size,
    );
  } else {
    final RenderBox button =
        (anchor ?? context).findRenderObject()! as RenderBox;
    // 锚点就是按钮自己的矩形：showFushiMenu 自己把菜单排在锚点下沿（放不下翻到
    // 上沿）。旧写法把锚点整体下移了一个按钮高，菜单和按钮之间空出一截（2026-10-26
    // 用户截图「三个点出来的和上面有很大的空隙」）。
    final Offset topLeft = button.localToGlobal(Offset.zero, ancestor: overlay);
    position = RelativeRect.fromRect(
      topLeft & button.size,
      Offset.zero & overlay.size,
    );
  }
  final String? picked = await showFushiMenu<String>(
    context: context,
    position: position,
    items: entries,
    constraints: const BoxConstraints(minWidth: 240, maxWidth: 320),
  );
  if (picked == null) return;
  actions[picked]?.call();
}

class _WidgetMenuEntry<T> extends PopupMenuEntry<T> {
  const _WidgetMenuEntry({
    required this.builder,
    required this.height,
    super.key,
  });

  final WidgetBuilder builder;
  @override
  final double height;

  @override
  bool represents(T? value) => false;

  @override
  State<_WidgetMenuEntry<T>> createState() => _WidgetMenuEntryState<T>();
}

class _WidgetMenuEntryState<T> extends State<_WidgetMenuEntry<T>> {
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    child: widget.builder(context),
  );
}

/// 菜单里「标签页样式」分段（设计系统分段组件，切换立即生效）。
class WebBrowserTabStyleSegments extends StatefulWidget {
  const WebBrowserTabStyleSegments({
    required this.value,
    required this.onChanged,
    super.key,
  });

  final WebBrowserTabStyle value;
  final ValueChanged<WebBrowserTabStyle> onChanged;

  @override
  State<WebBrowserTabStyleSegments> createState() =>
      _WebBrowserTabStyleSegmentsState();
}

class _WebBrowserTabStyleSegmentsState
    extends State<WebBrowserTabStyleSegments> {
  late WebBrowserTabStyle _value = widget.value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            FushiIcon(
              FushiIcons.tab,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Text(t.web_browser_tab_style, style: theme.textTheme.bodyMedium),
          ],
        ),
        const SizedBox(height: 6),
        adaptiveSegmentedButton<WebBrowserTabStyle>(
          context: context,
          segments: webBrowserTabStyleSegments(),
          selected: <WebBrowserTabStyle>{_value},
          onSelectionChanged: (Set<WebBrowserTabStyle> next) {
            if (next.isEmpty) return;
            setState(() => _value = next.first);
            widget.onChanged(next.first);
          },
        ),
      ],
    );
  }
}

/// 标签页样式的两个分段（菜单与设置页共用文案 / 图标）。
List<ButtonSegment<WebBrowserTabStyle>> webBrowserTabStyleSegments() =>
    <ButtonSegment<WebBrowserTabStyle>>[
      ButtonSegment<WebBrowserTabStyle>(
        value: WebBrowserTabStyle.sidebar,
        label: Text(t.web_browser_tab_style_sidebar),
        icon: const FushiIcon(FushiIcons.sidebar, size: 18),
      ),
      ButtonSegment<WebBrowserTabStyle>(
        value: WebBrowserTabStyle.topStrip,
        label: Text(t.web_browser_tab_style_top),
        icon: const FushiIcon(FushiIcons.tab, size: 18),
      ),
    ];

/// 菜单里「文字大小」一行：− 百分比 +（点百分比恢复 100%）。
class WebBrowserTextZoomRow extends StatefulWidget {
  const WebBrowserTextZoomRow({
    required this.value,
    required this.onChanged,
    super.key,
  });

  final int value;
  final ValueChanged<int> onChanged;

  @override
  State<WebBrowserTextZoomRow> createState() => _WebBrowserTextZoomRowState();
}

/// 文字大小步进（百分比）。
const int kWebBrowserTextZoomStep = 10;

/// 文字大小步进一次（50..300）。
int webBrowserStepTextZoom(int current, int direction) =>
    (current + direction * kWebBrowserTextZoomStep).clamp(50, 300);

class _WebBrowserTextZoomRowState extends State<WebBrowserTextZoomRow> {
  late int _value = widget.value;

  void _set(int v) {
    setState(() => _value = v);
    widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Row(
      children: <Widget>[
        FushiIcon(
          FushiIcons.fontSize,
          size: 20,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            t.web_browser_menu_text_size,
            style: theme.textTheme.bodyMedium,
          ),
        ),
        FushiIconButton(
          key: const ValueKey<String>('web-browser-text-zoom-out'),
          tooltip: t.web_browser_text_size_decrease,
          icon: FushiIcons.textDecrease,
          size: 18,
          padding: const EdgeInsets.all(6),
          onTap: () => _set(webBrowserStepTextZoom(_value, -1)),
        ),
        FushiTextButton(
          key: const ValueKey<String>('web-browser-text-zoom-reset'),
          onPressed: () => _set(100),
          child: Text('$_value%'),
        ),
        FushiIconButton(
          key: const ValueKey<String>('web-browser-text-zoom-in'),
          tooltip: t.web_browser_text_size_increase,
          icon: FushiIcons.textIncrease,
          size: 18,
          padding: const EdgeInsets.all(6),
          onTap: () => _set(webBrowserStepTextZoom(_value, 1)),
        ),
      ],
    );
  }
}
