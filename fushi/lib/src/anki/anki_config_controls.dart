import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi_anki/fushi_anki.dart';

import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/utils.dart';

/// BUG-1902：牌组 / 笔记类型选择与「一键创建 Lapis 卡组」的**单一实现**。
///
/// 这三样此前只活在 `anki_settings_page.dart` 的私有实例方法里
/// （`_buildDeckDropdown` / `_buildNoteTypeDropdown` / `_buildCreateLapisTile`），
/// 跨文件不可见。于是新手引导的 Anki 步只能显示三行**只读**文本（未选时是「—」），
/// 用户在引导里既建不出卡组也选不了牌组，被迫跳去设置页再回来——而「创建 Lapis 卡组」
/// 恰恰是一次性把 deck + note type + 字段映射三者对齐的动作，正是新手最需要的那一步
/// （也正好消除 [BUG-1900] 那类字段映射漂移）。
///
/// 抽成共享组件而不是把代码复制进引导页：两处显示的必须是同一份真值、同一种行为，
/// 复制一份就等于日后要改两处。业务层（`AnkiViewModel`）本来就是公开的，
/// 这里只是把「怎么画」也收成一处。
class AnkiDeckPickerRow extends StatelessWidget {
  const AnkiDeckPickerRow({
    required this.settings,
    required this.viewModel,
    super.key,
  });

  final AnkiSettings settings;
  final AnkiViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final List<AnkiDeck> decks = settings.availableDecks;
    final int? selectedId = settings.selectedDeckId;
    // 选中的 id 不在当前列表里（牌组在 Anki 里被删/改名）→ 不给 picker 一个它认不出的
    // 值，否则 Material 的 DropdownButton 会断言失败。
    final int? validSelectedId =
        decks.any((AnkiDeck d) => d.id == selectedId) ? selectedId : null;

    return AdaptiveSettingsPickerRow<int?>(
      title: t.anki_deck,
      controlBelow: true,
      selected: validSelectedId,
      options: decks
          .map((AnkiDeck d) => AdaptiveSettingsPickerOption<int?>(
                value: d.id,
                label: d.name,
              ))
          .toList(),
      onChanged: (int? id) {
        if (id == null) return;
        viewModel.selectDeck(decks.firstWhere((AnkiDeck d) => d.id == id));
      },
    );
  }
}

/// 笔记类型选择行。见 [AnkiDeckPickerRow] 的抽取理由。
class AnkiNoteTypePickerRow extends StatelessWidget {
  const AnkiNoteTypePickerRow({
    required this.settings,
    required this.viewModel,
    super.key,
  });

  final AnkiSettings settings;
  final AnkiViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final List<AnkiNoteType> noteTypes = settings.availableNoteTypes;
    final int? selectedId = settings.selectedNoteTypeId;
    final int? validSelectedId =
        noteTypes.any((AnkiNoteType n) => n.id == selectedId)
            ? selectedId
            : null;

    return AdaptiveSettingsPickerRow<int?>(
      title: t.anki_note_type,
      controlBelow: true,
      selected: validSelectedId,
      options: noteTypes
          .map((AnkiNoteType n) => AdaptiveSettingsPickerOption<int?>(
                value: n.id,
                label: n.name,
              ))
          .toList(),
      onChanged: (int? id) {
        if (id == null) return;
        viewModel.selectNoteType(
          noteTypes.firstWhere((AnkiNoteType n) => n.id == id),
        );
      },
    );
  }
}

/// 「一键创建 Lapis 卡组」行：向 Anki 建笔记类型 + 牌组，自动选中并套上
/// [LapisPreset] 的字段映射。
///
/// 自带在途状态：spinner 只跟本行自己的动作，不借 `AnkiUiState.isFetching`
/// ——否则点「刷新」时本行也凭空转圈（原设置页注释即此约定，一并搬过来）。
class AnkiCreateLapisRow extends StatefulWidget {
  const AnkiCreateLapisRow({
    required this.viewModel,
    required this.isFetching,
    this.onBusyChanged,
    super.key,
  });

  final AnkiViewModel viewModel;

  /// 外部（拉取牌组/笔记类型）是否在途——在途时本行禁用，避免两个动作打架。
  final bool isFetching;

  /// 本行自己的在途状态变化回调。
  ///
  /// `createLapisSetup` 内部会把 `AnkiUiState.isFetching` 也置真（vm 复用同一 flag），
  /// 所以**旁边的「刷新牌组」行分不清这是刷新还是建 Lapis**，会跟着显示「获取中…」+
  /// spinner。设置页据此把自己的文案压住；引导页不关心，可以不传。
  final ValueChanged<bool>? onBusyChanged;

  @override
  State<AnkiCreateLapisRow> createState() => _AnkiCreateLapisRowState();
}

class _AnkiCreateLapisRowState extends State<AnkiCreateLapisRow> {
  bool _busy = false;

  void _setBusy(bool value) {
    if (mounted) setState(() => _busy = value);
    widget.onBusyChanged?.call(value);
  }

  Future<void> _run() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    _setBusy(true);
    final LapisSetupResult result;
    try {
      result = await widget.viewModel.createLapisSetup();
    } finally {
      _setBusy(false);
    }
    if (!mounted) return;
    showLapisSetupResult(messenger, result);
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsRow(
      icon: Icons.note_add_outlined,
      showIcon: true,
      title: t.anki_create_lapis,
      subtitle: t.anki_create_lapis_hint,
      trailing: _busy
          ? SizedBox(
              width: 20,
              height: 20,
              child: adaptiveIndicator(context: context, strokeWidth: 2),
            )
          : null,
      onTap: widget.isFetching || _busy ? null : () => unawaited(_run()),
    );
  }
}

/// 「创建并选用 Lapis」的结果 snackbar —— **单一实现**。
///
/// 设置页 / 引导页的那一行按钮，和 [promptCreateLapisIfCannotMine] 弹窗里的确认，
/// 走的是同一个 [AnkiViewModel.createLapisSetup]，结果的呈现也必须是同一份：
/// 复制一份就等于日后 outcome 增删时要改两处。
void showLapisSetupResult(
  ScaffoldMessengerState messenger,
  LapisSetupResult result,
) {
  final String message;
  switch (result.outcome) {
    case LapisSetupOutcome.created:
      message = t.anki_create_lapis_success;
    case LapisSetupOutcome.alreadyExisted:
      message = t.anki_create_lapis_exists;
    case LapisSetupOutcome.failed:
      message = t.anki_create_lapis_failed(error: result.message ?? '');
  }
  // BUG-2098：权限被永久拒绝时系统不再弹授权框，光给一句提示等于把用户堵死；
  // 唯一出路是应用设置页里的权限项，所以直接把它做成 snackbar 上的一个按钮。
  final bool needsSettings =
      result.code == AnkiErrorCode.permissionPermanentlyDenied;
  messenger.showSnackBar(SnackBar(
    content: Text(message),
    duration: needsSettings
        ? const Duration(seconds: 10)
        : const Duration(seconds: 4),
    action: needsSettings
        ? SnackBarAction(
            label: t.anki_action_open_settings,
            onPressed: () => unawaited(AnkiRepository.openPermissionSettings()),
          )
        : null,
  ));
}

/// BUG-2380：当前 Anki 配置**制不出卡**时，劝用户建并选用 Lapis 的弹窗——
/// 同样是**单一实现**，新手引导点「下一步」与设置页/引导页连接 Anki 之后各调一次。
///
/// 判据是 [AnkiSettings.canMineCards]（首字段有没有接模板、选中的牌组还在不在），
/// **不是**「有没有 Lapis」：用户自己配好的笔记类型照样能制卡，拿 Lapis 当唯一合格
/// 线会把这些人也弹一遍窗。用户报的原始故障正是反面——配置其实是坏的（牌组被静默
/// 换成了用户自己的『日语』），却一路无声，直到制卡时才炸。
///
/// 清单为空时**不弹**：那是「还没连上 Anki / 这次没拉到东西」，不是配置有问题，
/// 此时劝人建牌组只是噪音。
///
/// 返回 true = 用户选择了创建且真的建成了（调用方据此决定要不要继续往下走）。
Future<bool> promptCreateLapisIfCannotMine({
  required BuildContext context,
  required AnkiViewModel viewModel,
}) async {
  final AnkiSettings settings = viewModel.settings;
  if (settings.availableDecks.isEmpty || settings.availableNoteTypes.isEmpty) {
    return false;
  }
  if (settings.canMineCards) return false;

  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  final bool confirmed = await showAppDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog.adaptive(
          title: Text(t.anki_lapis_suggest_title),
          content: Text(t.anki_lapis_suggest_body),
          actions: <Widget>[
            adaptiveDialogAction(
              context: dialogContext,
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(t.anki_lapis_suggest_dismiss),
            ),
            adaptiveDialogAction(
              context: dialogContext,
              isDefaultAction: true,
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(t.anki_create_lapis),
            ),
          ],
        ),
      ) ??
      false;
  if (!confirmed) return false;

  final LapisSetupResult result = await viewModel.createLapisSetup();
  showLapisSetupResult(messenger, result);
  return result.outcome != LapisSetupOutcome.failed;
}
