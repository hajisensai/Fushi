/// 「制卡发音兜底声音」的选择器与摘要文案。
///
/// 选项与朗读的「快速切换声音」同一套推导（[ttsVoiceSwitchEntries]：不可用 / 未配置
/// 完整的声音灰掉）与同一个单选对话框（[showFushiChoiceDialog]），前面多两项
/// 「系统语音」「不使用 TTS 兜底」，末尾一项跳到朗读声音设置页。
library;

import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/creator/mining_tts_fallback.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/media/audiobook/tts/tts_ui_text.dart';
import 'package:fushi/src/media/audiobook/tts/tts_voice_quick_switch.dart';
import 'package:fushi/src/media/audiobook/tts/tts_voice_settings_page.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart'
    show FushiChoiceOption, showFushiChoiceDialog;
import 'package:fushi/src/utils/fushi_icons.dart';

/// 选择器里「管理声音」那一项的值（不是合法的 [MiningTtsFallbackVoice.wire]）。
const String kMiningTtsFallbackManageValue = '#manage';

/// 这份预设走在线服务（词条文本会发到对方服务器）。
bool _isOnline(TtsProviderDescriptor? descriptor) =>
    descriptor?.category == TtsProviderCategory.online;

/// 选择器的全部选项（值 = [MiningTtsFallbackVoice.wire]，末项是
/// [kMiningTtsFallbackManageValue]）。纯函数，便于测试。
List<FushiChoiceOption<String>> miningTtsFallbackChoiceOptions({
  required List<TtsVoicePreset> presets,
  required TtsProviderDescriptor? Function(String providerId) descriptorOf,
  required String? systemEngineName,
}) => <FushiChoiceOption<String>>[
  FushiChoiceOption<String>(
    value: const MiningTtsFallbackVoice.system().wire,
    label: t.audiobook_tts_provider_system,
    subtitle: systemEngineName ?? t.models_tts_unavailable,
    icon: FushiIcons.volumeUp,
  ),
  FushiChoiceOption<String>(
    value: const MiningTtsFallbackVoice.none().wire,
    label: t.models_tts_fallback_off,
    icon: FushiIcons.volumeOff,
  ),
  for (final TtsVoiceSwitchEntry e in ttsVoiceSwitchEntries(
    presets: presets,
    activePresetId: null,
    descriptorOf: descriptorOf,
  ))
    FushiChoiceOption<String>(
      value: MiningTtsFallbackVoice.preset(e.preset.id).wire,
      label: e.label,
      subtitle: switch (e.block) {
        TtsVoiceSwitchBlock.unavailable => t.audiobook_tts_failure_unsupported,
        TtsVoiceSwitchBlock.incomplete =>
          t.audiobook_tts_voice_incomplete_status,
        null =>
          _isOnline(descriptorOf(e.preset.providerId))
              ? '${ttsProviderLabel(e.preset.providerId)} · '
                    '${t.models_tts_fallback_online_notice}'
              : ttsProviderLabel(e.preset.providerId),
      },
      icon: FushiIcons.voice,
      enabled: e.selectable,
    ),
  FushiChoiceOption<String>(
    value: kMiningTtsFallbackManageValue,
    label: t.audiobook_tts_voice_settings,
    subtitle: t.audiobook_tts_voice_settings_hint,
    icon: FushiIcons.settings,
  ),
];

/// 设置行副标题：当前选择；选的是在线声音时另起一行提示词条会发给该服务。
String miningTtsFallbackSummary({
  required MiningTtsFallbackVoice choice,
  required List<TtsVoicePreset> presets,
  required TtsProviderDescriptor? Function(String providerId) descriptorOf,
  required String? systemEngineName,
}) {
  switch (choice.kind) {
    case MiningTtsFallbackKind.system:
      return '${t.audiobook_tts_provider_system} · '
          '${systemEngineName ?? t.models_tts_unavailable}';
    case MiningTtsFallbackKind.none:
      return t.models_tts_fallback_off;
    case MiningTtsFallbackKind.preset:
      final TtsVoicePreset? preset = presets
          .where((TtsVoicePreset p) => p.id == choice.presetId)
          .firstOrNull;
      if (preset == null) return t.models_tts_fallback_voice_missing;
      final String head =
          '${ttsVoiceDisplayName(preset)} · '
          '${ttsProviderLabel(preset.providerId)}';
      return _isOnline(descriptorOf(preset.providerId))
          ? '$head\n${t.models_tts_fallback_online_notice}'
          : head;
  }
}

/// 弹出选择器。返回新选择；取消或去了「管理声音」返回 null。
Future<MiningTtsFallbackVoice?> showMiningTtsFallbackVoicePicker(
  BuildContext context,
  TtsServices services, {
  required MiningTtsFallbackVoice current,
}) async {
  final String? picked = await showFushiChoiceDialog<String>(
    context: context,
    title: t.models_tts_fallback_voice,
    icon: FushiIcons.voice,
    selected: current.wire,
    options: miningTtsFallbackChoiceOptions(
      presets: services.store.loadPresets(),
      descriptorOf: (String id) => services.registry[id],
      systemEngineName: systemTtsEngineName(),
    ),
  );
  if (picked == null) return null;
  if (picked == kMiningTtsFallbackManageValue) {
    if (context.mounted) await openTtsVoiceSettingsPage(context, services);
    return null;
  }
  return MiningTtsFallbackVoice.parse(picked);
}
