import 'package:flutter/material.dart';

import 'package:fushi/pages.dart';
import 'package:fushi/src/dictionary/user_dictionary_store.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/utils.dart';

/// 用户词典可视化编辑页。
///
/// 编辑的是偏好里的词条列表（真相源），每次保存后由
/// [AppModel.saveUserDictionaryEntries] 把整份列表编译成 Yomitan zip 走现有
/// 导入链整部重建「User Dictionary」——词条落进真实查词路径，与手动导入的
/// 词典完全同待遇（排序/隐藏/折叠/CSS 都可用既有词典管理能力）。
class UserDictionaryEditorPage extends BasePage {
  const UserDictionaryEditorPage({super.key});

  @override
  BasePageState createState() => _UserDictionaryEditorPageState();
}

class _UserDictionaryEditorPageState extends BasePageState {
  /// 首次 build 时从 AppModel 惰性加载（appModel 走 ref.watch，initState 里
  /// 拿不到）；之后本页内存副本就是编辑现场，保存时整份交回 AppModel。
  List<UserDictionaryEntry>? _entriesOrNull;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _searchQuery = '';
  bool _isRebuilding = false;

  List<UserDictionaryEntry> get _entries =>
      _entriesOrNull ??= appModel.userDictionaryEntries;

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  /// 当前搜索词下可见的词条下标（对全量列表的下标——编辑/删除必须按全量下标
  /// 寻址，过滤视图只是投影）。
  List<int> get _visibleIndices => <int>[
        for (int i = 0; i < _entries.length; i++)
          if (matchesMediaSearch(
            query: _searchQuery,
            titles: <String>[
              _entries[i].expression,
              _entries[i].reading,
              _entries[i].meaning,
            ],
          ))
            i,
      ];

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<int> visible = _visibleIndices;

    return AdaptiveSettingsScaffold(
      title: Text(t.dict_user_title),
      actions: cupertino
          ? <Widget>[
              FushiIconButton(
                tooltip: t.dict_user_entry_add,
                icon: Icons.add,
                onTap: _isRebuilding ? null : _addEntry,
              ),
            ]
          : const <Widget>[],
      children: <Widget>[
        if (!cupertino)
          Padding(
            padding: EdgeInsets.only(bottom: tokens.spacing.gap),
            child: Wrap(
              spacing: tokens.spacing.gap,
              runSpacing: tokens.spacing.gap,
              children: <Widget>[
                _buildActionButton(
                  focusPrefix: 'user-dict-action-add',
                  icon: Icons.add,
                  label: t.dict_user_entry_add,
                  onTap: _isRebuilding ? null : _addEntry,
                ),
              ],
            ),
          ),
        if (_isRebuilding)
          Padding(
            padding: EdgeInsets.only(bottom: tokens.spacing.gap),
            child: const LinearProgressIndicator(),
          ),
        if (_entries.isNotEmpty) ...<Widget>[
          FushiSearchField(
            controller: _searchController,
            focusNode: _searchFocusNode,
            hintText: t.search_ellipsis,
            onChanged: (String value) => setState(() => _searchQuery = value),
            onSubmitted: (_) {},
            onClear: () {
              _searchController.clear();
              setState(() => _searchQuery = '');
            },
          ),
          SizedBox(height: tokens.spacing.gap),
        ],
        if (_entries.isEmpty)
          FushiPlaceholderMessage(
            icon: Icons.edit_note_outlined,
            message: t.dict_user_empty,
          )
        else
          for (final int index in visible) _buildEntryRow(index),
      ],
    );
  }

  Widget _buildEntryRow(int index) {
    final UserDictionaryEntry entry = _entries[index];
    final String title = entry.reading.isEmpty
        ? entry.expression
        : '${entry.expression}【${entry.reading}】';
    final String subtitle = userDictionaryGlossaryLines(entry.meaning).first;
    return FushiListItem(
      focusId: FushiFocusId('user-dict-entry-$index'),
      title: Text(title),
      subtitle: subtitle.isEmpty ? null : Text(subtitle),
      trailing: FushiIconButton(
        tooltip: t.dialog_delete,
        icon: Icons.delete_outline,
        onTap: _isRebuilding ? null : () => _deleteEntry(index),
      ),
      onTap: _isRebuilding ? null : () => _editEntry(index),
    );
  }

  /// 与词典管理页动作栏同一 idiom：普通按钮 + 焦点根下的手柄/键盘焦点站。
  Widget _buildActionButton({
    required String focusPrefix,
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
  }) {
    final Widget button = FilledButton.tonalIcon(
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      label: Text(label),
    );
    if (onTap == null || FushiFocusRoot.maybeControllerOf(context) == null) {
      return button;
    }
    return FushiActivatableFocusTarget(
      focusIdPrefix: focusPrefix,
      onTap: onTap,
      child: ExcludeFocus(child: button),
    );
  }

  Future<void> _addEntry() async {
    final UserDictionaryEntry? entry = await showAppDialog<UserDictionaryEntry>(
      context: context,
      builder: (_) => const UserDictionaryEntryDialog(),
    );
    if (entry == null) return;
    await _saveEntries(<UserDictionaryEntry>[..._entries, entry]);
  }

  Future<void> _editEntry(int index) async {
    final UserDictionaryEntry? entry = await showAppDialog<UserDictionaryEntry>(
      context: context,
      builder: (_) => UserDictionaryEntryDialog(initialEntry: _entries[index]),
    );
    if (entry == null) return;
    final List<UserDictionaryEntry> next = <UserDictionaryEntry>[..._entries];
    next[index] = entry;
    await _saveEntries(next);
  }

  Future<void> _deleteEntry(int index) async {
    final UserDictionaryEntry entry = _entries[index];
    final FushiDestructiveConfirmResult? result =
        await showAppDialog<FushiDestructiveConfirmResult>(
      context: context,
      builder: (_) => FushiDestructiveConfirmDialog(
        title: t.dict_user_entry_delete_confirm,
        message: entry.reading.isEmpty
            ? entry.expression
            : '${entry.expression}【${entry.reading}】',
      ),
    );
    if (result == null) return;
    final List<UserDictionaryEntry> next = <UserDictionaryEntry>[..._entries]
      ..removeAt(index);
    await _saveEntries(next);
  }

  /// 落偏好 + 重建词典。重建失败只提示不回滚——偏好是真相源且已写成功，
  /// 下次保存自愈（AppModel 注释里的忙时冲突同走此路径）。
  Future<void> _saveEntries(List<UserDictionaryEntry> next) async {
    setState(() {
      _entriesOrNull = next;
      _isRebuilding = true;
    });
    try {
      await appModel.saveUserDictionaryEntries(next);
    } catch (e, stack) {
      ErrorLogService.instance.log('UserDictionaryEditor.rebuild', e, stack);
      FushiToast.show(
        msg: t.dict_user_rebuild_failed,
        severity: ToastSeverity.error,
      );
    } finally {
      if (mounted) {
        setState(() => _isRebuilding = false);
      }
    }
  }
}

/// 单条词条的表单对话框。pop [UserDictionaryEntry] = 保存；pop null = 取消。
///
/// 纯表单，不碰持久化——保存动作归页面（一处 `_saveEntries` 收口偏好写入与
/// 词典重建，向导航栈里塞副作用只会造出重复重建的特殊情况）。
class UserDictionaryEntryDialog extends StatefulWidget {
  const UserDictionaryEntryDialog({super.key, this.initialEntry});

  /// 非 null = 编辑既有词条（表单预填）；null = 新增。
  final UserDictionaryEntry? initialEntry;

  @override
  State<UserDictionaryEntryDialog> createState() =>
      _UserDictionaryEntryDialogState();
}

class _UserDictionaryEntryDialogState extends State<UserDictionaryEntryDialog> {
  late final TextEditingController _expressionController =
      TextEditingController(text: widget.initialEntry?.expression ?? '');
  late final TextEditingController _readingController =
      TextEditingController(text: widget.initialEntry?.reading ?? '');
  late final TextEditingController _meaningController =
      TextEditingController(text: widget.initialEntry?.meaning ?? '');

  @override
  void dispose() {
    _expressionController.dispose();
    _readingController.dispose();
    _meaningController.dispose();
    super.dispose();
  }

  void _submit() {
    final String expression = _expressionController.text.trim();
    if (expression.isEmpty) {
      FushiToast.show(
        msg: t.dict_user_expression_required,
        severity: ToastSeverity.error,
      );
      return;
    }
    Navigator.pop(
      context,
      UserDictionaryEntry(
        expression: expression,
        reading: _readingController.text.trim(),
        meaning: _meaningController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiDialogFrame(
      maxWidth: 480,
      maxHeightFactor: 0.88,
      child: FushiModalSheetFrame(
        title: widget.initialEntry == null
            ? t.dict_user_entry_add
            : t.dict_user_entry_edit,
        leadingIcon: Icons.edit_note_outlined,
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
          children: <Widget>[
            FushiTextField(
              controller: _expressionController,
              labelText: t.dict_user_field_expression,
              autofocus: true,
              textInputAction: TextInputAction.next,
            ),
            SizedBox(height: tokens.spacing.gap),
            FushiTextField(
              controller: _readingController,
              labelText: t.dict_user_field_reading,
              textInputAction: TextInputAction.next,
            ),
            SizedBox(height: tokens.spacing.gap),
            FushiTextField(
              controller: _meaningController,
              labelText: t.dict_user_field_meaning,
              keyboardType: TextInputType.multiline,
              minLines: 3,
              maxLines: 8,
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
              onPressed: _submit,
              child: Text(t.dialog_save),
            ),
          ],
        ),
      ),
    );
  }
}
