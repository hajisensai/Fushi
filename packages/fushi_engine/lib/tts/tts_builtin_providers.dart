/// 引擎层内置的 TTS 引擎（纯 HTTP / websocket，五端与无头服务端通用）。
/// 平台相关的系统 TTS 由 app 侧补进 [TtsProviderRegistry]。
library;

import 'package:fushi_engine/tts/providers/azure_tts_provider.dart';
import 'package:fushi_engine/tts/providers/edge_tts_provider.dart';
import 'package:fushi_engine/tts/providers/google_cloud_tts_provider.dart';
import 'package:fushi_engine/tts/providers/gpt_sovits_tts_provider.dart';
import 'package:fushi_engine/tts/providers/irodori_server_tts_provider.dart';
import 'package:fushi_engine/tts/providers/irodori_tts_provider.dart';
import 'package:fushi_engine/tts/providers/translate_tts_providers.dart';
import 'package:fushi_engine/tts/tts_provider.dart';

/// 设置页「添加声音」的展示顺序：自建主力 → 免费在线 → 需密钥的官方在线。
const List<TtsProviderDescriptor> kBuiltinTtsProviders =
    <TtsProviderDescriptor>[
      GptSovitsTtsDescriptor(),
      IrodoriTtsDescriptor(),
      // 官方 Irodori-TTS-Server（OpenAI 兼容，默认 :8088）；与上面的工作台并存。
      IrodoriServerTtsDescriptor(),
      EdgeTtsDescriptor(),
      MicrosoftTranslatorTtsDescriptor(),
      GoogleTranslateTtsDescriptor(),
      AzureTtsDescriptor(),
      GoogleCloudTtsDescriptor(),
    ];
