/// 引擎层内置的 TTS 引擎（HTTP / websocket 五端与无头服务端通用；VOICEPEAK 走本机
/// 命令行，只在桌面可用）。
/// 平台相关的系统 TTS 由 app 侧补进 [TtsProviderRegistry]。
library;

import 'package:fushi_engine/tts/providers/azure_tts_provider.dart';
import 'package:fushi_engine/tts/providers/edge_tts_provider.dart';
import 'package:fushi_engine/tts/providers/google_cloud_tts_provider.dart';
import 'package:fushi_engine/tts/providers/gpt_sovits_tts_provider.dart';
import 'package:fushi_engine/tts/providers/irodori_server_tts_provider.dart';
import 'package:fushi_engine/tts/providers/irodori_tts_provider.dart';
import 'package:fushi_engine/tts/providers/openai_compatible_tts_provider.dart';
import 'package:fushi_engine/tts/providers/translate_tts_providers.dart';
import 'package:fushi_engine/tts/providers/voicepeak_tts_provider.dart';
import 'package:fushi_engine/tts/providers/voicevox_tts_provider.dart';
import 'package:fushi_engine/tts/tts_provider.dart';

/// 设置页「添加声音」的展示顺序：自建主力 → 免费在线 → 需密钥的官方在线。
const List<TtsProviderDescriptor> kBuiltinTtsProviders =
    <TtsProviderDescriptor>[
      GptSovitsTtsDescriptor(),
      IrodoriTtsDescriptor(),
      // 官方 Irodori-TTS-Server（OpenAI 兼容，默认 :8088）；与上面的工作台并存。
      IrodoriServerTtsDescriptor(),
      // 通用 OpenAI 兼容语音接口（本机 VPTTS 等，默认 :8000）。
      OpenAiCompatibleTtsDescriptor(),
      // VOICEVOX 兼容 HTTP API 的三家（默认端口不同；其它兼容引擎改地址即可）。
      VoicevoxTtsDescriptor(),
      AivisSpeechTtsDescriptor(),
      SharevoxTtsDescriptor(),
      // VOICEPEAK 只有命令行（桌面三端；移动端 isAvailable=false）。
      VoicepeakTtsDescriptor(),
      EdgeTtsDescriptor(),
      MicrosoftTranslatorTtsDescriptor(),
      GoogleTranslateTtsDescriptor(),
      AzureTtsDescriptor(),
      GoogleCloudTtsDescriptor(),
    ];
