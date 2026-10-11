/// TTS 引擎契约：描述符（静态信息 + 参数表 + 由预设造实例）与实例（真合成）。
library;

import 'dart:io';

import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:fushi_engine/utils/net/app_http.dart';

/// 参数在设置页的输入形态。
enum TtsParamKind { url, text, secret, choice, voice }

/// 引擎的一个可配置参数。UI 按 [key] 取文案（app 侧 i18n），按 [kind] 选控件。
class TtsParamSpec {
  const TtsParamSpec({
    required this.key,
    required this.kind,
    this.required = false,
    this.defaultValue,
    this.choices = const <String>[],
    this.affectsAudio = true,
  });

  final String key;
  final TtsParamKind kind;
  final bool required;
  final String? defaultValue;

  /// [TtsParamKind.choice] 的取值（显示文案由 app 按值翻译或原样显示）。
  final List<String> choices;

  /// 改了它声音会变 → 进缓存键。地址、密钥这类不影响音色的参数为 false：
  /// 换个局域网 IP 不该让整本书的缓存失效。
  final bool affectsAudio;
}

/// 宿主注入：出站 HTTP 与诊断日志。默认走全应用代理装配点。
class TtsHost {
  const TtsHost({this.httpClientFactory = _defaultHttpClient, this.log});

  final HttpClient Function() httpClientFactory;

  /// 只会收到错误码与 HTTP 状态这类可公开信息。
  final void Function(String message)? log;

  static HttpClient _defaultHttpClient() => createAppHttpClient();
}

/// 一个合成实例（绑定一份预设的地址 / 凭据 / 声音）。
abstract class TtsProvider {
  TtsCapabilities get capabilities;

  /// 把 [text] 合成到 [outputPath]。失败抛 [TtsFailure]。
  Future<TtsResult> synthesize(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
  });

  /// 可选声音。不支持列举的引擎返回空列表。
  Future<List<TtsVoice>> listVoices({TtsCancelToken? cancel}) async =>
      const <TtsVoice>[];

  Future<void> dispose() async {}
}

/// 引擎描述符：一类引擎一个单例。
abstract class TtsProviderDescriptor {
  const TtsProviderDescriptor();

  /// 持久化 id（写进预设，不可改名）。
  String get id;

  TtsCapabilities get capabilities;

  List<TtsParamSpec> get params;

  /// 本平台能不能用（系统 TTS 之类受平台限制）。
  bool get isAvailable => true;

  TtsProvider create(TtsVoicePreset preset, TtsHost host);

  /// 预设缺什么。空列表 = 可用。返回缺失 / 非法的参数 key。
  List<String> validate(TtsVoicePreset preset) {
    final List<String> problems = <String>[];
    for (final TtsParamSpec spec in params) {
      final String value = preset.param(spec.key, fallback: spec.defaultValue);
      if (spec.required && value.trim().isEmpty) {
        problems.add(spec.key);
        continue;
      }
      if (spec.kind == TtsParamKind.url && value.trim().isNotEmpty) {
        final Uri? uri = Uri.tryParse(value.trim());
        if (uri == null ||
            !(uri.isScheme('http') || uri.isScheme('https')) ||
            uri.host.isEmpty) {
          problems.add(spec.key);
        }
      }
    }
    return problems;
  }

  /// 进缓存键的音色身份：引擎 id + 影响声音的参数 + 预设版本。
  Map<String, Object?> audioIdentity(
    TtsVoicePreset preset,
  ) => <String, Object?>{
    'provider': id,
    'revision': preset.revision,
    for (final TtsParamSpec spec in params)
      if (spec.affectsAudio && spec.kind != TtsParamKind.secret)
        spec.key: preset.param(spec.key, fallback: spec.defaultValue).trim(),
  };
}

/// 引擎注册表。app 在启动时把平台相关的描述符（系统 TTS）补进来。
class TtsProviderRegistry {
  TtsProviderRegistry(Iterable<TtsProviderDescriptor> descriptors)
    : _byId = <String, TtsProviderDescriptor>{
        for (final TtsProviderDescriptor d in descriptors) d.id: d,
      };

  final Map<String, TtsProviderDescriptor> _byId;

  TtsProviderDescriptor? operator [](String id) => _byId[id];

  List<TtsProviderDescriptor> get available => <TtsProviderDescriptor>[
    for (final TtsProviderDescriptor d in _byId.values)
      if (d.isAvailable) d,
  ];
}
