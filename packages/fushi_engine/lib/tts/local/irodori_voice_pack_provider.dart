/// 把声音包接进现有的「预设 → 引擎」管线：每个声音包的每组参考音频是一份虚拟预设
/// （id 就是声音 id `pack:<packId>/<group>`，见 `irodori_voice_pack.dart`），引擎实例
/// 把单句交给批处理 worker（一句一个任务）。小说制作台、单句重生成、试听都按普通预设
/// 走缓存与调度，不另写一条路径；整卷批量合成直接用 [IrodoriBatchWorker.run]。
///
/// 这个描述符**不进** `TtsProviderRegistry`（那里的引擎会出现在「添加声音」列表里，
/// 而声音包在声音包管理页里维护），由 app 的制作侧按 [kIrodoriPackProviderId] 单独查。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/local/irodori_batch_worker.dart';
import 'package:fushi_engine/tts/local/irodori_local_engine.dart';
import 'package:fushi_engine/tts/local/irodori_voice_pack.dart';
import 'package:fushi_engine/tts/tts_direction.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

/// 声音包虚拟预设的引擎 id（不会持久化进预设清单）。
const String kIrodoriPackProviderId = 'irodori_pack';

/// 虚拟预设的参数键。
abstract final class IrodoriPackParams {
  static const String pack = 'pack';
  static const String group = 'group';
  static const String character = 'character';
  static const String adapter = 'adapter';

  /// JSON 数组。
  static const String refs = 'refs';
  static const String steps = 'steps';
  static const String cfgText = 'cfgText';
  static const String cfgSpeaker = 'cfgSpeaker';
  static const String seed = 'seed';
}

/// 一个声音包一组参考音频 → 虚拟预设（参数是包的快照，缓存键据此计算）。
TtsVoicePreset irodoriVoicePackPreset(
  IrodoriVoicePack pack,
  IrodoriRefGroup group,
) => TtsVoicePreset(
  id: IrodoriPackVoiceId(pack.id, group.name).wire,
  providerId: kIrodoriPackProviderId,
  name: pack.groups.length > 1
      ? '${pack.character} · ${group.name}'
      : pack.character,
  revision: pack.revision,
  params: <String, String>{
    IrodoriPackParams.pack: pack.id,
    IrodoriPackParams.group: group.name,
    IrodoriPackParams.character: pack.character,
    IrodoriPackParams.adapter: pack.adapterDir ?? '',
    IrodoriPackParams.refs: jsonEncode(group.files),
    IrodoriPackParams.steps: '${pack.sampling.steps}',
    IrodoriPackParams.cfgText: '${pack.sampling.cfgText}',
    IrodoriPackParams.cfgSpeaker: '${pack.sampling.cfgSpeaker}',
    IrodoriPackParams.seed: '${pack.sampling.seed}',
  },
);

/// 所有声音包的虚拟预设（结构不完整的包跳过）。
List<TtsVoicePreset> irodoriVoicePackPresets(
  Iterable<IrodoriVoicePack> packs,
) => <TtsVoicePreset>[
  for (final IrodoriVoicePack pack in packs)
    if (pack.validate().isEmpty)
      for (final IrodoriRefGroup g in pack.groups)
        irodoriVoicePackPreset(pack, g),
];

/// 虚拟预设 → 一句请求（纯函数）。参数坏了返回 null。
IrodoriBatchItem? irodoriBatchItemFromPreset(
  TtsVoicePreset preset, {
  required String id,
  required String text,
  required String outputPath,
}) {
  final List<String> refs;
  try {
    final Object? raw = jsonDecode(preset.param(IrodoriPackParams.refs));
    if (raw is! List) return null;
    refs = <String>[
      for (final Object? f in raw)
        if (f is String && f.isNotEmpty) f,
    ];
  } on FormatException {
    return null;
  }
  final String adapter = preset.param(IrodoriPackParams.adapter).trim();
  final int? steps = int.tryParse(preset.param(IrodoriPackParams.steps));
  final double? cfgText = double.tryParse(
    preset.param(IrodoriPackParams.cfgText),
  );
  final double? cfgSpeaker = double.tryParse(
    preset.param(IrodoriPackParams.cfgSpeaker),
  );
  final int? seed = int.tryParse(preset.param(IrodoriPackParams.seed));
  if (refs.isEmpty || steps == null || cfgText == null || cfgSpeaker == null) {
    return null;
  }
  return IrodoriBatchItem(
    id: id,
    text: text,
    refs: refs,
    outputPath: outputPath,
    adapterDir: adapter.isEmpty ? null : adapter,
    seconds: irodoriManualSeconds(text, lora: adapter.isNotEmpty),
    seed: seed ?? 0,
    steps: steps,
    cfgText: cfgText,
    cfgSpeaker: cfgSpeaker,
  );
}

/// 按演出参数改写一句请求：[direction] 给了种子 / 时长就用它的（时长为 null 时保留
/// [item] 自带的短句规则结果），否则原样。
IrodoriBatchItem irodoriDirectedItem(
  IrodoriBatchItem item,
  TtsDirection direction,
) => IrodoriBatchItem(
  id: item.id,
  text: item.text,
  refs: item.refs,
  outputPath: item.outputPath,
  adapterDir: item.adapterDir,
  seconds: direction.durationSeconds ?? item.seconds,
  seed: direction.seed ?? item.seed,
  steps: item.steps,
  cfgText: item.cfgText,
  cfgSpeaker: item.cfgSpeaker,
);

/// 声音包虚拟预设能表达的演出字段：种子、给定时长都收；挂没挂 LoRA 看 adapter 参数。
TtsDirectionSupport irodoriPackDirectionSupport(TtsVoicePreset preset) =>
    TtsDirectionSupport(
      seed: true,
      duration: true,
      adapter: preset.param(IrodoriPackParams.adapter).trim().isNotEmpty,
    );

/// 声音包引擎描述符（见库注释：不进注册表）。
class IrodoriVoicePackTtsDescriptor extends TtsProviderDescriptor {
  const IrodoriVoicePackTtsDescriptor(this.engine);

  final IrodoriLocalEngine engine;

  @override
  String get id => kIrodoriPackProviderId;

  @override
  TtsCapabilities get capabilities => const TtsCapabilities(
    timing: TtsTimingGranularity.sentence,
    online: false,
    needsCredential: false,
    // 显存只够一个模型实例，worker 串行合成。
    maxConcurrency: 1,
    maxInputLength: kIrodoriMaxLineChars,
  );

  @override
  TtsProviderCategory get category => TtsProviderCategory.external;

  @override
  List<TtsParamSpec> get params => const <TtsParamSpec>[
    TtsParamSpec(
      key: IrodoriPackParams.pack,
      kind: TtsParamKind.text,
      required: true,
      affectsAudio: false,
    ),
    TtsParamSpec(
      key: IrodoriPackParams.group,
      kind: TtsParamKind.text,
      required: true,
      affectsAudio: false,
    ),
    TtsParamSpec(key: IrodoriPackParams.adapter, kind: TtsParamKind.text),
    TtsParamSpec(
      key: IrodoriPackParams.refs,
      kind: TtsParamKind.text,
      required: true,
    ),
    TtsParamSpec(key: IrodoriPackParams.steps, kind: TtsParamKind.text),
    TtsParamSpec(key: IrodoriPackParams.cfgText, kind: TtsParamKind.text),
    TtsParamSpec(key: IrodoriPackParams.cfgSpeaker, kind: TtsParamKind.text),
    TtsParamSpec(key: IrodoriPackParams.seed, kind: TtsParamKind.text),
  ];

  /// 桌面端、本机 Irodori 环境装好且 v4-Large 已下载。
  @override
  bool get isAvailable => engine.isSupported && engine.batchModelReady;

  @override
  TtsProvider create(TtsVoicePreset preset, TtsHost host) =>
      _IrodoriVoicePackProvider(engine.batchWorker, preset, capabilities);
}

class _IrodoriVoicePackProvider extends TtsProvider
    implements TtsDirectedSynthesis {
  _IrodoriVoicePackProvider(this._worker, this._preset, this.capabilities);

  final IrodoriBatchWorker _worker;
  final TtsVoicePreset _preset;

  @override
  final TtsCapabilities capabilities;

  @override
  TtsDirectionSupport get directionSupport =>
      irodoriPackDirectionSupport(_preset);

  static int _seq = 0;

  @override
  Future<TtsResult> synthesize(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
  }) => synthesizeDirected(
    text,
    outputPath: outputPath,
    cancel: cancel,
    direction: TtsDirection.none,
  );

  /// 单句也走 worker（一句一个任务）；种子 / 给定时长按 [direction] 改写请求。整卷
  /// 批量合成由漫画生成端直接调 [IrodoriBatchWorker.run]（按参考音频组成批）。
  @override
  Future<TtsResult> synthesizeDirected(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
    required TtsDirection direction,
  }) async {
    final IrodoriBatchItem? base = irodoriBatchItemFromPreset(
      _preset,
      id: 'single',
      text: text,
      // worker 写 wav（按扩展名选格式）；调用方的路径可能是临时名，写完再搬过去。
      outputPath: '$outputPath.irodori.wav',
    );
    if (base == null) throw const TtsFailure(TtsFailureCode.notConfigured);
    final IrodoriBatchItem item = irodoriDirectedItem(base, direction);
    final IrodoriBatchResult r = await _worker.run(
      IrodoriBatchJob(id: 'single-${_seq++}', items: <IrodoriBatchItem>[item]),
      cancel: cancel,
    );
    if (r.cancelled || cancel.isCancelled) {
      throw const TtsFailure(TtsFailureCode.cancelled);
    }
    final IrodoriBatchFailure? failure = r.failure;
    if (failure != null) {
      throw switch (failure) {
        IrodoriBatchFailure.notInstalled => const TtsFailure(
          TtsFailureCode.notConfigured,
          'notInstalled',
        ),
        // 进程中途退出：下一次会重新拉起，值得重试。
        IrodoriBatchFailure.exited => const TtsFailure(
          TtsFailureCode.serverError,
          'exited',
        ),
        // 起不来 / 加载失败 / 协议不对：重试也一样，不让重试循环反复拉起 13 GB 模型。
        _ => TtsFailure.withRetry(
          TtsFailureCode.serverError,
          detail: failure.name,
          transient: false,
        ),
      };
    }
    final IrodoriBatchLineResult? line = r.lines['single'];
    if (line == null || !line.ok || line.outputPath == null) {
      // 异常原文只进 worker 日志尾（可能带文本片段），这里只给错误码。
      throw const TtsFailure(TtsFailureCode.rejected);
    }
    await File(line.outputPath!).rename(outputPath);
    return const TtsResult(format: TtsAudioFormat.wav);
  }
}
