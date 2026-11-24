/// 组合编辑页（拍板台 design-combo-node-split 阶段 6，设计
/// `docs/specs/2026-11-23-combo-settings-tree-design.md` §2.2、§5）：设置树逐节点标「继承」/
/// 「单独设置」；「单独设置」复制此刻的生效值、「恢复继承」撤销拆分，子组可整体拆 / 恢复；在这一层
/// 不能拆的节点灰掉并写原因。改值本身仍在各设置页里做：组合是激活配置时，改任何设置在写回时
/// 自动拆出它所属的项（`ProfileRepository.snapshotCurrentSettings` → `rebaseComboDocument`）。
///
/// 复习库归属（`srs.library`）有自己的动作：「拆成独立复习库」，已拆的「合并进共享复习库」（阶段
/// 5 的合并流程，入口从配置行挪到这里）。
library;

import 'package:cupertino_ui/cupertino_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/profile/combo/combo_editing.dart';
import 'package:fushi/src/profile/combo/combo_node_widgets.dart';
import 'package:fushi/src/profile/combo/combo_repository.dart';
import 'package:fushi/src/profile/combo/fushi_settings_tree.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/settings/settings_section_footer.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart'
    show showFushiConfirmDialog;
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 编辑组合 [profileId]。默认组合只读（所有项都有值，没有继承可言）。
///
/// 编辑动作 [editing] 与「合并进共享复习库」流程 [onMergeSrsLibrary] 由调用方（配置管理页）注入，
/// 本文件不连视图模型 / AppModel（见 [ComboEditing]）。
class ComboEditorPage extends StatefulWidget {
  const ComboEditorPage({
    required this.profileId,
    required this.editing,
    required this.onMergeSrsLibrary,
    super.key,
  });

  final int profileId;
  final ComboEditing editing;

  /// 预览 → 冲突确认框 → 合并 → 提示（组合阶段 5 的流程）。
  final Future<void> Function(BuildContext context, int profileId)
  onMergeSrsLibrary;

  @override
  State<ComboEditorPage> createState() => _ComboEditorPageState();
}

class _ComboEditorPageState extends State<ComboEditorPage> {
  ComboEditorData? _data;
  bool _loading = true;
  bool _busy = false;

  ComboEditing get _vm => widget.editing;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    ComboEditorData? data;
    try {
      data = await _vm.loadComboEditor(widget.profileId);
    } catch (e, stack) {
      ErrorLogService.instance.log('ComboEditor.load', e, stack);
    }
    if (!mounted) return;
    setState(() {
      _data = data;
      _loading = false;
    });
  }

  /// 跑一个编辑动作：期间按钮不可点，失败提示并记日志，完了重读。
  Future<void> _run(String tag, Future<void> Function() op) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await op();
    } catch (e, stack) {
      ErrorLogService.instance.log('ComboEditor.$tag', e, stack);
      FushiToast.show(
        msg: t.profile_combo_action_failed,
        severity: ToastSeverity.error,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final ComboEditorData? data = _data;
    return AdaptiveSettingsScaffold(
      title: Text(data?.profile.name ?? t.profile_combo_editor_title),
      children: <Widget>[
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 48),
            child: FushiLoadingView(),
          )
        else if (data != null)
          FushiEntranceScope(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final (int i, Widget section) in _sections(
                  context,
                  data,
                ).indexed)
                  FushiStaggeredEntrance(index: i, child: section),
              ],
            ),
          ),
      ],
    );
  }

  List<Widget> _sections(BuildContext context, ComboEditorData data) {
    final SettingsTree tree = fushiSettingsTree;
    return <Widget>[
      _intro(context, data),
      for (final SettingsNode root in tree.roots)
        AdaptiveSettingsSection(
          key: ValueKey<String>('combo_section_${root.id}'),
          title: root.isLeaf ? null : comboGroupLabel(root.id),
          children: <Widget>[
            if (!root.isLeaf && !data.isDefault) ?_groupRow(data, root),
            for (final SettingsNode leaf in tree.leavesUnder(root.id))
              _leafTile(data, leaf),
          ],
        ),
    ];
  }

  Widget _intro(BuildContext context, ComboEditorData data) {
    if (data.isDefault) {
      return SettingsSectionFooter(t.profile_combo_default_note);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SettingsSectionFooter(
          '${t.profile_combo_inherits_from(name: data.defaultName)}\n'
          '${data.active ? t.profile_combo_values_hint_active : t.profile_combo_values_hint_inactive}',
        ),
        if (!data.active)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FushiTextButton(
              key: const ValueKey<String>('combo_switch_to_edit'),
              onPressed: _busy
                  ? null
                  : () => _run(
                      'switch',
                      () => _vm.switchProfile(widget.profileId),
                    ),
              child: Text(t.profile_combo_switch_to_edit),
            ),
          ),
      ],
    );
  }

  /// 子组整体拆 / 恢复（能在这一层拆的叶子不止一个时才有）。
  Widget? _groupRow(ComboEditorData data, SettingsNode group) {
    final List<SettingsNode> editable = <SettingsNode>[
      for (final SettingsNode leaf in fushiSettingsTree.leavesUnder(group.id))
        if (leaf.diffable && leaf.splittableAt.contains(data.scope)) leaf,
    ];
    if (editable.length < 2) return null;
    final bool allSplit = editable.every(
      (SettingsNode l) => data.document.isSplit(l.id),
    );
    final bool cupertino = isCupertinoPlatform(context);
    return AdaptiveSettingsRow(
      key: ValueKey<String>('combo_group_${group.id}'),
      icon: cupertino ? CupertinoIcons.square_stack_3d_up : FushiIcons.widgets,
      showIcon: true,
      title: allSplit
          ? t.profile_combo_action_restore_group
          : t.profile_combo_action_split_group,
      onTap: _busy
          ? null
          : () => _run(
              allSplit ? 'restoreGroup' : 'splitGroup',
              () => allSplit
                  ? _vm.restoreComboNode(widget.profileId, group.id)
                  : _vm.splitComboNode(widget.profileId, group.id),
            ),
    );
  }

  Widget _leafTile(ComboEditorData data, SettingsNode leaf) {
    final Map<SettingKey, String> values = data.effective.leafValues(
      fushiSettingsTree,
      leaf.id,
    );
    if (leaf.id == FushiComboNode.srsLibrary) {
      return _srsLibraryTile(data, values);
    }
    final bool split = data.document.isSplit(leaf.id);
    if (data.isDefault) {
      return ComboLeafTile(
        leafId: leaf.id,
        split: false,
        showState: false,
        values: values,
      );
    }
    final bool splittable = leaf.splittableAt.contains(data.scope);
    final String? subtitle = !splittable
        ? t.profile_combo_not_splittable_work
        : !leaf.splittableAt.contains(ComboScope.work) && split
        ? t.profile_combo_ignored_on_work
        : null;
    return ComboLeafTile(
      leafId: leaf.id,
      split: split,
      values: values,
      subtitle: subtitle,
      actionLabel: !splittable
          ? null
          : split
          ? t.profile_combo_action_restore
          : t.profile_combo_action_split,
      onAction: !splittable || _busy
          ? null
          : () => _run(
              split ? 'restore' : 'split',
              () => split
                  ? _vm.restoreComboNode(widget.profileId, leaf.id)
                  : _vm.splitComboNode(widget.profileId, leaf.id),
            ),
    );
  }

  Widget _srsLibraryTile(ComboEditorData data, Map<SettingKey, String> values) {
    final bool own = data.ownSrsLibrary;
    if (data.isDefault) {
      return ComboLeafTile(
        leafId: FushiComboNode.srsLibrary,
        split: false,
        showState: false,
        values: values,
        subtitle: t.profile_combo_srs_shared,
      );
    }
    return ComboLeafTile(
      leafId: FushiComboNode.srsLibrary,
      split: own,
      values: values,
      subtitle: own ? t.profile_combo_srs_own : t.profile_combo_srs_shared,
      actionLabel: own
          ? t.srs_library_merge_action
          : t.profile_combo_srs_split_action,
      onAction: _busy
          ? null
          : own
          ? _mergeSrsLibrary
          : _splitSrsLibrary,
    );
  }

  Future<void> _splitSrsLibrary() async {
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.profile_combo_srs_split_action,
      message: t.profile_combo_srs_split_confirm,
      confirmLabel: t.profile_combo_srs_split_action,
    );
    if (!ok || !mounted) return;
    await _run(
      'splitSrsLibrary',
      () => _vm.splitComboSrsLibrary(widget.profileId),
    );
  }

  /// 「合并进共享复习库」（组合阶段 5）：先读预览（冲突表），再弹确认框；合并在框里跑。
  Future<void> _mergeSrsLibrary() async {
    await widget.onMergeSrsLibrary(context, widget.profileId);
    await _reload();
  }
}
