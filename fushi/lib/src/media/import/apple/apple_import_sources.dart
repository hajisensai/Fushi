/// Apple 导入页（方案 A）的来源部分：「网络与服务器」组里来自来源区的行（连接
/// 服务器 / Fushi 互联 / 浏览对端漫画库）与「常驻来源」组（含 Apple「编辑」模式）。
///
/// 数据与动作仍只在 `MediaSourcesViewState` 一份：它在 Cupertino 主题下不画色块，
/// 而是把 [AppleImportSourcesData]（[ImportSourceBlockData] 列表 + 互联 / 添加 /
/// 连接服务器的开关量与回调）交给外层 `AppleImportLayout` 经 [AppleImportScope]
/// 下发的 compose 函数，由布局决定这些组放在哪一栏。
library;

import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/import/apple/apple_import_rows.dart';
import 'package:fushi/src/media/import/import_source_blocks.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptiveSwitch;
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_reorderable_column.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiLinearProgressIndicator;
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 来源区交给 Apple 布局的全部数据（纯数据 + 回调，动作仍在来源视图里）。
@immutable
class AppleImportSourcesData {
  const AppleImportSourcesData({
    required this.sources,
    required this.interconnectEnabled,
    required this.onInterconnectChanged,
    required this.onReorder,
    required this.onAddSource,
    required this.addSourceHint,
    this.onBrowseInterconnect,
    this.browseLabel,
    this.browseDisabledHint,
    this.onConnectServer,
    this.connectServerHint,
  });

  /// 扫描根；null = 仍在加载。
  final List<ImportSourceBlockData>? sources;

  /// 互联总开关；null = 仍在加载。
  final bool? interconnectEnabled;
  final ValueChanged<bool> onInterconnectChanged;

  /// 「浏览对端漫画库」（漫画）；null = 没有这一行。
  final VoidCallback? onBrowseInterconnect;
  final String? browseLabel;
  final String? browseDisabledHint;

  /// 「连接服务器」（书 / 漫画）；null = 没有这一行。
  final VoidCallback? onConnectServer;
  final String? connectServerHint;

  /// 「添加来源」；null = 此刻不可用（忙）。
  final VoidCallback? onAddSource;
  final String addSourceHint;

  /// 编辑模式重排：第 from 个挪到最终下标 to（持久化在来源视图里）。
  final void Function(int from, int to) onReorder;
}

/// 能在 Apple 导入布局里交出 [AppleImportSourcesData] 的来源区（`MediaSourcesView`
/// 的色块呈现）。布局据此决定来源组由谁画：实现方且 [composesAppleImport] 为真时
/// 由它经 [AppleImportScope] 回调布局；否则布局自己画全部方式组，再把来源区原样
/// 接在后面。
abstract interface class AppleImportSourcesComposer {
  bool get composesAppleImport;
}

/// Apple 导入布局下发给来源区的 compose 函数（纯数据通道，与设计系统分派无关）。
class AppleImportScope extends InheritedWidget {
  const AppleImportScope({
    required this.compose,
    required super.child,
    super.key,
  });

  final Widget Function(BuildContext context, AppleImportSourcesData data)
  compose;

  static AppleImportScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppleImportScope>();

  @override
  bool updateShouldNotify(AppleImportScope oldWidget) =>
      oldWidget.compose != compose;
}

/// 「网络与服务器」组里来自来源区的行：连接服务器 → Fushi 互联 → 浏览对端漫画库。
List<Widget> appleImportNetworkRows(
  BuildContext context,
  AppleImportSourcesData data,
) {
  final bool? interconnect = data.interconnectEnabled;
  final VoidCallback? connect = data.onConnectServer;
  final VoidCallback? browse = data.onBrowseInterconnect;
  final String? browseLabel = data.browseLabel;
  return <Widget>[
    if (connect != null)
      AdaptiveSettingsRow(
        key: const ValueKey<String>('import-connect-server'),
        title: t.discovery_guide_connect_server,
        subtitle: data.connectServerHint,
        leading: const AppleImportIconTile(icon: FushiIcons.storage),
        trailing: const FushiAppleChevron(),
        onTap: connect,
      ),
    if (interconnect != null)
      AdaptiveSettingsRow(
        key: const ValueKey<String>('import-interconnect'),
        title: t.audio_source_fushi_interconnect,
        subtitle: t.interconnect_enable_hint,
        leading: const AppleImportIconTile(icon: FushiIcons.devices),
        trailing: adaptiveSwitch(
          context: context,
          value: interconnect,
          onChanged: data.onInterconnectChanged,
        ),
        onTap: () => data.onInterconnectChanged(!interconnect),
      ),
    if (interconnect != null && browse != null && browseLabel != null)
      AdaptiveSettingsRow(
        key: const ValueKey<String>('import-interconnect-browse'),
        title: browseLabel,
        subtitle: interconnect ? null : data.browseDisabledHint,
        leading: const AppleImportIconTile(icon: FushiIcons.link, plain: true),
        trailing: const FushiAppleChevron(),
        onTap: interconnect ? browse : null,
      ),
  ];
}

/// 「常驻来源」组：组头「编辑 / 完成」→ 每个扫描根一行 → 末行「添加来源」。
///
/// 编辑模式（Apple「编辑」）：行首红色删除钮（走菜单里同一个「移除来源」动作与
/// 确认框）、行尾 ≡ 重排把手（拖动 / Alt+↑↓ / 读屏「上移 / 下移」），其余行尾动作
/// 隐去；「完成」退出。非编辑态不画拖动手柄。
class AppleImportSourcesSection extends StatefulWidget {
  const AppleImportSourcesSection({required this.data, super.key});

  final AppleImportSourcesData data;

  @override
  State<AppleImportSourcesSection> createState() =>
      _AppleImportSourcesSectionState();
}

class _AppleImportSourcesSectionState extends State<AppleImportSourcesSection> {
  bool _editing = false;

  @override
  Widget build(BuildContext context) {
    final AppleImportSourcesData data = widget.data;
    final List<ImportSourceBlockData>? sources = data.sources;
    final bool editing = _editing && (sources?.isNotEmpty ?? false);
    final VoidCallback? add = data.onAddSource;
    final Widget addRow = AdaptiveSettingsRow(
      key: const ValueKey<String>('import-sources-add'),
      title: t.media_source_add,
      subtitle: data.addSourceHint,
      leading: const AppleImportIconTile(icon: FushiIcons.add, plain: true),
      onTap: editing ? null : add,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AdaptiveSettingsSection(
          title: t.media_source_section_title,
          titleTrailing: sources == null || sources.isEmpty
              ? null
              : AppleImportSectionAction(
                  key: const ValueKey<String>('import-sources-edit'),
                  label: editing ? t.dialog_done : t.dialog_edit,
                  onTap: () => setState(() => _editing = !editing),
                ),
          children: <Widget>[
            if (sources == null)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: AppleImportRowSpinner()),
              )
            else if (sources.isNotEmpty)
              FushiReorderableColumn(
                itemCount: sources.length,
                useDragHandles: true,
                keyForIndex: (int i) =>
                    ValueKey<String>('media_source_${sources[i].id}'),
                onReorder: data.onReorder,
                itemBuilder: (BuildContext context, int i) =>
                    AppleImportSourceRow(
                      data: sources[i],
                      index: i,
                      count: sources.length,
                      editing: editing,
                      onReorder: data.onReorder,
                    ),
              ),
            addRow,
          ],
        ),
      ],
    );
  }
}

/// 一个扫描根的列表行：名称（私密徽标）+ 位置 + 状态（进度 / 扫描失败 / 计数 ·
/// 上次扫描）+ 进度条 + 自动添加来源 + 视频上次刮削摘要（可点）。
///
/// 行尾：macOS 档平铺「重新扫描 / 刮削 / 刮削设置 / ⋯」；iOS 档只留 ⋯（重新扫描与
/// 刮削动作排进菜单顶部），在扫时转圈、扫描失败时「重试」。
class AppleImportSourceRow extends StatelessWidget {
  const AppleImportSourceRow({
    required this.data,
    required this.index,
    required this.count,
    required this.editing,
    required this.onReorder,
    super.key,
  });

  final ImportSourceBlockData data;
  final int index;
  final int count;
  final bool editing;
  final void Function(int from, int to) onReorder;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final FushiAppleColors colors = appleColorsOf(context);
    final TextStyle sub = metrics.subtitleStyle(context);
    final String scan = <String>[
      data.countText,
      if (data.lastScanText != null) data.lastScanText!,
    ].join(' · ');
    final String? progress = data.progressText;
    final Widget status = progress != null
        ? Text(
            progress,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: sub,
          )
        : data.scanError
        ? Row(
            key: ValueKey<String>('media_source_scan_error_${data.id}'),
            children: <Widget>[
              FushiIcon(
                FushiIcons.warning,
                size: sub.fontSize,
                color: colors.destructive,
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  <String>[
                    t.media_source_scan_error,
                    if (data.lastScanText != null) data.lastScanText!,
                  ].join(' · '),
                  style: sub.copyWith(color: colors.destructive),
                ),
              ),
            ],
          )
        : Text(scan, style: sub);
    final String? owner = data.autoOwnerText;
    final String? scrape = data.scrapeSummaryText;
    final Widget details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          data.location,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: metrics
              .footnoteStyle(context)
              .copyWith(fontFamily: 'monospace'),
        ),
        status,
        if (data.working)
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 2),
            child: FushiLinearProgressIndicator(
              value: data.progressValue,
              minHeight: 4,
              wavy: false,
            ),
          ),
        if (owner != null)
          Text(
            owner,
            key: ValueKey<String>('media_source_auto_owner_${data.id}'),
            style: sub,
          ),
        if (scrape != null)
          GestureDetector(
            key: ValueKey<String>('media-source-scrape-summary-${data.id}'),
            behavior: HitTestBehavior.opaque,
            onTap: data.onScrapeSummary,
            child: Text.rich(
              TextSpan(
                children: <InlineSpan>[
                  TextSpan(text: scrape),
                  if (data.onScrapeSummary != null)
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: Padding(
                        padding: const EdgeInsetsDirectional.only(start: 2),
                        child: FushiIcon(
                          FushiIcons.chevronRight,
                          size: sub.fontSize,
                          color: colors.tertiaryLabel,
                        ),
                      ),
                    ),
                ],
              ),
              style: sub.copyWith(
                color: data.scrapeSummaryFailed ? colors.destructive : null,
              ),
            ),
          ),
      ],
    );

    ImportSourceMenuAction? remove;
    for (final ImportSourceMenuAction action in data.menu) {
      if (action.destructive) remove = action;
    }

    final Widget tile = AppleImportIconTile(
      icon: data.remote ? FushiIcons.cloud : FushiIcons.folder,
    );
    final Widget leading = editing
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FushiIconButton(
                key: ValueKey<String>('import-source-delete-${data.id}'),
                icon: FushiIcons.removeCircle,
                tooltip: remove?.label ?? t.media_source_remove,
                enabled: remove?.onTap != null,
                onTap: remove?.onTap,
                enabledColor: colors.destructive,
                size: metrics.desktop ? 18 : 22,
                padding: EdgeInsets.zero,
                constraints: BoxConstraints.tight(
                  Size.square(metrics.desktop ? 24 : 32),
                ),
              ),
              SizedBox(width: metrics.desktop ? 6 : 8),
              tile,
            ],
          )
        : tile;

    final Widget trailing = editing
        ? _AppleSourceReorderHandle(
            index: index,
            count: count,
            onReorder: onReorder,
          )
        : _trailingActions(context, metrics);

    // 来源行整行不可点（只有行内按钮），内容是多行富文本（位置 / 状态 / 进度条 /
    // 刮削摘要），[AdaptiveSettingsRow] 的说明位只收一行行内件，所以这里按同一套
    // Apple 行度量（[FushiAppleMetrics]）自排：行首件 → 文字列 → 行尾件。
    final Widget row = Padding(
      key: ValueKey<String>('media-source-${data.id}'),
      padding: EdgeInsetsDirectional.symmetric(
        horizontal: metrics.rowHorizontal,
        vertical: metrics.rowVertical + 2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(padding: const EdgeInsets.only(top: 2), child: leading),
          SizedBox(width: FushiDesignTokens.of(context).spacing.gap + 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        data.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: metrics.titleStyle(context),
                      ),
                    ),
                    if (data.isPrivate) ...<Widget>[
                      const SizedBox(width: 6),
                      _AppleSourceBadge(
                        icon: FushiIcons.lock,
                        label: t.media_source_privacy_badge,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                details,
              ],
            ),
          ),
          const SizedBox(width: 8),
          AnimatedSwitcher(
            duration: fushiMotionDuration(context, FushiMotion.short),
            child: KeyedSubtree(key: ValueKey<bool>(editing), child: trailing),
          ),
        ],
      ),
    );
    if (index == 0) return row;
    final double inset =
        metrics.rowHorizontal +
        metrics.iconTileSize +
        FushiDesignTokens.of(context).spacing.gap +
        4;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          height: fushiHairline(context),
          margin: EdgeInsetsDirectional.only(start: inset),
          color: colors.separator,
        ),
        row,
      ],
    );
  }

  Widget _trailingActions(BuildContext context, FushiAppleMetrics metrics) {
    final FushiAppleColors colors = appleColorsOf(context);
    final bool desktop = metrics.desktop;
    final VoidCallback? rescan = data.onRescan;
    final List<Widget> buttons = <Widget>[];
    if (data.scanError && !data.working) {
      buttons.add(
        _AppleSourceTextAction(
          key: ValueKey<String>('media_source_rescan_${data.id}'),
          label: t.retry,
          onTap: rescan,
        ),
      );
    } else if (desktop) {
      buttons.add(
        _AppleSourceIconButton(
          key: ValueKey<String>('media_source_rescan_${data.id}'),
          icon: FushiIcons.refresh,
          tooltip: t.media_source_rescan,
          busy: data.rescanBusy,
          onTap: rescan,
        ),
      );
    } else if (data.working) {
      buttons.add(const AppleImportRowSpinner());
    }
    if (desktop) {
      for (final ImportSourceIconAction action in data.actions) {
        buttons.add(
          _AppleSourceIconButton(
            key: action.key,
            icon: action.icon,
            tooltip: action.tooltip,
            busy: action.busy,
            onTap: action.onTap,
          ),
        );
      }
    }
    // iOS 档：重新扫描与刮削动作排进 ⋯ 菜单顶部（行尾只留一颗圆钮）。
    final List<ImportSourceMenuAction> menu = <ImportSourceMenuAction>[
      if (!desktop && !data.scanError)
        ImportSourceMenuAction(
          key: ValueKey<String>('media_source_rescan_menu_${data.id}'),
          label: t.media_source_rescan,
          icon: FushiIcons.refresh,
          onTap: rescan,
        ),
      if (!desktop)
        for (final ImportSourceIconAction action in data.actions)
          ImportSourceMenuAction(
            key: action.key,
            label: action.tooltip,
            icon: action.icon,
            onTap: action.onTap,
          ),
      ...data.menu,
    ];
    buttons.add(
      ImportSourceMenuButton(
        key: ValueKey<String>('import-source-more-${data.id}'),
        actions: menu,
        color: desktop ? colors.secondaryLabel : colors.label,
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: desktop ? 2 : 6,
      children: buttons,
    );
  }
}

/// 行尾小圆钮（macOS 档：无底、secondaryLabel 字形；命中区补到 ≥ 32）。
class _AppleSourceIconButton extends StatelessWidget {
  const _AppleSourceIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.busy = false,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors colors = appleColorsOf(context);
    return FushiIconButton(
      icon: icon,
      tooltip: tooltip,
      busy: busy,
      enabled: onTap != null,
      onTap: onTap,
      size: 16,
      enabledColor: colors.secondaryLabel,
      disabledColor: colors.tertiaryLabel,
      backgroundColor: Colors.transparent,
      padding: const EdgeInsets.all(6),
      padTouchTarget: true,
    );
  }
}

/// 行尾强调色文字动作（「重试」）。
class _AppleSourceTextAction extends StatelessWidget {
  const _AppleSourceTextAction({
    required this.label,
    required this.onTap,
    super.key,
  });

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final FushiAppleColors colors = appleColorsOf(context);
    return Semantics(
      button: true,
      enabled: onTap != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 44, minHeight: 32),
          child: Center(
            widthFactor: 1,
            child: Text(
              label,
              style: metrics
                  .subtitleStyle(context)
                  .copyWith(
                    color: onTap == null ? colors.tertiaryLabel : colors.accent,
                  ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 名称后的小徽标（私密）。
class _AppleSourceBadge extends StatelessWidget {
  const _AppleSourceBadge({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors colors = appleColorsOf(context);
    final TextStyle style = context.fushiType.labelSmall.copyWith(
      color: colors.secondaryLabel,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.fill,
        borderRadius: FushiBorderRadius.chip,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 3,
          children: <Widget>[
            FushiIcon(icon, size: 10, color: colors.secondaryLabel),
            Text(label, style: style),
          ],
        ),
      ),
    );
  }
}

/// 编辑模式的 ≡ 重排把手：拖动（[FushiReorderableDragHandle]）、Alt+↑/↓、读屏
/// 「上移 / 下移」三条路径同一个 [onReorder]。
class _AppleSourceReorderHandle extends StatelessWidget {
  const _AppleSourceReorderHandle({
    required this.index,
    required this.count,
    required this.onReorder,
  });

  final int index;
  final int count;
  final void Function(int from, int to) onReorder;

  void _move(int delta) {
    final int to = index + delta;
    if (to < 0 || to >= count) return;
    onReorder(index, to);
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors colors = appleColorsOf(context);
    return Semantics(
      label: t.tag_manage_reorder_hint,
      customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
        if (index > 0) CustomSemanticsAction(label: t.move_up): () => _move(-1),
        if (index < count - 1)
          CustomSemanticsAction(label: t.move_down): () => _move(1),
      },
      child: FocusableActionDetector(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.arrowUp, alt: true):
              _MoveAppleSourceIntent(-1),
          SingleActivator(LogicalKeyboardKey.arrowDown, alt: true):
              _MoveAppleSourceIntent(1),
        },
        actions: <Type, Action<Intent>>{
          _MoveAppleSourceIntent: CallbackAction<_MoveAppleSourceIntent>(
            onInvoke: (_MoveAppleSourceIntent intent) {
              _move(intent.delta);
              return null;
            },
          ),
        },
        mouseCursor: SystemMouseCursors.grab,
        child: FushiReorderableDragHandle(
          child: SizedBox.square(
            dimension: 44,
            child: Center(
              child: FushiIcon(
                FushiIcons.dragHandle,
                size: 20,
                color: colors.tertiaryLabel,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MoveAppleSourceIntent extends Intent {
  const _MoveAppleSourceIntent(this.delta);

  final int delta;
}
