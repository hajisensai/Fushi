/// 「已保存的提示词」的统一 UI（反馈 _LLhOKwmI3）：各 AI 入口在提示词输入框旁放一枚
/// [AiSavedPromptButton]，点开 [AiSavedPromptSheet] 选用 / 保存当前 / 管理。
///
/// 选中一条只把文字填回原输入框，不自动发请求——用户仍照常点「生成」。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/ai/ai_saved_prompts.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 输入框旁的「已保存的提示词」按钮。
///
/// [store] 默认取 `appProvider` 的偏好仓库；测试可注入内存实现。
class AiSavedPromptButton extends StatelessWidget {
  const AiSavedPromptButton({
    required this.scene,
    required this.controller,
    this.enabled = true,
    this.showLabel = false,
    this.store,
    super.key,
  });

  /// 当前入口。
  final AiPromptScene scene;

  /// 提示词输入框的控制器：「保存当前」读它，选中一条写回它。
  final TextEditingController controller;

  /// AI 正在跑时置 false。
  final bool enabled;

  /// true = 带文字的文字按钮（竖排区块里用）；false = 纯图标按钮（与输入框同行）。
  final bool showLabel;

  /// 存取实现；null = 应用偏好。
  final AiSavedPromptStore? store;

  AiSavedPromptStore _resolveStore(BuildContext context) =>
      store ?? ProviderScope.containerOf(context).read(appProvider).prefsRepo;

  Future<void> _open(BuildContext context) async {
    final String? picked = await showAiSavedPromptSheet(
      context,
      scene: scene,
      current: controller.text,
      store: _resolveStore(context),
    );
    if (picked == null) return;
    controller.value = TextEditingValue(
      text: picked,
      selection: TextSelection.collapsed(offset: picked.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (showLabel) {
      return FushiTextButton.icon(
        key: ValueKey<String>('ai-saved-prompts-${scene.wire}'),
        onPressed: enabled ? () => unawaited(_open(context)) : null,
        icon: const FushiIcon(FushiIcons.bookmarks, size: 18),
        label: Text(t.ai_prompt_library_title),
      );
    }
    return FushiIconButton(
      key: ValueKey<String>('ai-saved-prompts-${scene.wire}'),
      icon: FushiIcons.bookmarks,
      tooltip: t.ai_prompt_library_title,
      enabled: enabled,
      padTouchTarget: true,
      onTap: () => _open(context),
    );
  }
}

/// 打开提示词库；返回选中的提示词正文（null = 没选）。
Future<String?> showAiSavedPromptSheet(
  BuildContext context, {
  required AiPromptScene scene,
  required String current,
  required AiSavedPromptStore store,
}) => adaptiveModalSheet<String>(
  context: context,
  builder: (BuildContext context) =>
      AiSavedPromptSheet(scene: scene, current: current, store: store),
);

enum _EntryAction { rename, toggleScope, delete }

/// 提示词库抽屉：顶部「保存当前提示词」，下面「我的提示词」（本场景 + 通用）与
/// 「内置预设」。点一条 = 选用（pop 正文）。
class AiSavedPromptSheet extends StatefulWidget {
  const AiSavedPromptSheet({
    required this.scene,
    required this.current,
    required this.store,
    super.key,
  });

  final AiPromptScene scene;

  /// 打开时输入框里的文字（「保存当前」用）。
  final String current;

  final AiSavedPromptStore store;

  @override
  State<AiSavedPromptSheet> createState() => _AiSavedPromptSheetState();
}

class _AiSavedPromptSheetState extends State<AiSavedPromptSheet> {
  late List<AiSavedPrompt> _all = widget.store.aiSavedPrompts;

  bool get _canSaveCurrent => widget.current.trim().isNotEmpty;

  Future<void> _write(List<AiSavedPrompt> next) async {
    await widget.store.setAiSavedPrompts(next);
    if (mounted) setState(() => _all = widget.store.aiSavedPrompts);
  }

  Future<void> _saveCurrent() async {
    final String body = widget.current.trim();
    if (body.isEmpty) return;
    final String? name = await showFushiTextInputDialog(
      context: context,
      title: t.ai_prompt_library_current_save,
      message: body,
      labelText: t.ai_prompt_library_name_label,
      initialValue: aiSavedPromptDefaultName(body),
      confirmLabel: t.ai_prompt_library_current_save,
      cancelLabel: t.cancel,
      icon: FushiIcons.bookmarkAdd,
    );
    if (name == null || !mounted) return;
    await _write(
      addAiSavedPrompt(_all, name: name, text: body, scene: widget.scene),
    );
    FushiToast.show(msg: t.ai_prompt_library_entry_saved(name: name));
  }

  Future<void> _rename(AiSavedPrompt prompt) async {
    final String? name = await showFushiTextInputDialog(
      context: context,
      title: t.ai_prompt_library_entry_rename,
      labelText: t.ai_prompt_library_name_label,
      initialValue: prompt.name,
      confirmLabel: t.ai_prompt_library_entry_rename,
      cancelLabel: t.cancel,
      icon: FushiIcons.rename,
    );
    if (name == null || !mounted) return;
    final String trimmed = name.length > kAiSavedPromptNameMax
        ? name.substring(0, kAiSavedPromptNameMax)
        : name;
    await _write(<AiSavedPrompt>[
      for (final AiSavedPrompt p in _all)
        p.id == prompt.id ? p.renamed(trimmed) : p,
    ]);
  }

  Future<void> _toggleScope(AiSavedPrompt prompt) => _write(<AiSavedPrompt>[
    for (final AiSavedPrompt p in _all)
      p.id == prompt.id
          ? p.withScope(general: !p.isGeneral, scene: widget.scene)
          : p,
  ]);

  Future<void> _delete(AiSavedPrompt prompt) => _write(<AiSavedPrompt>[
    for (final AiSavedPrompt p in _all)
      if (p.id != prompt.id) p,
  ]);

  void _pick(AiSavedPrompt prompt) => Navigator.of(context).pop(prompt.text);

  Widget _entry(AiSavedPrompt prompt) {
    final String subtitle = prompt.isGeneral && !prompt.isBuiltin
        ? '${t.ai_prompt_library_scope_global_badge} · ${prompt.text}'
        : prompt.text;
    return FushiListItem(
      key: ValueKey<String>('ai-saved-prompt-${prompt.id}'),
      leading: FushiIcon(
        prompt.isBuiltin
            ? FushiIcons.aiAssistant
            : (prompt.isGeneral ? FushiIcons.globe : FushiIcons.bookmark),
      ),
      title: Text(prompt.name),
      subtitle: Text(subtitle),
      subtitleMaxLines: 2,
      onTap: () => _pick(prompt),
      trailing: prompt.isBuiltin
          ? null
          : FushiPopupMenuButton<_EntryAction>(
              key: ValueKey<String>('ai-saved-prompt-menu-${prompt.id}'),
              tooltip: t.ai_prompt_library_entry_more,
              icon: const FushiIcon(FushiIcons.more),
              onSelected: (_EntryAction action) => unawaited(switch (action) {
                _EntryAction.rename => _rename(prompt),
                _EntryAction.toggleScope => _toggleScope(prompt),
                _EntryAction.delete => _delete(prompt),
              }),
              itemBuilder: (BuildContext _) => <PopupMenuEntry<_EntryAction>>[
                _menuItem(
                  _EntryAction.rename,
                  FushiIcons.rename,
                  t.ai_prompt_library_entry_rename,
                ),
                _menuItem(
                  _EntryAction.toggleScope,
                  prompt.isGeneral ? FushiIcons.bookmark : FushiIcons.globe,
                  prompt.isGeneral
                      ? t.ai_prompt_library_scope_local_set
                      : t.ai_prompt_library_scope_global_set,
                ),
                _menuItem(
                  _EntryAction.delete,
                  FushiIcons.delete,
                  t.ai_prompt_library_entry_delete,
                ),
              ],
            ),
    );
  }

  PopupMenuItem<_EntryAction> _menuItem(
    _EntryAction value,
    IconData icon,
    String label,
  ) => PopupMenuItem<_EntryAction>(
    key: ValueKey<String>('ai-saved-prompt-action-${value.name}'),
    value: value,
    child: Row(
      children: <Widget>[
        FushiIcon(icon, size: 20),
        const SizedBox(width: 12),
        Text(label),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<AiSavedPrompt> saved = aiSavedPromptsFor(_all, widget.scene);
    final List<AiSavedPrompt> builtins = aiBuiltinPrompts(widget.scene);
    final List<Widget> children = <Widget>[
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: FushiFilledButton.tonalIcon(
          key: const ValueKey<String>('ai-saved-prompt-save-current'),
          onPressed: _canSaveCurrent ? () => unawaited(_saveCurrent()) : null,
          icon: const FushiIcon(FushiIcons.bookmarkAdd),
          label: Text(t.ai_prompt_library_current_save),
        ),
      ),
      FushiSectionTitle(t.ai_prompt_library_saved_header),
      if (saved.isEmpty)
        Text(
          t.ai_prompt_library_saved_empty,
          key: const ValueKey<String>('ai-saved-prompt-empty'),
          style: tokens.type.listSubtitle,
        )
      else
        for (final AiSavedPrompt p in saved) _entry(p),
      FushiSectionTitle(t.ai_prompt_library_presets_header),
      for (final AiSavedPrompt p in builtins) _entry(p),
    ];
    return FushiModalSheetFrame(
      key: const ValueKey<String>('ai-saved-prompt-sheet'),
      title: t.ai_prompt_library_title,
      leadingIcon: FushiIcons.bookmarks,
      scrollable: true,
      body: FushiEntranceScope(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: tokens.spacing.gap / 2,
          children: <Widget>[
            for (final (int i, Widget w) in children.indexed)
              FushiStaggeredEntrance(index: i, child: w),
          ],
        ),
      ),
    );
  }
}
