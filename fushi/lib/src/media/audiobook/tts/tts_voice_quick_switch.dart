/// 朗读中「快速切换声音」：列出全部声音预设（标出使用中），选中即换；末尾一项跳到
/// 朗读声音设置页。条目推导是纯函数（[ttsVoiceSwitchEntries]），对话框只做呈现。
///
/// 在书 / 漫画里打开时（给了 [TtsMediaVoiceScope]），选中的声音记到这部作品
/// （[TtsMediaVoices]：有系列记到「系列 + 语言」，没有就记到本书），不改全局默认；
/// 作品有自己的声音时多一项「使用默认声音」把它清掉。
library;

import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/media/audiobook/tts/tts_ui_text.dart';
import 'package:fushi/src/utils/components/content_language_picker.dart'
    show contentLanguageLabelOf;
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
    this.isDefault = false,
    this.block,
  });

  final TtsVoicePreset preset;
  final String label;

  /// 是当前使用中的声音（在作品里打开时 = 这部作品实际用的声音）。
  final bool active;

  /// 是全局默认声音，且作品用的不是它（标「默认」，让用户知道清掉作品声音后回到哪个）。
  final bool isDefault;

  /// 非 null = 不能选。
  final TtsVoiceSwitchBlock? block;

  bool get selectable => block == null;
}

/// 由预设清单推导快速切换列表。[activePresetId] 是实际在用的声音（作品里打开时取
/// `TtsServices.voiceForMedia`，否则 `TtsPresetStore.activePreset()`）；
/// [defaultPresetId] 是全局默认声音，与 [activePresetId] 不同时那一行标「默认」。
List<TtsVoiceSwitchEntry> ttsVoiceSwitchEntries({
  required List<TtsVoicePreset> presets,
  required String? activePresetId,
  required TtsProviderDescriptor? Function(String providerId) descriptorOf,
  String? defaultPresetId,
}) => <TtsVoiceSwitchEntry>[
  for (final TtsVoicePreset preset in presets)
    TtsVoiceSwitchEntry(
      preset: preset,
      label: ttsVoiceDisplayName(preset),
      active: preset.id == activePresetId,
      isDefault:
          defaultPresetId != null &&
          defaultPresetId != activePresetId &&
          preset.id == defaultPresetId,
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

/// 快速切换的结果种类。
enum TtsVoiceQuickSwitchAction {
  /// 选了某个声音（[TtsVoiceQuickSwitchChoice.presetId]）。
  preset,

  /// 清掉作品自己的声音，回到全局默认。
  useDefault,

  /// 去朗读声音设置页。
  manage,
}

/// 快速切换的结果：选了某个声音、回到默认声音，或要去管理声音。
@immutable
class TtsVoiceQuickSwitchChoice {
  const TtsVoiceQuickSwitchChoice.preset(String this.presetId)
    : action = TtsVoiceQuickSwitchAction.preset;
  const TtsVoiceQuickSwitchChoice.useDefault()
    : action = TtsVoiceQuickSwitchAction.useDefault,
      presetId = null;
  const TtsVoiceQuickSwitchChoice.manage()
    : action = TtsVoiceQuickSwitchAction.manage,
      presetId = null;

  final TtsVoiceQuickSwitchAction action;

  /// 只在 [TtsVoiceQuickSwitchAction.preset] 时非 null。
  final String? presetId;

  bool get isManage => action == TtsVoiceQuickSwitchAction.manage;

  @override
  bool operator ==(Object other) =>
      other is TtsVoiceQuickSwitchChoice &&
      other.action == action &&
      other.presetId == presetId;

  @override
  int get hashCode => Object.hash(action, presetId);
}

/// 对话框顶部的说明：在这里选的声音记到哪（作品里打开时才有）。
String ttsVoiceScopeMessage(TtsMediaVoiceScope scope) {
  if (scope.seriesKey == null) return t.audiobook_tts_voice_scope_book;
  final String language = scope.language?.trim() ?? '';
  return scope.languageKey.isEmpty || language.isEmpty
      ? t.audiobook_tts_voice_scope_series
      : t.audiobook_tts_voice_scope_series_language(
          language: contentLanguageLabelOf(language),
        );
}

/// 弹出快速切换对话框。焦点落在使用中的那一项，方向键 / Tab 移动，Enter / 手柄 A
/// 选中（[showFushiChoiceDialog] 的既有行为）。返回 null = 取消。
///
/// [scope] 非 null 时按这部作品标「使用中」、顶部说明选择记到哪，并在作品有自己的
/// 声音时多一项「使用默认声音」。调用方按 [TtsVoiceQuickSwitchChoice.action] 落盘
/// （[applyTtsVoiceQuickSwitchChoice]）。
Future<TtsVoiceQuickSwitchChoice?> showTtsVoiceQuickSwitch(
  BuildContext context,
  TtsServices services, {
  TtsMediaVoiceScope? scope,
}) {
  final TtsMediaVoice? media = scope == null
      ? null
      : services.voiceForMedia(scope);
  final TtsVoicePreset? defaultPreset = services.store.activePreset();
  final String? activeId = media?.preset.id ?? defaultPreset?.id;
  final bool hasOwnVoice =
      media != null && media.source != TtsVoiceSource.defaultVoice;
  final List<TtsVoiceSwitchEntry> entries = ttsVoiceSwitchEntries(
    presets: services.store.loadPresets(),
    activePresetId: activeId,
    defaultPresetId: hasOwnVoice ? defaultPreset?.id : null,
    descriptorOf: (String id) => services.registry[id],
  );
  final TtsVoiceSwitchEntry? active = entries
      .where((TtsVoiceSwitchEntry e) => e.active)
      .firstOrNull;
  return showFushiChoiceDialog<TtsVoiceQuickSwitchChoice>(
    context: context,
    title: t.audiobook_tts_voices_section,
    icon: FushiIcons.voice,
    message: scope == null ? null : ttsVoiceScopeMessage(scope),
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
            null => <String>[
              if (e.active) t.audiobook_tts_voice_active,
              if (e.isDefault) t.audiobook_tts_voice_default_status,
              ttsProviderLabel(e.preset.providerId),
            ].join(' · '),
          },
          icon: FushiIcons.voice,
          enabled: e.selectable,
        ),
      if (hasOwnVoice)
        FushiChoiceOption<TtsVoiceQuickSwitchChoice>(
          value: const TtsVoiceQuickSwitchChoice.useDefault(),
          label: t.audiobook_tts_voice_use_default,
          subtitle: defaultPreset == null
              ? null
              : ttsVoiceDisplayName(defaultPreset),
          icon: FushiIcons.voice,
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

/// 把选中的声音 / 「使用默认声音」落到作品表；[scope] 为 null（不在作品里）时选中
/// 声音即设为全局使用中（旧行为）。「管理声音」不在这里处理。
Future<void> applyTtsVoiceQuickSwitchChoice(
  TtsServices services,
  TtsVoiceQuickSwitchChoice choice, {
  TtsMediaVoiceScope? scope,
}) async {
  final TtsPresetStore store = services.store;
  switch (choice.action) {
    case TtsVoiceQuickSwitchAction.manage:
      return;
    case TtsVoiceQuickSwitchAction.preset:
      final String presetId = choice.presetId!;
      if (scope == null) {
        await store.setActivePresetId(presetId);
        return;
      }
      final TtsMediaVoices voices = store.loadMediaVoices()
        ..assign(scope, presetId);
      await store.saveMediaVoices(voices);
    case TtsVoiceQuickSwitchAction.useDefault:
      if (scope == null) return;
      final TtsMediaVoices voices = store.loadMediaVoices()..clear(scope);
      await store.saveMediaVoices(voices);
  }
}
