/// 作品「作品配置」里的组合部分（拍板台 design-combo-node-split 阶段 6，设计 §2.2、§5）：
///
/// * 「最终生效值」表：每一项（叶子）的生效值与它来自哪一层 / 哪份组合（作品 → 媒体类型 →
///   语言 → 默认），越层被忽略的拆分单列原因。
/// * 作品上直接「单独设置」/「恢复继承」：作品层空着时第一次拆会建一个只挂在这部作品上的匿名组合
///   （配置列表不列出）；全部恢复后匿名组合撤掉。作品挂的是普通组合（别的作品也可能用它）时不在这里
///   改，提示去配置管理编辑它。
/// * 「存成组合」：匿名组合改名列进配置列表，别的作品 / 媒体类型 / 语言就能绑它。
library;

import 'package:fushi_core/fushi_core.dart' show ProfileMediaKind, ProfileRow;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/profile/combo/combo_editing.dart';
import 'package:fushi/src/profile/combo/combo_node_widgets.dart';
import 'package:fushi/src/profile/combo/combo_repository.dart';
import 'package:fushi/src/profile/combo/fushi_settings_tree.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/settings/settings_section_footer.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 一部作品的生效值表 + 直接拆分。[revision] 变了就重读（外面改了作品绑定）；作品层绑定被这里改动
/// （第一次拆出匿名组合 / 全部恢复撤掉它）时调 [onBindingChanged]。[onWorkLocalChanged] 报告作品层
/// 此刻是不是匿名组合（外面的绑定列表据此显示「仅此作品」）。
///
/// 编辑动作 [editing] 与配置名输入框 [askName] 由调用方注入（本文件不连视图模型 / AppModel，见
/// [ComboEditing]）。
class WorkComboPanel extends StatefulWidget {
  const WorkComboPanel({
    required this.editing,
    required this.askName,
    required this.bookUid,
    required this.title,
    required this.mediaType,
    required this.languageTag,
    super.key,
    this.revision = 0,
    this.onBindingChanged,
    this.onWorkLocalChanged,
  });

  final ComboEditing editing;

  /// 弹配置名输入框（「存成组合」），初值 `initialName`；取消返回 null。
  final Future<String?> Function(BuildContext context, String initialName)
  askName;

  final String bookUid;

  /// 作品名（匿名组合的名字、「存成组合」的默认名）。
  final String title;
  final ProfileMediaKind? mediaType;
  final String? languageTag;
  final int revision;
  final VoidCallback? onBindingChanged;
  final ValueChanged<bool>? onWorkLocalChanged;

  @override
  State<WorkComboPanel> createState() => _WorkComboPanelState();
}

class _WorkComboPanelState extends State<WorkComboPanel> {
  WorkComboTable? _table;
  bool _busy = false;

  ComboEditing get _vm => widget.editing;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(WorkComboPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) _reload();
  }

  Future<void> _reload() async {
    WorkComboTable? table;
    try {
      table = await _vm.loadWorkComboTable(
        bookUid: widget.bookUid,
        languageTag: widget.languageTag,
        mediaType: widget.mediaType,
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('WorkComboPanel.load', e, stack);
    }
    if (!mounted) return;
    setState(() => _table = table);
    widget.onWorkLocalChanged?.call(table?.workRole == ComboRole.workLocal);
  }

  /// 跑一个改动；返回是否成功（失败已提示并记日志）。
  Future<bool> _run(String tag, Future<void> Function() op) async {
    if (_busy) return false;
    bool ok = false;
    final int? before = _table?.workProfileId;
    setState(() => _busy = true);
    try {
      await op();
      ok = true;
    } catch (e, stack) {
      ErrorLogService.instance.log('WorkComboPanel.$tag', e, stack);
      FushiToast.show(
        msg: t.profile_combo_action_failed,
        severity: ToastSeverity.error,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _reload();
    if (_table?.workProfileId != before) widget.onBindingChanged?.call();
    return ok;
  }

  String _sourceText(WorkComboTable table, String leafId) {
    final ComboSource source = table.stack.settings.sourceOf(leafId);
    final ProfileRow? defaults = table.profiles[table.stack.defaultProfileId];
    if (source.scope == ComboScope.defaults) {
      return t.profile_combo_source_default(name: defaults?.name ?? '');
    }
    final int? id = table.stack.sourceProfileIdOf(leafId);
    final bool workLocal =
        source.scope == ComboScope.work &&
        table.workRole == ComboRole.workLocal;
    return t.profile_combo_source_layer(
      layer: comboLayerLabel(source.scope),
      name: workLocal
          ? t.profile_combo_work_local_label
          : table.profiles[id]?.name ?? '',
    );
  }

  @override
  Widget build(BuildContext context) {
    final WorkComboTable? table = _table;
    if (table == null) return const SizedBox.shrink();
    final List<Widget> blocks = <Widget>[
      AdaptiveSettingsSection(
        key: const ValueKey<String>('work_combo_effective'),
        title: t.profile_combo_effective_title,
        children: <Widget>[
          for (final SettingsNode leaf in fushiSettingsTree.leaves)
            _leafTile(table, leaf),
        ],
      ),
      SettingsSectionFooter(t.profile_combo_effective_hint),
      if (table.stack.settings.ignoredSplits.isNotEmpty)
        SettingsSectionFooter(
          <String>[
            for (final IgnoredSplit s in table.stack.settings.ignoredSplits)
              t.profile_combo_ignored_item(
                leaf: comboLeafLabel(s.leafId),
                layer: comboLayerLabel(s.scope),
                name:
                    table
                        .profiles[table.stack.profileIdByRef[s.comboRef]]
                        ?.name ??
                    '',
              ),
          ].join('\n'),
        ),
      if (!table.canEditOnWork && table.workProfileId != null)
        SettingsSectionFooter(
          t.profile_combo_work_bound_shared(
            name: table.profiles[table.workProfileId]?.name ?? '',
          ),
        ),
      if (table.workRole == ComboRole.workLocal)
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: FushiTextButton(
            key: const ValueKey<String>('work_combo_save_as'),
            onPressed: _busy ? null : _saveAs,
            child: Text(t.profile_combo_work_save_as),
          ),
        ),
    ];
    return FushiEntranceScope(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final (int i, Widget block) in blocks.indexed)
            FushiStaggeredEntrance(index: i, child: block),
        ],
      ),
    );
  }

  Widget _leafTile(WorkComboTable table, SettingsNode leaf) {
    final ComboSource source = table.stack.settings.sourceOf(leaf.id);
    final bool onWork = source.scope == ComboScope.work;
    final bool editable =
        table.canEditOnWork &&
        leaf.diffable &&
        leaf.splittableAt.contains(ComboScope.work);
    final String subtitle =
        leaf.diffable &&
            !leaf.splittableAt.contains(ComboScope.work) &&
            table.canEditOnWork
        ? '${_sourceText(table, leaf.id)}\n${t.profile_combo_not_splittable_work}'
        : _sourceText(table, leaf.id);
    return ComboLeafTile(
      leafId: leaf.id,
      split: source.scope != ComboScope.defaults,
      values: table.stack.settings.leafValues(fushiSettingsTree, leaf.id),
      subtitle: subtitle,
      actionLabel: !editable
          ? null
          : onWork
          ? t.profile_combo_action_restore
          : t.profile_combo_action_split,
      onAction: !editable || _busy
          ? null
          : () => _run(
              onWork ? 'restore' : 'split',
              () => onWork
                  ? _vm.restoreWorkNode(
                      bookUid: widget.bookUid,
                      nodeId: leaf.id,
                    )
                  : _vm.splitWorkNode(
                      bookUid: widget.bookUid,
                      languageTag: widget.languageTag,
                      mediaType: widget.mediaType,
                      nodeId: leaf.id,
                      anonymousName: t.profile_combo_work_anonymous_name(
                        title: widget.title,
                      ),
                    ),
            ),
    );
  }

  Future<void> _saveAs() async {
    final String? name = await widget.askName(context, widget.title);
    if (name == null || name.trim().isEmpty || !mounted) return;
    final bool ok = await _run(
      'saveAs',
      () => _vm.saveWorkComboAs(bookUid: widget.bookUid, name: name.trim()),
    );
    if (ok) {
      widget.onBindingChanged?.call();
      FushiToast.show(msg: t.profile_combo_work_saved);
    }
  }
}
