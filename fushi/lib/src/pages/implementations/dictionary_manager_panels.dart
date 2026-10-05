import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyEvent, KeyRepeatEvent, LogicalKeyboardKey;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/utils.dart';
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
    super.key,
  });

  /// 1 起的序号。
  final int position;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 停用：退成浮起面那一阶的中性底（tokens 色阶，不在页面里自选容器色）。
    final Color fill =
        enabled ? tokens.surfaces.primaryContainer : tokens.surfaces.search;
    final Color ink =
        enabled ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;
    return SizedBox.square(
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
  final ValueChanged<DictionaryCollapseState> onCollapseChanged;
  final VoidCallback onRename;
  final VoidCallback onLanguage;
  final VoidCallback onUpdate;

  /// 移到本类型列表的最终下标（0 起）。
  final ValueChanged<int> onMoveTo;

  /// 「移到第几位」：弹位置输入框（见 [showDictionaryPositionDialog]）。
  final VoidCallback onMoveToPrompt;
  final VoidCallback onDelete;
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double gap = tokens.spacing.gap;
    final bool first = position <= 0;
    final bool last = position >= count - 1;
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
            AdaptiveSettingsSegmentedRow<DictionaryCollapseState>(
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
              onChanged: onCollapseChanged,
            ),
          ],
        ),
        SizedBox(height: gap),
        AdaptiveSettingsSection(
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
  });

  final DictionaryType type;
  final String label;
  final IconData icon;
  final int total;
  final int enabled;
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
            FushiIcon(Icons.touch_app_outlined,
                size: 18, color: scheme.onSurfaceVariant),
            SizedBox(width: gap),
            Expanded(
              child: Text(
                t.dict_detail_placeholder,
                style: textTheme.bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
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
    builder: (_) => DictionaryPositionDialog(
      name: name,
      position: position,
      count: count,
    ),
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
  late final TextEditingController _controller =
      TextEditingController(text: '${widget.position + 1}');

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
