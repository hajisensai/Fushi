/// 「添加声音」流程的唯一实现：朗读声音页的「添加声音」与制作侧（有声书制作台、
/// 漫画有声）各声音选择弹窗末尾的「添加声音」都走这里，加完回填并选中新声音。
library;

import 'package:fushi_engine/tts/local/voicevox_local_engine.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/tts/gpt_sovits_local_page.dart';
import 'package:fushi/src/media/audiobook/tts/irodori_local_page.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/media/audiobook/tts/tts_ui_text.dart';
import 'package:fushi/src/media/audiobook/tts/tts_voice_settings_page.dart';
import 'package:fushi/src/media/audiobook/tts/voicevox_local_page.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 「添加声音」里「本机一键部署 GPT-SoVITS」那一项的值（其余项是
/// [TtsProviderCategory] / [VoicevoxLocalEngine]）。
const String _kAddLocalGptSovits = 'local_gpt_sovits';

/// 「添加声音」里「本机一键部署 Irodori-TTS」那一项的值。
const String _kAddLocalIrodori = 'local_irodori';

/// 声音选择弹窗末尾「添加声音」那一项的值（不会与预设 id 撞：预设 id 不含 NUL）。
const String kTtsVoicePickAddValue = '\u0000add_voice';

/// 声音大类的图标（声音列表行、「添加声音」选项共用）。
IconData ttsCategoryIcon(TtsProviderCategory c) => switch (c) {
  TtsProviderCategory.external => FushiIcons.devices,
  TtsProviderCategory.online => FushiIcons.cloud,
  TtsProviderCategory.system => FushiIcons.voice,
};

/// 打开本机部署页（GPT-SoVITS / [irodori] 时 Irodori-TTS / 给了 [voicevox] 时该
/// VOICEVOX 兼容引擎）；那边新建了声音时返回其 id（已落盘）。
Future<String?> openTtsLocalDeployPage(
  BuildContext context,
  TtsServices services, {
  bool irodori = false,
  VoicevoxLocalEngine? voicevox,
}) {
  if (voicevox != null) {
    return openVoicevoxLocalPage(context, services, voicevox);
  }
  return irodori
      ? openIrodoriLocalPage(context, services)
      : openGptSovitsLocalPage(context, services);
}

/// 按引擎默认参数新建一份声音并落盘（追加到清单末尾；原先没有使用中的声音时设为
/// 使用中），返回其 id。
Future<String> addTtsPresetFor(
  TtsPresetStore store,
  TtsProviderDescriptor descriptor,
) async {
  final TtsVoicePreset preset = TtsVoicePreset(
    id: newTtsPresetId(),
    providerId: descriptor.id,
    name: ttsProviderLabel(descriptor.id),
    params: ttsDefaultParams(descriptor),
  );
  final String? active = store.activePreset()?.id;
  await store.savePresets(<TtsVoicePreset>[...store.loadPresets(), preset]);
  await store.setActivePresetId(active ?? preset.id);
  return preset.id;
}

/// 「添加声音」：只按大类选（外部服务 / 在线服务 / 系统语音），另加本机一键部署；
/// 具体是哪个引擎在编辑页的「服务类型」里选，默认取该类第一个。新声音落盘后返回
/// 其 id；取消返回 null。
///
/// 直接读写预设仓：调用方手里若有防抖中的清单编辑，调用前先落盘、回来后重读。
Future<String?> runTtsVoiceAddFlow(
  BuildContext context,
  TtsServices services,
) async {
  // 与进朗读声音页同一前提：从没存过清单时先放进内置声音，免得新声音把它挤掉。
  await services.seedBuiltinVoiceIfUnset();
  if (!context.mounted) return null;
  final TtsProviderRegistry registry = services.registry;
  final List<TtsProviderCategory> categories = <TtsProviderCategory>[
    for (final TtsProviderCategory c in TtsProviderCategory.values)
      if (registry.available.any((TtsProviderDescriptor d) => d.category == c))
        c,
  ];
  final Object? choice = await showFushiChoiceDialog<Object>(
    context: context,
    title: t.audiobook_tts_voice_add_title,
    icon: FushiIcons.voice,
    options: <FushiChoiceOption<Object>>[
      // 自己没有服务的用户最该走的一条：放最前。
      if (services.localGptSovits.isSupported)
        FushiChoiceOption<Object>(
          value: _kAddLocalGptSovits,
          label: t.audiobook_tts_local_add,
          subtitle: t.audiobook_tts_local_add_hint,
          icon: FushiIcons.download,
        ),
      if (services.localIrodori.isSupported)
        FushiChoiceOption<Object>(
          value: _kAddLocalIrodori,
          label: t.audiobook_tts_irodori_local_add,
          subtitle: t.audiobook_tts_irodori_local_add_hint,
          icon: FushiIcons.download,
        ),
      for (final VoicevoxLocalEngine engine in <VoicevoxLocalEngine>[
        services.localVoicevox,
        services.localAivisSpeech,
      ])
        if (engine.isSupported)
          FushiChoiceOption<Object>(
            value: engine,
            label: t.audiobook_tts_voicevox_local_add(
              engine: voicevoxLocalEngineName(engine),
            ),
            subtitle: voicevoxLocalAddHint(engine),
            icon: FushiIcons.download,
          ),
      for (final TtsProviderCategory c in categories)
        FushiChoiceOption<Object>(
          value: c,
          label: ttsCategoryLabel(c),
          subtitle: ttsCategoryHint(c),
          icon: ttsCategoryIcon(c),
        ),
    ],
  );
  if (choice == null || !context.mounted) return null;
  if (choice == _kAddLocalGptSovits) {
    return openTtsLocalDeployPage(context, services);
  }
  if (choice == _kAddLocalIrodori) {
    return openTtsLocalDeployPage(context, services, irodori: true);
  }
  if (choice is VoicevoxLocalEngine) {
    return openTtsLocalDeployPage(context, services, voicevox: choice);
  }
  final TtsProviderCategory picked = choice as TtsProviderCategory;
  return addTtsPresetFor(
    services.store,
    registry.available.firstWhere(
      (TtsProviderDescriptor d) => d.category == picked,
    ),
  );
}

/// 声音选择弹窗里的「添加声音」：走 [runTtsVoiceAddFlow]；新声音还用不了（按大类
/// 新建的多半要填服务地址 / 密钥）时直接打开朗读声音页定位到它。返回新声音 id；
/// 取消返回 null。调用方回来后重读自己的声音清单（用户可能在声音页里又删掉它）。
Future<String?> addTtsVoiceFromPicker(
  BuildContext context,
  TtsServices services,
) async {
  final String? id = await runTtsVoiceAddFlow(context, services);
  if (id == null || !context.mounted) return id;
  final TtsVoicePreset? preset = services.store
      .loadPresets()
      .where((TtsVoicePreset p) => p.id == id)
      .firstOrNull;
  final TtsProviderDescriptor? descriptor = preset == null
      ? null
      : services.registry[preset.providerId];
  final bool usable =
      preset != null &&
      descriptor != null &&
      descriptor.isAvailable &&
      descriptor.validate(preset).isEmpty;
  if (!usable) {
    await openTtsVoiceSettingsPage(context, services, openPresetId: id);
  }
  return id;
}

/// 选声音的单选弹窗：[options] 之后固定接一项「添加声音」，选它就跑 [onAdd]
/// 并把新声音当作选中项返回（只有一个声音时也能从这里加第二个）。返回 null = 取消。
Future<String?> showTtsVoicePickDialog({
  required BuildContext context,
  required String title,
  required List<FushiChoiceOption<String>> options,
  required Future<String?> Function() onAdd,
  String? selected,
  String? message,
}) async {
  final String? picked = await showFushiChoiceDialog<String>(
    context: context,
    title: title,
    icon: FushiIcons.voice,
    message: message,
    selected: selected,
    options: <FushiChoiceOption<String>>[
      ...options,
      FushiChoiceOption<String>(
        value: kTtsVoicePickAddValue,
        label: t.audiobook_tts_voice_add,
        icon: FushiIcons.add,
      ),
    ],
  );
  if (picked != kTtsVoicePickAddValue) return picked;
  if (!context.mounted) return null;
  return onAdd();
}
