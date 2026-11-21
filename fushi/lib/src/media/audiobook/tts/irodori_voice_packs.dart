/// 声音包在 app 里的落点：清单文件位置，以及「制作侧可选的声音」= 声音预设 + 声音包
/// 虚拟预设（id 是 `pack:<packId>/<group>`，见 `irodori_voice_pack.dart`）。
///
/// 只有制作侧（有声书制作台、漫画有声）列声音包；朗读 / 查词发音这些实时场景不列——
/// v4-Large 是离线制作用的大模型。
library;

import 'dart:io';

import 'package:fushi_engine/tts/local/irodori_local_engine.dart';
import 'package:fushi_engine/tts/local/irodori_voice_pack.dart';
import 'package:fushi_engine/tts/local/irodori_voice_pack_provider.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/audiobook/tts/studio/audio_production_host.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';

/// 声音包清单（设备本地：里面是本机的 adapter / 参考音频路径）。
IrodoriVoicePackStore irodoriVoicePackStoreFor(AudioProductionHost appModel) =>
    IrodoriVoicePackStore(
      File(p.join(appModel.databaseDirectory.path, 'tts_voice_packs.json')),
    );

/// 制作侧可选的全部声音：声音预设在前，声音包（桌面端才有）在后。
List<TtsVoicePreset> ttsProductionPresets(
  TtsServices tts,
  AudioProductionHost appModel,
) => ttsProductionPresetsFrom(
  presets: tts.store.loadPresets(),
  packs: IrodoriLocalEngine.platformSupported
      ? irodoriVoicePackStoreFor(appModel).load()
      : const <IrodoriVoicePack>[],
);

/// [ttsProductionPresets] 的纯函数部分（测试直接调）。
List<TtsVoicePreset> ttsProductionPresetsFrom({
  required List<TtsVoicePreset> presets,
  required List<IrodoriVoicePack> packs,
}) => <TtsVoicePreset>[...presets, ...irodoriVoicePackPresets(packs)];
