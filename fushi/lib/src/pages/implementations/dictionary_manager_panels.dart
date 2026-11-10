import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyEvent, KeyRepeatEvent, LogicalKeyboardKey;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/models/dictionary_repository.dart'
    show DictionaryRepository, RemoteDictionary;
import 'package:fushi/src/utils/components/fushi_inline_notice.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_chips.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_neutral_decor.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_tag.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

// 词典管理页（[DictionaryDialogPage]）的呈现组件：宽屏详情侧板 / 窄屏底部
// sheet 共用的「词典详情」、宽屏未选中时的「概览」、全空状态。全部是无状态
// 组件，动作经回调交回页面 State——数据层（导入 / 隐藏 / 排序 / 删除）仍只在
// 页面里调 AppModel，这里不碰。

/// 词典管理页切成「列表 + 详情侧板」两栏的最小窗宽（MD3 window size class
/// 的 expanded 起点）。窄于此走单列卡片列表 + 底部 sheet。
const double kDictionaryManagerSplitBreakpoint = 840;

/// 两栏布局里详情侧板的固定宽度。
const double kDictionaryManagerDetailPaneWidth = 400;

/// 当前窗宽是否走「列表 + 详情侧板」两栏布局。
bool dictionaryManagerUsesSplitLayout(double width) =>
    width >= kDictionaryManagerSplitBreakpoint;

/// 词典在本类型列表里的优先级序号（查词结果按这个顺序合并）。行首一枚圆形
/// 序号徽标：一眼看出谁排前面，停用的词典徽标退成中性色。
class DictionaryOrderBadge extends StatelessWidget {
  const DictionaryOrderBadge({
    required this.position,
    required this.enabled,
    this.serverHostName,
    super.key,
  });

  /// 1 起的序号。
  final int position;
  final bool enabled;

  /// 只在服务器上的词典：所在 host 的展示名。非 null 时徽标右下角挂一枚服务器小图标
  /// （替代以前行内的「服务器 · 名字」文字标签），设备名进 tooltip 与 Semantics。
  final String? serverHostName;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 停用：退成浮起面那一阶的中性底（tokens 色阶，不在页面里自选容器色）。
    final Color fill = enabled
        ? tokens.surfaces.primaryContainer
        : tokens.surfaces.search;
    final Color ink = enabled
        ? scheme.onPrimaryContainer
        : scheme.onSurfaceVariant;
    final Widget badge = SizedBox.square(
      dimension: 32,
      child: DecoratedBox(
        decoration: ShapeDecoration(shape: const CircleBorder(), color: fill),
        child: Center(
          child: Text(
            '$position',
            style: textTheme.labelLarge?.copyWith(
              color: ink,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
    final String? host = serverHostName;
    if (host == null) return badge;
    final String label = t.dictionary_source_server(name: host);
    // 小圆片描一圈页面底色，与序号圆分开；图标色跟序号同一套启用 / 停用色阶。
    return FushiTooltip(
      message: label,
      child: Semantics(
        label: label,
        child: SizedBox.square(
          dimension: 36,
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              Positioned(left: 0, top: 0, child: badge),
              Positioned(
                right: 0,
                bottom: 0,
                child: DecoratedBox(
                  key: const ValueKey<String>('dict-row-server-glyph'),
                  decoration: ShapeDecoration(
                    shape: CircleBorder(
                      side: BorderSide(color: tokens.surfaces.page, width: 2),
                    ),
                    color: enabled
                        ? tokens.surfaces.selected
                        : tokens.surfaces.search,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: FushiIcon(
                      FushiIcons.server,
                      size: 12,
                      color: enabled
                          ? scheme.onSecondaryContainer
                          : scheme.onSurfaceVariant,
                    ),
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

/// 单本词典的详情与全部动作。宽屏放在右侧详情侧板，窄屏放进底部 sheet，
/// 两处同一份内容（[showHeader] 只决定是否自己画标题——sheet 的标题由
/// sheet 外壳画）。
class DictionaryManagerDetail extends StatelessWidget {
  const DictionaryManagerDetail({
    required this.dictionary,
    required this.enabled,
    required this.collapseState,
    required this.typeLabel,
    required this.versionLabel,
    required this.formatLabel,
    required this.languageLabel,
    required this.position,
    required this.count,
    required this.onEnabledChanged,
    required this.onCollapseChanged,
    required this.onRename,
    required this.onLanguage,
    required this.onUpdate,
    required this.onMoveTo,
    required this.onMoveToPrompt,
    required this.onDelete,
    this.showHeader = true,
    this.headerTags = const <Widget>[],
    this.serverCopySection,
    this.transferSection,
    super.key,
  });

  final Dictionary dictionary;
  final bool enabled;
  final DictionaryCollapseState collapseState;
  final String typeLabel;
  final String versionLabel;
  final String formatLabel;
  final String languageLabel;

  /// 本词典在本类型列表里的下标（0 起）与列表总数。
  final int position;
  final int count;

  final ValueChanged<bool> onEnabledChanged;

  /// null = 不给折叠控件。折叠管的是查词弹窗里这本的**释义**；「汉字」分区里的行
  /// （纯 kanji 词典 / 混合词典的汉字部分）对应的是汉字卡，汉字卡不折叠——在那里给
  /// 这个控件，改的其实是混合词典术语部分的折叠状态（BUG-3573）。
  final ValueChanged<DictionaryCollapseState>? onCollapseChanged;
  final VoidCallback onRename;
  final VoidCallback onLanguage;
  final VoidCallback onUpdate;

  /// 移到本类型列表的最终下标（0 起）。
  final ValueChanged<int> onMoveTo;

  /// 「移到第几位」：弹位置输入框（见 [showDictionaryPositionDialog]）。
  final VoidCallback onMoveToPrompt;
  final VoidCallback onDelete;
  final bool showHeader;

  /// 标题下标签行的额外标签（「两者」行的来源 chip）。
  final List<Widget> headerTags;

  /// 「两者」行：服务器上那一份的信息分组（host、两边版本），null = 不画。
  final Widget? serverCopySection;

  /// 「推送到 <服务器>」分组（见 [DictionaryTransferSection]），null = 不画（没有
  /// 还缺这本的查词 host）。
  final Widget? transferSection;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double gap = tokens.spacing.gap;
    final Widget? serverCopy = serverCopySection;
    final Widget? transfer = transferSection;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (showHeader) ...<Widget>[
          _buildHeader(context),
          SizedBox(height: gap * 2),
        ],
        _buildQuickActions(context),
        SizedBox(height: gap),
        AdaptiveSettingsSection(
          title: t.dict_detail_lookup_section,
          children: <Widget>[
            AdaptiveSettingsSwitchRow(
              key: ValueKey<String>('dict-detail-enabled-${dictionary.name}'),
              title: t.options_show,
              icon: Icons.visibility_outlined,
              showIcon: true,
              value: enabled,
              onChanged: onEnabledChanged,
            ),
            if (onCollapseChanged != null)
              AdaptiveSettingsSegmentedRow<DictionaryCollapseState>(
                key: ValueKey<String>(
                  'dict-detail-collapse-${dictionary.name}',
                ),
                title: t.dict_detail_collapse_title,
                icon: Icons.unfold_more,
                showIcon: true,
                segments: <ButtonSegment<DictionaryCollapseState>>[
                  ButtonSegment<DictionaryCollapseState>(
                    value: DictionaryCollapseState.inherit,
                    label: Text(t.dict_collapse_state_inherit),
                  ),
                  ButtonSegment<DictionaryCollapseState>(
                    value: DictionaryCollapseState.expanded,
                    label: Text(t.dict_collapse_state_expanded),
                  ),
                  ButtonSegment<DictionaryCollapseState>(
                    value: DictionaryCollapseState.collapsed,
                    label: Text(t.dict_collapse_state_collapsed),
                  ),
                ],
                selected: collapseState,
                onChanged: onCollapseChanged!,
              ),
          ],
        ),
        SizedBox(height: gap),
        DictionaryOrderSection(
          position: position,
          count: count,
          onMoveTo: onMoveTo,
          onMoveToPrompt: onMoveToPrompt,
        ),
        SizedBox(height: gap),
        AdaptiveSettingsSection(
          title: t.dict_detail_info_section,
          children: <Widget>[
            _infoRow(context, t.dict_detail_type_label, typeLabel),
            if (versionLabel.isNotEmpty)
              _infoRow(context, t.dict_detail_version_label, versionLabel),
            _infoRow(context, t.dict_detail_format_label, formatLabel),
            _infoRow(context, t.dict_language_tooltip, languageLabel),
            _infoRow(
              context,
              t.dict_detail_source_label,
              dictionary.isUpdatable
                  ? t.dict_detail_source_online
                  : t.dict_detail_source_local,
            ),
          ],
        ),
        if (serverCopy != null) ...<Widget>[SizedBox(height: gap), serverCopy],
        if (transfer != null) ...<Widget>[SizedBox(height: gap), transfer],
        SizedBox(height: gap * 2),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FushiFilledButton.tonalIcon(
            key: ValueKey<String>('dict-detail-delete-${dictionary.name}'),
            onPressed: onDelete,
            style: FilledButton.styleFrom(
              foregroundColor: fushiStatusColor(context, FushiStatusTone.error),
            ),
            icon: const FushiIcon(Icons.delete_outline, size: 18),
            label: Text(t.options_delete),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          dictionary.effectiveDisplayName,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w600,
            color: enabled ? scheme.onSurface : scheme.onSurfaceVariant,
          ),
        ),
        SizedBox(height: tokens.spacing.gap),
        Wrap(
          spacing: tokens.spacing.gap / 2,
          runSpacing: tokens.spacing.gap / 2,
          children: <Widget>[
            FushiTag(text: typeLabel, tone: FushiTagTone.accent, dense: true),
            if (dictionary.isUpdatable)
              FushiTag(
                text: t.dict_detail_source_online,
                icon: Icons.cloud_done_outlined,
                tone: FushiTagTone.neutral,
                dense: true,
              ),
            ...headerTags,
            if (!enabled)
              FushiTag(
                text: t.dict_status_disabled,
                tone: FushiTagTone.warning,
                dense: true,
              ),
          ],
        ),
      ],
    );
  }

  /// 改名 / 内容语言 / 更新：一排三等分的 tonal 动作块（图标在上、文字在下，
  /// M3 Expressive 的按钮组形态），一步可达——以前是行尾一串无字图标。
  Widget _buildQuickActions(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: _QuickActionTile(
            key: ValueKey<String>('dict-detail-rename-${dictionary.name}'),
            icon: Icons.drive_file_rename_outline,
            label: t.dict_rename,
            onTap: onRename,
          ),
        ),
        SizedBox(width: tokens.spacing.gap),
        Expanded(
          child: _QuickActionTile(
            key: ValueKey<String>('dict-detail-language-${dictionary.name}'),
            icon: Icons.translate,
            label: t.dict_language_tooltip,
            onTap: onLanguage,
          ),
        ),
        SizedBox(width: tokens.spacing.gap),
        Expanded(
          child: FushiTooltip(
            // 不可在线更新的词典点下去是「选本地文件覆盖」，提示要说在前头。
            message: dictionary.isUpdatable
                ? t.dict_update_tooltip
                : t.dict_update_from_file_tooltip,
            child: _QuickActionTile(
              key: ValueKey<String>('dict-detail-update-${dictionary.name}'),
              icon: Icons.system_update_alt,
              label: t.dict_update_tooltip,
              onTap: onUpdate,
            ),
          ),
        ),
      ],
    );
  }

  Widget _infoRow(BuildContext context, String label, String value) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return AdaptiveSettingsRow(
      title: label,
      trailingFlexible: true,
      trailing: Text(
        value,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.end,
        style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }
}

/// 「排序」分组：第 n / m 位 + 置顶 / 上移 / 下移 / 置底 + 移到第几位。本机词典与
/// 服务器词典的详情共用这一份（排序在同一条混排列表里进行）。
class DictionaryOrderSection extends StatelessWidget {
  const DictionaryOrderSection({
    required this.position,
    required this.count,
    required this.onMoveTo,
    required this.onMoveToPrompt,
    super.key,
  });

  /// 在语言组里的下标（0 起）与组内本数。
  final int position;
  final int count;
  final ValueChanged<int> onMoveTo;
  final VoidCallback onMoveToPrompt;

  @override
  Widget build(BuildContext context) {
    final bool first = position <= 0;
    final bool last = position >= count - 1;
    return AdaptiveSettingsSection(
      title: t.dict_detail_order_section,
      children: <Widget>[
        AdaptiveSettingsRow(
          key: const ValueKey<String>('dict-detail-position'),
          title: t.dict_detail_order_position(n: position + 1, m: count),
          icon: Icons.low_priority,
          showIcon: true,
          // 点「第 n / m 位」本身也是「移到第几位」。
          onTap: count > 1 ? onMoveToPrompt : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FushiIconButton(
                key: const ValueKey<String>('dict-detail-move-top'),
                icon: Icons.vertical_align_top,
                tooltip: t.dict_order_top_move,
                enabled: !first,
                onTap: () => onMoveTo(0),
              ),
              FushiIconButton(
                key: const ValueKey<String>('dict-detail-move-up'),
                icon: Icons.keyboard_arrow_up,
                tooltip: t.move_up,
                enabled: !first,
                onTap: () => onMoveTo(position - 1),
              ),
              FushiIconButton(
                key: const ValueKey<String>('dict-detail-move-down'),
                icon: Icons.keyboard_arrow_down,
                tooltip: t.move_down,
                enabled: !last,
                onTap: () => onMoveTo(position + 1),
              ),
              FushiIconButton(
                key: const ValueKey<String>('dict-detail-move-bottom'),
                icon: Icons.vertical_align_bottom,
                tooltip: t.dict_order_bottom_move,
                enabled: !last,
                onTap: () => onMoveTo(count - 1),
              ),
            ],
          ),
        ),
        AdaptiveSettingsRow(
          key: const ValueKey<String>('dict-detail-move-to'),
          title: t.dict_order_position_move,
          icon: Icons.format_list_numbered,
          showIcon: true,
          onTap: count > 1 ? onMoveToPrompt : null,
        ),
      ],
    );
  }
}

/// 详情顶部的动作块：可点的 tonal 卡（按下下沉 / 悬停轻抬），图标在上文字在下。
class _QuickActionTile extends StatelessWidget {
  const _QuickActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    return FushiHoverLift(
      scale: 1.03,
      builder: (BuildContext context, bool hovering) => FushiCard(
        color: tokens.surfaces.selected,
        onTap: onTap,
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.gap,
          vertical: tokens.spacing.rowVertical,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FushiIcon(icon, size: 22, color: scheme.onSecondaryContainer),
            SizedBox(height: tokens.spacing.gap / 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: textTheme.labelLarge?.copyWith(
                color: scheme.onSecondaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一类词典的计数（概览面板的一格）。
class DictionaryTypeCount {
  const DictionaryTypeCount({
    required this.type,
    required this.label,
    required this.icon,
    required this.total,
    required this.enabled,
    this.onServer = 0,
  });

  final DictionaryType type;
  final String label;
  final IconData icon;

  /// 列表里这一类的行数（本机词典 + 只在服务器上的词典）。
  final int total;
  final int enabled;

  /// 其中只在服务器上的行数（与本机同名的服务器词典算本机那一行，不重复计）。
  final int onServer;

  /// 其中本机已安装的行数。
  int get onDevice => total - onServer;
}

/// 宽屏详情侧板在「还没选中任何词典」时的内容：四类词典的计数格（点一下切到
/// 那一类）、选择提示，以及页面交进来的设置区（自动更新）。
class DictionaryManagerOverview extends StatelessWidget {
  const DictionaryManagerOverview({
    required this.counts,
    required this.totalDictionaries,
    required this.enabledDictionaries,
    required this.selectedType,
    required this.onTypeSelected,
    required this.footer,
    super.key,
  });

  final List<DictionaryTypeCount> counts;

  /// 已装词典的本数 / 其中参与查词的本数。
  final int totalDictionaries;
  final int enabledDictionaries;
  final DictionaryType selectedType;
  final ValueChanged<DictionaryType> onTypeSelected;
  final Widget footer;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double gap = tokens.spacing.gap;
    // 总数按全部已装词典计（页面直接从词典仓库数），不在这里把四格相加。
    final int all = totalDictionaries;
    final int allEnabled = enabledDictionaries;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          t.dict_overview_title,
          style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        SizedBox(height: gap / 2),
        Text(
          t.dict_manager_summary(n: all, m: allEnabled),
          style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        SizedBox(height: gap * 2),
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final double cellWidth = (constraints.maxWidth - gap) / 2;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: <Widget>[
                for (final DictionaryTypeCount count in counts)
                  SizedBox(
                    width: cellWidth,
                    child: _DictionaryTypeTile(
                      count: count,
                      selected: count.type == selectedType,
                      onTap: () => onTypeSelected(count.type),
                    ),
                  ),
              ],
            );
          },
        ),
        SizedBox(height: gap * 3),
        Row(
          children: <Widget>[
            FushiIcon(
              Icons.touch_app_outlined,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
            SizedBox(width: gap),
            Expanded(
              child: Text(
                t.dict_detail_placeholder,
                style: textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        footer,
      ],
    );
  }
}

class _DictionaryTypeTile extends StatelessWidget {
  const _DictionaryTypeTile({
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final DictionaryTypeCount count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 悬停轻抬 + 按下下沉：计数格是可点的卡（点一下切到那一类）。
    return FushiHoverLift(
      scale: 1.02,
      builder: (BuildContext context, bool hovering) => FushiCard(
        key: ValueKey<String>('dict-overview-type-${count.type.name}'),
        selected: selected,
        onTap: onTap,
        padding: EdgeInsets.all(tokens.spacing.rowHorizontal),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FushiIcon(count.icon, size: 20, color: scheme.primary),
            SizedBox(height: tokens.spacing.gap),
            Text(
              '${count.total}',
              style: textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              count.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            // 有服务器词典时才分开计：没配服务器的用户这一行纯属噪音。
            if (count.onServer > 0)
              Text(
                '${t.dictionary_overview_on_device(n: count.onDevice)} · '
                '${t.dictionary_overview_on_server(n: count.onServer)}',
                key: ValueKey<String>(
                  'dict-overview-sources-${count.type.name}',
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 一本词典都没有时的整页空状态：说明支持的格式，并把「导入」「下载推荐」
/// 两个入口直接放在眼前（以前空状态只有一句话，入口要去页头找）。
class DictionaryManagerEmptyState extends StatelessWidget {
  const DictionaryManagerEmptyState({
    required this.icon,
    required this.onImport,
    required this.onDownload,
    required this.showDropHint,
    super.key,
  });

  final IconData icon;
  final VoidCallback onImport;
  final VoidCallback onDownload;
  final bool showDropHint;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(
        vertical: tokens.spacing.section,
        horizontal: tokens.spacing.page,
      ),
      child: FushiPlaceholderMessage(
        icon: icon,
        message: t.dictionaries_menu_empty,
        detail: t.dict_empty_hint,
        details: <String>[if (showDropHint) t.dict_empty_drop_hint],
        action: Wrap(
          alignment: WrapAlignment.center,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            FushiPressScale(
              child: FushiFilledButton.icon(
                key: const ValueKey<String>('dict-empty-import'),
                onPressed: onImport,
                icon: const FushiIcon(Icons.upload_file_outlined, size: 18),
                label: Text(t.dialog_import_dictionary),
              ),
            ),
            FushiPressScale(
              child: FushiFilledButton.tonalIcon(
                key: const ValueKey<String>('dict-empty-download'),
                onPressed: onDownload,
                icon: const FushiIcon(Icons.cloud_download_outlined, size: 18),
                label: Text(t.dict_download_browse),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 把用户输入的位置文本解析成 1 起的位置，并夹进 `1..count`。
///
/// - 空 / 非数字 → null（确认键置灰，回车不提交）；
/// - 越界 → 夹到最近的端点（输 0 = 第 1 位，输 99 = 最后一位），对话框里会
///   提示「将移到第 n 位」，不静默改值。
@visibleForTesting
int? parseDictionaryPosition(String text, int count) {
  final int? value = int.tryParse(text.trim());
  if (value == null || count <= 0) return null;
  return value.clamp(1, count);
}

/// 「移到第几位」输入框：数字输入 + 两侧 −/+ 步进（输入框里 ↑/↓ 同样步进），
/// 回车 / 确认提交。返回**最终下标（0 起）**；取消返回 null。
///
/// 外壳与改名框同一套（[FushiDialogFrame] + [FushiModalSheetFrame]），所以 MD3 /
/// Apple 两套设计系统、对话框转场、焦点圈都随共享组件走。
Future<int?> showDictionaryPositionDialog({
  required BuildContext context,
  required String name,
  required int position,
  required int count,
}) {
  return showAppDialog<int>(
    context: context,
    builder: (_) =>
        DictionaryPositionDialog(name: name, position: position, count: count),
  );
}

@visibleForTesting
class DictionaryPositionDialog extends StatefulWidget {
  const DictionaryPositionDialog({
    required this.name,
    required this.position,
    required this.count,
    super.key,
  });

  final String name;

  /// 当前下标（0 起）与本类型词典总数。
  final int position;
  final int count;

  @override
  State<DictionaryPositionDialog> createState() =>
      _DictionaryPositionDialogState();
}

class _DictionaryPositionDialogState extends State<DictionaryPositionDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: '${widget.position + 1}',
  );

  @override
  void initState() {
    super.initState();
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _controller.text.length,
    );
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  int? get _parsed => parseDictionaryPosition(_controller.text, widget.count);

  bool get _clamped {
    final int? raw = int.tryParse(_controller.text.trim());
    final int? parsed = _parsed;
    return raw != null && parsed != null && raw != parsed;
  }

  void _step(int delta) {
    final int base = _parsed ?? widget.position + 1;
    final int next = (base + delta).clamp(1, widget.count);
    _controller.value = TextEditingValue(
      text: '$next',
      selection: TextSelection.collapsed(offset: '$next'.length),
    );
  }

  void _submit() {
    final int? target = _parsed;
    if (target == null) return;
    Navigator.pop(context, target - 1);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _step(1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _step(-1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    final int? parsed = _parsed;
    return FushiDialogFrame(
      maxWidth: 380,
      maxHeightFactor: 0.74,
      scrollable: false,
      child: FushiModalSheetFrame(
        title: t.dict_order_position_title,
        subtitle: widget.name,
        leadingIcon: Icons.format_list_numbered,
        scrollable: true,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                FushiIconButton(
                  key: const ValueKey<String>('dict-position-dec'),
                  icon: Icons.remove,
                  tooltip: t.move_up,
                  enabled: (parsed ?? 1) > 1,
                  onTap: () => _step(-1),
                ),
                SizedBox(width: tokens.spacing.gap),
                Expanded(
                  child: Focus(
                    canRequestFocus: false,
                    skipTraversal: true,
                    onKeyEvent: _onKey,
                    child: FushiTextField(
                      key: const ValueKey<String>('dict-position-field'),
                      controller: _controller,
                      labelText: t.dict_order_position_label(m: widget.count),
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.done,
                      autofocus: true,
                      onSubmitted: (_) => _submit(),
                    ),
                  ),
                ),
                SizedBox(width: tokens.spacing.gap),
                FushiIconButton(
                  key: const ValueKey<String>('dict-position-inc'),
                  icon: Icons.add,
                  tooltip: t.move_down,
                  enabled: (parsed ?? widget.count) < widget.count,
                  onTap: () => _step(1),
                ),
              ],
            ),
            // 越界提示：淡入 + 高度展开（时长取 FushiMotion，减弱动态效果下归零）。
            AnimatedSize(
              duration: fushiMotionDuration(context, FushiMotion.short),
              curve: FushiMotion.standard,
              child: AnimatedOpacity(
                duration: fushiMotionDuration(context, FushiMotion.short),
                opacity: _clamped ? 1 : 0,
                child: _clamped
                    ? Padding(
                        padding: EdgeInsets.only(top: tokens.spacing.gap),
                        child: Text(
                          t.dict_order_position_clamped(n: parsed!),
                          style: textTheme.bodySmall?.copyWith(
                            color: fushiStatusColor(
                              context,
                              FushiStatusTone.warning,
                            ),
                          ),
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ),
          ],
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context),
              child: Text(t.dialog_cancel),
            ),
            adaptiveDialogAction(
              context: context,
              isDefaultAction: true,
              onPressed: parsed == null ? null : _submit,
              child: Text(t.dialog_ok),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 服务器托管词典：与本机词典同一条按语言分组的混排列表 ─────────────────
//
// 服务器词典（[RemoteDictionary]，`remote_dictionary_metadata`）不下载到本机，
// 但与本机词典共用一条查词优先级（同一数轴的 `order`，见
// `DictionaryRepository.lookupFiltersOf`）。管理页因此只有一条列表：每行是本机
// 词典或服务器词典，按「有效语言」分组、组内可拖动，来源只在行内的标签里说明
// ——不分「已安装 / 服务器上」两段。

/// 一行词典的来源（行副标题里的来源标签）。
enum DictionarySourceKind {
  /// 只在本机。
  thisDevice,

  /// 只在服务器上（查词时由那台服务器查）。
  server,

  /// 本机装了，服务器上也有同名的一本：本机这行说了算，标签只是告知。
  both,

  /// 服务器目录里已经没有了（设置保留，回来时原样生效）。
  missing,
}

/// 服务器行 [DictionaryManagerRow.key] 的前缀。
const String kDictionaryManagerServerKeyPrefix = 'server:';

/// 词典管理页列表里的一行：一本本机词典，或一本只在服务器上的词典。
@immutable
class DictionaryManagerRow {
  /// 本机词典行；[alsoOnHosts] 是目录里也有同名词典（且没缺席）的 host。
  const DictionaryManagerRow.local(
    Dictionary this.local, {
    this.alsoOnHosts = const <String>{},
  }) : remote = null;

  /// 只在服务器上的词典行。
  const DictionaryManagerRow.remote(RemoteDictionary this.remote)
    : local = null,
      alsoOnHosts = const <String>{};

  final Dictionary? local;
  final RemoteDictionary? remote;
  final Set<String> alsoOnHosts;

  bool get isRemote => remote != null;

  /// 列表 / 焦点 / 详情里的身份。本机行用真名（与改造前逐字一致），服务器行加前缀
  /// 带上 host，免得与本机真名或另一台 host 的同名词典撞键。
  String get key {
    final Dictionary? l = local;
    if (l != null) return l.name;
    return '$kDictionaryManagerServerKeyPrefix${remote!.key}';
  }

  /// 用户可见的名字：本机走 effectiveDisplayName；服务器行是本机起的名（v150）>
  /// host 报的展示名 > 真名（[RemoteDictionary.effectiveDisplayName]）。
  String get displayName {
    final Dictionary? l = local;
    if (l != null) return l.effectiveDisplayName;
    return remote!.effectiveDisplayName;
  }

  DictionarySourceKind get source {
    final RemoteDictionary? r = remote;
    if (r != null) {
      return r.isMissing
          ? DictionarySourceKind.missing
          : DictionarySourceKind.server;
    }
    return alsoOnHosts.isEmpty
        ? DictionarySourceKind.thisDevice
        : DictionarySourceKind.both;
  }

  /// 归哪个语言组：本机行同 [dictionaryLanguageGroupOf]（手动指定优先），服务器
  /// 行按 host 报的 `sourceLanguage`，同一套规范化（[canonicalDictionaryLanguageTag]）。
  String? get languageGroup {
    final Dictionary? l = local;
    if (l != null) return dictionaryLanguageGroupOf(l);
    return canonicalDictionaryLanguageTag(remote!.sourceLanguage);
  }
}

/// 一个分区（某一类词典）的混排行：本机分区（已按分区顺序排好）与参与查词的服务器
/// 词典按 `order` 归并，同序号本机在前——与 `DictionaryRepository` 的查词混排同一
/// 规则，所以列表顺序就是查词顺序。
///
/// * 服务器行只取类型是 [sectionType] 的；
/// * 与**任何**本机词典同名的服务器行不单独成行（本机那本遮住它，本机行标「两者」）；
/// * 多台 host 同名只留排得最前的一行（查词名单里一个名字只出现一次）。
///
/// [localOrder] 给出本机行在这个分区里的序号。
List<DictionaryManagerRow> mixDictionaryManagerRows({
  required List<Dictionary> localSection,
  required Iterable<Dictionary> allLocal,
  required List<RemoteDictionary> remote,
  required DictionaryType sectionType,
  required int Function(Dictionary dictionary) localOrder,
}) {
  final Map<String, Set<String>> hostsByName = <String, Set<String>>{};
  for (final RemoteDictionary r in remote) {
    if (r.isMissing) continue;
    hostsByName.putIfAbsent(r.name, () => <String>{}).add(r.hostId);
  }
  // 成员规则与仓库的分区重编号同一份：列表上画出来的服务器行就是写回时重编号的行。
  final List<RemoteDictionary> serverOnly =
      DictionaryRepository.serverOnlySectionRows(
        allLocal: allLocal,
        remote: remote,
        type: sectionType,
      );
  final List<DictionaryManagerRow> out = <DictionaryManagerRow>[];
  int i = 0;
  int j = 0;
  while (i < localSection.length || j < serverOnly.length) {
    final bool takeLocal =
        j >= serverOnly.length ||
        (i < localSection.length &&
            localOrder(localSection[i]) <= serverOnly[j].order);
    if (takeLocal) {
      final Dictionary d = localSection[i++];
      out.add(
        DictionaryManagerRow.local(
          d,
          alsoOnHosts: hostsByName[d.name] ?? const <String>{},
        ),
      );
    } else {
      out.add(DictionaryManagerRow.remote(serverOnly[j++]));
    }
  }
  return out;
}

/// 一组混排行（同一「有效语言」）。
class DictionaryManagerLanguageGroup {
  const DictionaryManagerLanguageGroup({
    required this.language,
    required this.rows,
  });

  /// 规范化语言标签；null = 「未标注语言」组。
  final String? language;
  final List<DictionaryManagerRow> rows;
}

/// 混排行按语言分组：与 [groupDictionariesByLanguage] 同一规则（组序按首次出现、
/// 「未标注语言」组放最后、组内保持分区顺序），服务器行按 `sourceLanguage` 参与。
List<DictionaryManagerLanguageGroup> groupDictionaryManagerRowsByLanguage(
  List<DictionaryManagerRow> section,
) {
  final Map<String, List<DictionaryManagerRow>> labelled =
      <String, List<DictionaryManagerRow>>{};
  final List<DictionaryManagerRow> unlabelled = <DictionaryManagerRow>[];
  for (final DictionaryManagerRow row in section) {
    final String? language = row.languageGroup;
    if (language == null) {
      unlabelled.add(row);
    } else {
      labelled.putIfAbsent(language, () => <DictionaryManagerRow>[]).add(row);
    }
  }
  return <DictionaryManagerLanguageGroup>[
    for (final MapEntry<String, List<DictionaryManagerRow>> e
        in labelled.entries)
      DictionaryManagerLanguageGroup(language: e.key, rows: e.value),
    if (unlabelled.isNotEmpty)
      DictionaryManagerLanguageGroup(language: null, rows: unlabelled),
  ];
}

/// [section] 里与 [row] 同语言组的全部行（分区顺序）。
List<DictionaryManagerRow> dictionaryManagerLanguageGroupOf(
  List<DictionaryManagerRow> section,
  DictionaryManagerRow row,
) {
  final String? language = row.languageGroup;
  return <DictionaryManagerRow>[
    for (final DictionaryManagerRow r in section)
      if (r.languageGroup == language) r,
  ];
}

/// 把 [section] 里键为 [key] 的行挪到它所在语言组的最终下标 [to]（钳到组两端），
/// 返回整个分区的新规范顺序（各组首尾相接，同 [moveDictionaryWithinLanguageGroup]）。
/// null = 不用写（行已不在分区里，或位置不变）。调用方按返回下标重编号。
List<DictionaryManagerRow>? moveDictionaryManagerRowWithinLanguageGroup(
  List<DictionaryManagerRow> section,
  String key,
  int to,
) {
  final int index = section.indexWhere(
    (DictionaryManagerRow r) => r.key == key,
  );
  if (index < 0) return null;
  final DictionaryManagerRow moved = section[index];
  final List<DictionaryManagerRow> group = dictionaryManagerLanguageGroupOf(
    section,
    moved,
  );
  final int from = group.indexOf(moved);
  final int target = to.clamp(0, group.length - 1);
  if (target == from) return null;
  group
    ..removeAt(from)
    ..insert(target, moved);
  final String? language = moved.languageGroup;
  return <DictionaryManagerRow>[
    for (final DictionaryManagerLanguageGroup g
        in groupDictionaryManagerRowsByLanguage(section))
      ...(g.language == language ? group : g.rows),
  ];
}

/// 列表上方来源筛选的种类。
enum DictionarySourceFilterKind { all, thisDevice, server, hidden }

/// 来源筛选的一个选项：全部 / 本机 / 某台服务器 / 已隐藏。
@immutable
class DictionarySourceFilter {
  const DictionarySourceFilter._(this.kind) : hostId = null;

  /// 某台服务器（`remoteDictionaryHostIdOf` 口径的 host 身份）。
  const DictionarySourceFilter.server(String this.hostId)
    : kind = DictionarySourceFilterKind.server;

  static const DictionarySourceFilter all = DictionarySourceFilter._(
    DictionarySourceFilterKind.all,
  );
  static const DictionarySourceFilter thisDevice = DictionarySourceFilter._(
    DictionarySourceFilterKind.thisDevice,
  );
  static const DictionarySourceFilter hidden = DictionarySourceFilter._(
    DictionarySourceFilterKind.hidden,
  );

  final DictionarySourceFilterKind kind;
  final String? hostId;

  /// 这一行在这个筛选下是否显示。[enabled] 是这一行在当前分区的开关状态。
  bool matches(DictionaryManagerRow row, {required bool enabled}) =>
      switch (kind) {
        DictionarySourceFilterKind.all => true,
        DictionarySourceFilterKind.thisDevice => !row.isRemote,
        // 「两者」行也在那台服务器上：按服务器筛时一并列出。
        DictionarySourceFilterKind.server =>
          row.remote?.hostId == hostId || row.alsoOnHosts.contains(hostId),
        DictionarySourceFilterKind.hidden => !enabled,
      };

  /// 筛选键（ValueKey 后缀）。
  String get id =>
      kind == DictionarySourceFilterKind.server ? 'server-$hostId' : kind.name;

  @override
  bool operator ==(Object other) =>
      other is DictionarySourceFilter &&
      other.kind == kind &&
      other.hostId == hostId;

  @override
  int get hashCode => Object.hash(kind, hostId);
}

/// 行副标题里的来源标签——只给**例外状态**画文字 chip（设计稿 6 降噪）：
/// 「两者」「服务器上已没有」「旧版服务器」（那台 host 上次查词没套用本端发去的词典
/// 选择）。只在本机的行不画；只在服务器上的行由序号徽标上的服务器小图标说明
/// （[DictionaryOrderBadge.serverHostName]），这里不再重复一枚「服务器 · 名字」。
///
/// [showHostName]：配对了两台及以上参与查词的 host 时才把设备名写进 chip 文字，
/// 只有一台时名字只进 tooltip。
class DictionarySourceChip extends StatelessWidget {
  const DictionarySourceChip({
    required this.kind,
    required this.hostName,
    this.showHostName = false,
    this.olderHost = false,
    super.key,
  });

  final DictionarySourceKind kind;
  final String hostName;
  final bool showHostName;

  /// 服务器行所在 host 上次查词忽略了本端的词典选择（老版本）。
  final bool olderHost;

  /// 这一行此刻要不要画 chip（不画时调用方省掉间距）。
  static bool shows(DictionarySourceKind kind, {required bool olderHost}) =>
      switch (kind) {
        DictionarySourceKind.thisDevice => false,
        DictionarySourceKind.server => olderHost,
        DictionarySourceKind.both || DictionarySourceKind.missing => true,
      };

  @override
  Widget build(BuildContext context) {
    final (String, IconData, FushiTagTone)? spec = switch (kind) {
      DictionarySourceKind.thisDevice => null,
      DictionarySourceKind.server =>
        olderHost
            ? (
                showHostName
                    ? t.dictionary_source_older_server_named(name: hostName)
                    : t.dictionary_source_older_server,
                FushiIcons.warning,
                FushiTagTone.warning,
              )
            : null,
      DictionarySourceKind.both => (
        showHostName
            ? t.dictionary_source_both_named(name: hostName)
            : t.dictionary_source_both,
        FushiIcons.cloudSync,
        FushiTagTone.neutral,
      ),
      DictionarySourceKind.missing => (
        showHostName
            ? t.dictionary_source_missing_named(name: hostName)
            : t.dictionary_source_missing,
        FushiIcons.cloudOff,
        FushiTagTone.warning,
      ),
    };
    if (spec == null) return const SizedBox.shrink();
    final (String text, IconData icon, FushiTagTone tone) = spec;
    return FushiTag(
      text: text,
      icon: icon,
      tone: tone,
      dense: true,
      message: switch (kind) {
        DictionarySourceKind.both => t.dictionary_source_both_tooltip(
          name: hostName,
        ),
        DictionarySourceKind.server => t.dictionary_server_older_host(
          name: hostName,
        ),
        _ => null,
      },
    );
  }
}

/// 列表上方的来源筛选条：全部 / 本机 / 每台服务器一枚 / 已隐藏；有两台及以上服务器
/// 时行尾多一个「刷新全部服务器词典」（单台的刷新住在它的来源卡片上，不重复给）。
/// 单选 chip（按下下沉），放不下时横向滚动。
class DictionarySourceFilterBar extends StatelessWidget {
  const DictionarySourceFilterBar({
    required this.hosts,
    required this.selected,
    required this.onSelected,
    required this.onRefresh,
    required this.refreshing,
    super.key,
  });

  /// host 身份 → 展示名，按显示顺序。
  final Map<String, String> hosts;
  final DictionarySourceFilter selected;
  final ValueChanged<DictionarySourceFilter> onSelected;

  /// 「刷新全部服务器词典」；null = 不给这个钮（弹窗进程没有目录服务，或只有一台
  /// 服务器——它的来源卡片上已有刷新）。
  final VoidCallback? onRefresh;
  final bool refreshing;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<(DictionarySourceFilter, String)> options =
        <(DictionarySourceFilter, String)>[
          (DictionarySourceFilter.all, t.dictionary_filter_all),
          (DictionarySourceFilter.thisDevice, t.dictionary_source_this_device),
          for (final MapEntry<String, String> h in hosts.entries)
            (
              DictionarySourceFilter.server(h.key),
              t.dictionary_source_server(name: h.value),
            ),
          (DictionarySourceFilter.hidden, t.dictionary_filter_hidden),
        ];
    final VoidCallback? refresh = onRefresh;
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.spacing.gap),
      child: Row(
        children: <Widget>[
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  for (final (DictionarySourceFilter filter, String label)
                      in options)
                    Padding(
                      padding: EdgeInsetsDirectional.only(
                        end: tokens.spacing.gap / 2,
                      ),
                      child: FushiPressScale(
                        child: FushiChoiceChip(
                          key: ValueKey<String>(
                            'dict-source-filter-${filter.id}',
                          ),
                          label: Text(label),
                          selected: filter == selected,
                          onSelected: (bool _) {
                            if (filter != selected) onSelected(filter);
                          },
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (refresh != null)
            FushiIconButton(
              key: const ValueKey<String>('dict-server-refresh'),
              icon: FushiIcons.refresh,
              tooltip: t.dictionary_server_refresh,
              enabled: !refreshing,
              onTap: refresh,
            ),
        ],
      ),
    );
  }
}

/// 「来源」条上一台 host 的一张卡片的数据（页面算好交进来，组件不碰数据层）。
@immutable
class DictionaryServerSourceCard {
  const DictionaryServerSourceCard({
    required this.hostId,
    required this.name,
    required this.status,
    required this.enabled,
    required this.total,
    required this.lookupEnabled,
    required this.olderHost,
    required this.refreshing,
  });

  final String hostId;
  final String name;

  /// 状态行：在线 / 最近在线 <时刻> / 自 <时刻> 起连不上。
  final String status;

  /// 当前分区里这台 host 上启用 / 全部的词典本数（已缺席的不算）。
  final int enabled;
  final int total;

  /// 「用这台服务器查词典」。
  final bool lookupEnabled;

  /// 这台 host 上次查词没有套用本端发去的词典选择（老版本）。
  final bool olderHost;
  final bool refreshing;
}

/// 列表上方的「来源」条（设计稿 6，取代以前列表底部按 host 的提示）：每台有目录的
/// host 一行紧凑卡片——设备名、状态、当前分区的启用 / 全部本数、「用于查词」开关
/// （与配对设置页同一个写入口，也是远端词典查词唯一的开关）、刷新；老版本 host、
/// 关掉「用于查词」的 host 各多一行说明。
///
/// 关掉「用于查词」的 host 的词典根本不在列表里，它那张卡片自己说「不参与查词、
/// 不列出」并给「开启」（就是拨这台 host 的开关）。
///
/// 卡片竖排、首次出现错峰淡入。
class DictionaryServerSourcesStrip extends StatelessWidget {
  const DictionaryServerSourcesStrip({
    required this.cards,
    required this.onLookupChanged,
    required this.onRefresh,
    super.key,
  });

  final List<DictionaryServerSourceCard> cards;
  final void Function(String hostId, bool enabled) onLookupChanged;

  /// 刷新一台 host 的目录；null = 没有目录服务（弹窗进程），不给刷新钮。
  final void Function(String hostId)? onRefresh;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double gap = tokens.spacing.gap;
    return Padding(
      padding: EdgeInsets.only(bottom: gap),
      child: FushiEntranceScope(
        replayKey: 'dict-server-sources',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (int i = 0; i < cards.length; i++)
              Padding(
                padding: EdgeInsets.only(
                  bottom: i == cards.length - 1 ? 0 : gap / 2,
                ),
                child: FushiStaggeredEntrance(
                  index: i,
                  child: _DictionaryServerSourceCardView(
                    card: cards[i],
                    onLookupChanged: onLookupChanged,
                    onRefresh: onRefresh,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 宽于这个值时来源卡片排成一行；更窄时折成两行（名字 + 刷新 / 状态 + 开关）。
const double _kSourceCardSingleLineMinWidth = 560;

class _DictionaryServerSourceCardView extends StatelessWidget {
  const _DictionaryServerSourceCardView({
    required this.card,
    required this.onLookupChanged,
    required this.onRefresh,
  });

  final DictionaryServerSourceCard card;
  final void Function(String hostId, bool enabled) onLookupChanged;
  final void Function(String hostId)? onRefresh;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double gap = tokens.spacing.gap;
    final void Function(String hostId)? refresh = onRefresh;
    final TextStyle? meta = textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final Color warning = fushiStatusColor(context, FushiStatusTone.warning);

    final Widget glyph = FushiIcon(
      FushiIcons.server,
      size: 18,
      color: scheme.primary,
    );
    final Widget name = Text(
      card.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
    );
    final Widget metaLine = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Flexible(
          child: Text(
            card.status,
            key: ValueKey<String>('dict-server-source-status-${card.hostId}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: meta,
          ),
        ),
        Text(' · ', style: meta),
        Flexible(
          child: Text(
            t.dictionary_source_counts(m: card.enabled, n: card.total),
            key: ValueKey<String>('dict-server-source-counts-${card.hostId}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: meta,
          ),
        ),
      ],
    );
    final Widget lookupSwitch = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          t.dictionary_source_use_for_lookups,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: textTheme.bodyMedium,
        ),
        SizedBox(width: gap),
        Semantics(
          toggled: card.lookupEnabled,
          label: t.dictionary_source_use_for_lookups,
          child: FushiSwitch(
            key: ValueKey<String>('dict-server-source-lookup-${card.hostId}'),
            value: card.lookupEnabled,
            onChanged: (bool value) => onLookupChanged(card.hostId, value),
          ),
        ),
      ],
    );
    final List<Widget> refreshButton = <Widget>[
      if (refresh != null)
        FushiIconButton(
          key: ValueKey<String>('dict-server-source-refresh-${card.hostId}'),
          icon: FushiIcons.refresh,
          size: 20,
          tooltip: t.interconnect_dictionaries_refresh,
          enabled: !card.refreshing,
          onTap: () => refresh(card.hostId),
        ),
    ];

    return FushiHoverLift(
      scale: 1.005,
      builder: (BuildContext context, bool hovering) => FushiCard(
        key: ValueKey<String>('dict-server-source-${card.hostId}'),
        padding: EdgeInsets.fromLTRB(gap * 1.5, gap / 2, gap / 2, gap / 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                if (constraints.maxWidth >= _kSourceCardSingleLineMinWidth) {
                  return Row(
                    children: <Widget>[
                      glyph,
                      SizedBox(width: gap / 2),
                      Flexible(child: name),
                      SizedBox(width: gap),
                      Expanded(child: metaLine),
                      SizedBox(width: gap),
                      lookupSwitch,
                      ...refreshButton,
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        glyph,
                        SizedBox(width: gap / 2),
                        Expanded(child: name),
                        ...refreshButton,
                      ],
                    ),
                    Row(
                      children: <Widget>[
                        Expanded(child: metaLine),
                        SizedBox(width: gap),
                        lookupSwitch,
                      ],
                    ),
                  ],
                );
              },
            ),
            if (card.olderHost)
              _SourceCardNote(
                key: ValueKey<String>(
                  'dict-server-source-older-${card.hostId}',
                ),
                icon: FushiIcons.warning,
                color: warning,
                message: t.dictionary_server_older_host(name: card.name),
              ),
            if (!card.lookupEnabled)
              _SourceCardNote(
                key: ValueKey<String>(
                  'dict-server-source-lookup-off-${card.hostId}',
                ),
                icon: FushiIcons.info,
                color: scheme.onSurfaceVariant,
                message: t.dictionary_source_lookup_off_hint,
                action: FushiTextButton(
                  key: ValueKey<String>(
                    'dict-server-source-lookup-turn-on-${card.hostId}',
                  ),
                  onPressed: () => onLookupChanged(card.hostId, true),
                  child: Text(t.dictionary_remote_lookup_turn_on),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 来源卡片主行下面的一行说明（老版本警告 / 不参与查词），可带一个动作。
class _SourceCardNote extends StatelessWidget {
  const _SourceCardNote({
    required this.icon,
    required this.color,
    required this.message,
    this.action,
    super.key,
  });

  final IconData icon;
  final Color color;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final double gap = FushiDesignTokens.of(context).spacing.gap;
    final TextStyle? style = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: color);
    final Widget? trailing = action;
    return Padding(
      padding: EdgeInsets.only(top: gap / 2, right: gap),
      child: Row(
        children: <Widget>[
          FushiIcon(icon, size: 16, color: color),
          SizedBox(width: gap / 2),
          Expanded(
            child: Text(
              message,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          if (trailing != null) ...<Widget>[SizedBox(width: gap), trailing],
        ],
      ),
    );
  }
}

/// 只在服务器上的词典的详情（宽屏侧板 / 窄屏 sheet）：开关、排序、来源 / host /
/// 类型 / 版本 / 最近在线；服务器上已没有的词典多一个「忘掉」。改名、内容语言、
/// 更新、删除文件、CSS 这些要本机目录的动作一律不给。
/// 本机词典详情里的「推送到 <服务器>」分组：每台还缺这本词典的查词 host 一行，
/// 整行可聚焦、Enter / 点按即推送。host 已有同名词典（「两者」行）的不列。
class DictionaryTransferSection extends StatelessWidget {
  const DictionaryTransferSection({
    required this.dictionaryName,
    required this.hosts,
    required this.onPush,
    super.key,
  });

  /// 词典真名（行 key 用）。
  final String dictionaryName;

  /// host 身份 → 展示名，按要列的顺序。
  final Map<String, String> hosts;
  final ValueChanged<String> onPush;

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsSection(
      title: t.dict_transfer_section,
      children: <Widget>[
        for (final MapEntry<String, String> host in hosts.entries)
          AdaptiveSettingsRow(
            key: ValueKey<String>(
              'dict-detail-push-${host.key}-$dictionaryName',
            ),
            title: t.dict_transfer_push_to(name: host.value),
            icon: Icons.upload_outlined,
            showIcon: true,
            onTap: () => onPush(host.key),
          ),
      ],
    );
  }
}

class RemoteDictionaryDetail extends StatelessWidget {
  const RemoteDictionaryDetail({
    required this.row,
    required this.hostName,
    required this.enabled,
    required this.typeLabel,
    required this.lastSeenLabel,
    required this.position,
    required this.count,
    required this.showHeader,
    required this.onEnabledChanged,
    required this.onMoveTo,
    required this.onMoveToPrompt,
    required this.onForget,
    required this.languageLabel,
    required this.onRename,
    this.olderHost = false,
    this.shadowedOnHosts = const <String>[],
    this.onDownload,
    super.key,
  });

  final DictionaryManagerRow row;
  final String hostName;
  final bool enabled;
  final String typeLabel;
  final String lastSeenLabel;

  /// 内容语言，与本机词典详情同一套文案（「自动 · 日本語 (ja)」）。
  final String languageLabel;

  /// 本机显示名（设备本地）：与本机词典同一个改名对话框。
  final VoidCallback onRename;

  /// 这台 host 上次查词忽略了本端的词典选择（老版本）。
  final bool olderHost;

  /// 另有同名词典、被这一行遮住的 host 展示名（列表只列排得最前的一份）。
  final List<String> shadowedOnHosts;
  final int position;
  final int count;
  final bool showHeader;
  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<int> onMoveTo;
  final VoidCallback onMoveToPrompt;

  /// 「忘掉」（只对服务器上已没有的词典给；null = 不给）。
  final VoidCallback? onForget;

  /// 「下载到本机」（只对服务器上还在、本机没有的词典给；null = 不给）。
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double gap = tokens.spacing.gap;
    final RemoteDictionary remote = row.remote!;
    final String revision = remote.revision?.trim() ?? '';
    final VoidCallback? forget = onForget;
    final VoidCallback? download = onDownload;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (showHeader) ...<Widget>[
          Text(
            row.displayName,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
              color: enabled ? scheme.onSurface : scheme.onSurfaceVariant,
            ),
          ),
          SizedBox(height: gap),
          Wrap(
            spacing: gap / 2,
            runSpacing: gap / 2,
            children: <Widget>[
              FushiTag(text: typeLabel, tone: FushiTagTone.accent, dense: true),
              // 详情不是列表：服务器行这里照常写明「服务器 · 名字」。
              if (row.source == DictionarySourceKind.server)
                FushiTag(
                  text: t.dictionary_source_server(name: hostName),
                  icon: FushiIcons.server,
                  tone: FushiTagTone.accent,
                  dense: true,
                ),
              DictionarySourceChip(
                kind: row.source,
                hostName: hostName,
                olderHost: olderHost,
              ),
              if (!enabled)
                FushiTag(
                  text: t.dict_status_disabled,
                  tone: FushiTagTone.warning,
                  dense: true,
                ),
            ],
          ),
          SizedBox(height: gap * 2),
        ],
        Wrap(
          spacing: gap,
          runSpacing: gap,
          children: <Widget>[
            FushiFilledButton.tonalIcon(
              key: ValueKey<String>('dict-detail-rename-${row.key}'),
              onPressed: onRename,
              icon: const FushiIcon(FushiIcons.rename, size: 18),
              label: Text(t.dict_rename),
            ),
            if (download != null)
              FushiFilledButton.tonalIcon(
                key: ValueKey<String>('dict-detail-download-${row.key}'),
                onPressed: download,
                icon: const FushiIcon(Icons.download_outlined, size: 18),
                label: Text(t.dict_transfer_download),
              ),
          ],
        ),
        SizedBox(height: gap),
        AdaptiveSettingsSection(
          title: t.dict_detail_lookup_section,
          children: <Widget>[
            AdaptiveSettingsSwitchRow(
              key: ValueKey<String>('dict-detail-enabled-${row.key}'),
              title: t.options_show,
              icon: FushiIcons.visibility,
              showIcon: true,
              value: enabled,
              onChanged: onEnabledChanged,
            ),
          ],
        ),
        SizedBox(height: gap),
        DictionaryOrderSection(
          position: position,
          count: count,
          onMoveTo: onMoveTo,
          onMoveToPrompt: onMoveToPrompt,
        ),
        SizedBox(height: gap),
        AdaptiveSettingsSection(
          title: t.dict_detail_info_section,
          children: <Widget>[
            _remoteInfoRow(
              context,
              t.dictionary_detail_source_label,
              row.source == DictionarySourceKind.missing
                  ? t.dictionary_source_missing
                  : t.dictionary_source_server(name: hostName),
            ),
            _remoteInfoRow(context, t.dictionary_detail_host_label, hostName),
            _remoteInfoRow(context, t.dict_detail_type_label, typeLabel),
            if (revision.isNotEmpty)
              _remoteInfoRow(context, t.dict_detail_version_label, revision),
            _remoteInfoRow(context, t.dict_language_tooltip, languageLabel),
            _remoteInfoRow(
              context,
              t.dictionary_detail_last_seen_label,
              lastSeenLabel,
            ),
          ],
        ),
        if (shadowedOnHosts.isNotEmpty) ...<Widget>[
          SizedBox(height: gap),
          FushiInlineNotice(
            key: ValueKey<String>('dict-detail-shadowed-${row.key}'),
            icon: FushiIcons.info,
            severity: FushiNoticeSeverity.info,
            message: t.dictionary_detail_shadowed_copy(
              name: shadowedOnHosts.join(', '),
            ),
          ),
        ],
        if (forget != null) ...<Widget>[
          SizedBox(height: gap * 2),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FushiFilledButton.tonalIcon(
              key: ValueKey<String>('dict-detail-forget-${row.key}'),
              onPressed: forget,
              style: FilledButton.styleFrom(
                foregroundColor: fushiStatusColor(
                  context,
                  FushiStatusTone.error,
                ),
              ),
              icon: const FushiIcon(FushiIcons.delete, size: 18),
              label: Text(t.dictionary_server_forget),
            ),
          ),
        ],
      ],
    );
  }

  Widget _remoteInfoRow(BuildContext context, String label, String value) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return AdaptiveSettingsRow(
      title: label,
      trailingFlexible: true,
      trailing: Text(
        value,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.end,
        style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }
}

/// 毫秒时间戳的本地时间文案（与「上次成功检查」同一格式）。
String dictionaryManagerTimestampLabel(int millisecondsSinceEpoch) =>
    DateTime.fromMillisecondsSinceEpoch(
      millisecondsSinceEpoch,
    ).toLocal().toString().split('.').first;
