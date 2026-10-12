/// 朗读中「快速切换声音」：列出全部声音预设（标出使用中），选中即换；末尾一项跳到
/// 朗读声音设置页。条目推导是纯函数（[ttsVoiceSwitchEntries]），对话框只做呈现。
library;

import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/media/audiobook/tts/tts_ui_text.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart'
    show FushiChoiceOption, showFushiChoiceDialog;
import 'package:fushi/src/utils/fushi_icons.dart';

/// 不能用来朗读的原因。
enum TtsVoiceSwitchBlock {
  /// 引擎在本平台不可用（或已不在注册表里）。
  unavailable,

  /// 预设缺必填参数。
  incomplete,
}

/// 快速切换列表的一行。
@immutable
class TtsVoiceSwitchEntry {
  const TtsVoiceSwitchEntry({
    required this.preset,
    required this.label,
    required this.active,
    this.block,
  });

  final TtsVoicePreset preset;
  final String label;

  /// 是当前使用中的声音。
  final bool active;

  /// 非 null = 不能选。
  final TtsVoiceSwitchBlock? block;

  bool get selectable => block == null;
}

/// 由预设清单推导快速切换列表。[activePresetId] 取 `TtsPresetStore.activePreset()`
/// 的 id（未选 / 已删时那份是清单第一份），与朗读实际使用的声音同口径。
List<TtsVoiceSwitchEntry> ttsVoiceSwitchEntries({
  required List<TtsVoicePreset> presets,
  required String? activePresetId,
  required TtsProviderDescriptor? Function(String providerId) descriptorOf,
}) => <TtsVoiceSwitchEntry>[
  for (final TtsVoicePreset preset in presets)
    TtsVoiceSwitchEntry(
      preset: preset,
      label: ttsVoiceDisplayName(preset),
      active: preset.id == activePresetId,
      block: switch (descriptorOf(preset.providerId)) {
        null => TtsVoiceSwitchBlock.unavailable,
        final TtsProviderDescriptor d when !d.isAvailable =>
          TtsVoiceSwitchBlock.unavailable,
        final TtsProviderDescriptor d when d.validate(preset).isNotEmpty =>
          TtsVoiceSwitchBlock.incomplete,
        _ => null,
      },
    ),
];

/// 声音的显示名：预设名，没起名时用引擎名。
String ttsVoiceDisplayName(TtsVoicePreset preset) =>
    preset.name.isEmpty ? ttsProviderLabel(preset.providerId) : preset.name;

/// 快速切换的结果：选了某个声音，或要去管理声音。
@immutable
class TtsVoiceQuickSwitchChoice {
  const TtsVoiceQuickSwitchChoice.preset(String this.presetId);
  const TtsVoiceQuickSwitchChoice.manage() : presetId = null;

  /// null = 「管理声音」。
  final String? presetId;

  bool get isManage => presetId == null;

  @override
  bool operator ==(Object other) =>
      other is TtsVoiceQuickSwitchChoice && other.presetId == presetId;

  @override
  int get hashCode => presetId.hashCode;
}

/// 弹出快速切换对话框。焦点落在使用中的那一项，方向键 / Tab 移动，Enter / 手柄 A
/// 选中（[showFushiChoiceDialog] 的既有行为）。返回 null = 取消。
Future<TtsVoiceQuickSwitchChoice?> showTtsVoiceQuickSwitch(
  BuildContext context,
  TtsServices services,
) {
  final List<TtsVoiceSwitchEntry> entries = ttsVoiceSwitchEntries(
    presets: services.store.loadPresets(),
    activePresetId: services.store.activePreset()?.id,
    descriptorOf: (String id) => services.registry[id],
  );
  final TtsVoiceSwitchEntry? active = entries
      .where((TtsVoiceSwitchEntry e) => e.active)
      .firstOrNull;
  return showFushiChoiceDialog<TtsVoiceQuickSwitchChoice>(
    context: context,
    title: t.audiobook_tts_voices_section,
    icon: FushiIcons.voice,
    selected: active == null
        ? null
        : TtsVoiceQuickSwitchChoice.preset(active.preset.id),
    options: <FushiChoiceOption<TtsVoiceQuickSwitchChoice>>[
      for (final TtsVoiceSwitchEntry e in entries)
        FushiChoiceOption<TtsVoiceQuickSwitchChoice>(
          value: TtsVoiceQuickSwitchChoice.preset(e.preset.id),
          label: e.label,
          subtitle: switch (e.block) {
            TtsVoiceSwitchBlock.unavailable =>
              t.audiobook_tts_failure_unsupported,
            TtsVoiceSwitchBlock.incomplete =>
              t.audiobook_tts_voice_incomplete_status,
            null =>
              e.active
                  ? '${t.audiobook_tts_voice_active} · '
                        '${ttsProviderLabel(e.preset.providerId)}'
                  : ttsProviderLabel(e.preset.providerId),
          },
          icon: FushiIcons.voice,
          enabled: e.selectable,
        ),
      FushiChoiceOption<TtsVoiceQuickSwitchChoice>(
        value: const TtsVoiceQuickSwitchChoice.manage(),
        label: t.audiobook_tts_voice_settings,
        subtitle: t.audiobook_tts_voice_settings_hint,
        icon: FushiIcons.settings,
      ),
    ],
  );
}
