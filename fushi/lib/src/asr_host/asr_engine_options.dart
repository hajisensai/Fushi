/// 转录弹层「模型」下拉里到底有哪几项。
///
/// 在系统语音引擎进来之前，这个下拉的值域就是「服务该语言的 ONNX 包」，一个
/// [AsrModelPack] 列表就够了。系统语音不是一个包——**它没有文件、没有变体、不占
/// 磁盘、大小是未知**，硬塞成 `AsrModelPack` 会在 `filesFor()` / `totalBytes()` 这些
/// 地方抛 `StateError`（那些方法逐角色 `firstWhere`）。所以这里给出一个只表达 UI
/// 需要的窄类型：**值域是两类东西的和**，一个包 id，或那个保留 id。
///
/// 纯函数、无 IO、不碰平台单例——「本机有没有系统语音」由调用方探好了传进来。
library;

import 'package:fushi_asr_core/asr_core.dart';

import 'package:fushi/src/asr_host/apple_speech_transcription_service.dart';
import 'package:fushi/src/asr_host/asr_model_catalog.dart';

/// 下拉里的一项。
class AsrEngineOption {
  const AsrEngineOption({
    required this.id,
    required this.label,
    this.pack,
  });

  /// [AsrModelPack.id]，或系统语音的保留 id [kAppleSpeechEngineId]。
  final String id;

  /// 给用户看的名字。
  final String label;

  /// ONNX 包（系统语音项为 null）。
  final AsrModelPack? pack;

  bool get isSystemSpeech => pack == null;
}

/// 这门语言能选哪些引擎。
///
/// 顺序即展示顺序：**ONNX 包在前、系统语音在后**。理由是默认不能变——系统语音在
/// 支持它的机器上是「另一个可选项」，不是新的默认；而 [selectedAsrEngineId] 在没有
/// 选择记录时取第一项，取到 ONNX 包才与改动前逐字一致。
///
/// [systemSpeechAvailable] 为 false（OS < 26、非 Apple 平台、原生侧没实现）时那一项
/// **整个不出现**——出现一个点了就报错的选项比没有更糟。
List<AsrEngineOption> asrEngineOptions({
  required AsrLanguage language,
  required AsrModelRegistry registry,
  required bool systemSpeechAvailable,
  required String systemSpeechLabel,
}) {
  return <AsrEngineOption>[
    for (final AsrModelPack pack in asrModelChoicesFor(language, registry))
      AsrEngineOption(id: pack.id, label: pack.displayName, pack: pack),
    if (systemSpeechAvailable)
      AsrEngineOption(id: kAppleSpeechEngineId, label: systemSpeechLabel),
  ];
}

/// 当前这门语言选中的是哪一项。
///
/// 判据顺序：目录里记着的选择 → 命中就用它；没有记录、或记的那项已经不在列表里
/// （用户移除了自带包、换了台没有系统语音的机器）→ 回落第一项。**不回落 null**：
/// 下拉必须有个选中值，而「第一项」正是 `asrModelPackFor` 的判据。
String? selectedAsrEngineId({
  required AsrLanguage language,
  required AsrModelCatalog catalog,
  required List<AsrEngineOption> options,
}) {
  if (options.isEmpty) return null;
  final String? remembered = catalog.choices[language.tag];
  if (remembered != null) {
    for (final AsrEngineOption option in options) {
      if (option.id == remembered) return option.id;
    }
  }
  return options.first.id;
}
