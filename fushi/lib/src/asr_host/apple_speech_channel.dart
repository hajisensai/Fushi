/// Apple 系统语音转录（iOS 26 / macOS 26 的 `SpeechAnalyzer`）的平台能力面。
///
/// 与系统 OCR 那条同一套哲学：原生侧只回答「本机能不能用」和「给一个音频文件返回
/// 若干条带时间的文本」，切句、拼 SRT、写任务目录全留在 Dart 侧——**产物必须与
/// ONNX 后端逐字节同构**，否则下游对齐链路要为它开第二条路。
///
/// 「不用下模型」的**准确说法**：不用下我们那 1 GB ONNX，但系统的语言资产仍要下
/// （`AssetInventory`），只是由系统保管、多 app 共享、不占我们的包体。
library;

import 'package:flutter/services.dart';

import 'package:fushi_asr_core/asr_core.dart';

/// 平台通道。原生侧实现同名方法（`apple/FushiSpeechTranscriber.swift`）。
const MethodChannel kAppleSpeechChannel =
    MethodChannel('app.fushi.reader/apple_speech');

/// 原生给回的一条结果：一句话 + 它在音频里的区间 + 逐词起点。
class AppleSpeechSegment {
  const AppleSpeechSegment({
    required this.text,
    required this.startMs,
    required this.endMs,
    this.tokens = const <String>[],
    this.tokenOffsetsMs = const <int>[],
  });

  final String text;
  final int startMs;
  final int endMs;

  /// 逐词文本与起点（毫秒）。两者等长；原生没给词级时间时同为空。
  final List<String> tokens;
  final List<int> tokenOffsetsMs;
}

/// 一次转录的结果。
class AppleSpeechResult {
  const AppleSpeechResult({required this.segments, required this.durationMs});

  final List<AppleSpeechSegment> segments;
  final int durationMs;
}

/// 系统语音转录不可用（OS 太老 / 语言没有模型 / 资产装不上）。
///
/// 与「这次识别失败」分开：调用方据此该换引擎或提示装语言，而不是重试这个文件。
class AppleSpeechUnavailable implements Exception {
  const AppleSpeechUnavailable(this.reason);

  final String reason;

  @override
  String toString() => 'AppleSpeechUnavailable($reason)';
}

/// 平台能力接口。测试注 fake，生产走 [MethodChannelAppleSpeech]。
abstract interface class AppleSpeechPlatform {
  Future<bool> isAvailable();

  /// 本机这套 API 认得的语言标签（BCP-47，如 `ja-JP`）。
  Future<List<String>> supportedLocales();

  /// 已经装好资产、可以离线直接跑的语言标签。
  Future<List<String>> installedLocales();

  /// 确保该语言的资产就位（已就位时不发网络请求）。
  Future<void> prepare(String locale);

  /// 转录一个本地音频文件。[onProgress] 收原生反向发来的进度。
  Future<AppleSpeechResult> transcribe({
    required String path,
    required String locale,
    void Function(int processedMs, int totalMs)? onProgress,
  });

  /// 请求取消进行中的转录。
  Future<void> cancel();
}

class MethodChannelAppleSpeech implements AppleSpeechPlatform {
  MethodChannelAppleSpeech({MethodChannel? channel})
      : _channel = channel ?? kAppleSpeechChannel;

  final MethodChannel _channel;
  void Function(int processedMs, int totalMs)? _onProgress;
  bool _handlerInstalled = false;

  @override
  Future<bool> isAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      // 这个平台没有原生侧——「没有」不是错误，是当前事实（与系统 OCR 同一条纪律）。
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<List<String>> supportedLocales() => _locales('supportedLocales');

  @override
  Future<List<String>> installedLocales() => _locales('installedLocales');

  Future<List<String>> _locales(String method) async {
    try {
      final List<Object?>? raw = await _channel.invokeMethod<List<Object?>>(
        method,
      );
      return <String>[
        for (final Object? entry in raw ?? const <Object?>[])
          if (entry is String && entry.isNotEmpty) entry,
      ];
    } on MissingPluginException {
      return const <String>[];
    } on PlatformException {
      return const <String>[];
    }
  }

  @override
  Future<void> prepare(String locale) async {
    try {
      await _channel.invokeMethod<bool>('prepare', <String, Object?>{
        'locale': locale,
      });
    } on MissingPluginException {
      throw const AppleSpeechUnavailable('missing_plugin');
    } on PlatformException catch (error) {
      throw AppleSpeechUnavailable(_reasonOf(error));
    }
  }

  @override
  Future<AppleSpeechResult> transcribe({
    required String path,
    required String locale,
    void Function(int processedMs, int totalMs)? onProgress,
  }) async {
    _onProgress = onProgress;
    if (!_handlerInstalled) {
      _handlerInstalled = true;
      _channel.setMethodCallHandler((MethodCall call) async {
        if (call.method != 'progress') return null;
        final Map<Object?, Object?> args =
            (call.arguments as Map<Object?, Object?>?) ??
                const <Object?, Object?>{};
        _onProgress?.call(
          _asInt(args['processedMs']),
          _asInt(args['totalMs']),
        );
        return null;
      });
    }
    try {
      final Map<Object?, Object?>? raw =
          await _channel.invokeMapMethod<Object?, Object?>(
        'transcribe',
        <String, Object?>{'path': path, 'locale': locale},
      );
      if (raw == null) throw const AppleSpeechUnavailable('empty_response');
      return parseAppleSpeechPayload(raw);
    } on MissingPluginException {
      throw const AppleSpeechUnavailable('missing_plugin');
    } on PlatformException catch (error) {
      // OS 太老 / 语言没模型 / 资产装不上 → 不可用；其余（含取消）原样抛。
      const Set<String> unavailable = <String>{
        'UNSUPPORTED_OS',
        'LOCALE_UNSUPPORTED',
        'ASSET_INSTALL_FAILED',
      };
      if (unavailable.contains(error.code)) {
        throw AppleSpeechUnavailable(_reasonOf(error));
      }
      rethrow;
    } finally {
      _onProgress = null;
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _channel.invokeMethod<bool>('cancel');
    } on MissingPluginException {
      // 没有原生侧就没有在跑的任务，取消是无事可做。
    } on PlatformException {
      // 取消失败不该盖过调用方正在处理的那个错误。
    }
  }

  static String _reasonOf(PlatformException error) => error.code.toLowerCase();
}

/// 纯函数：把原生回传的 map 解析成 [AppleSpeechResult]。
///
/// 单独抽出来是为了让**契约**有一个可测的落点：Swift 改一个字段名，这里的测试立刻
/// 红，而不是等到真机上转出一份空字幕——那种失败在设备上看起来和「这段没人说话」
/// 一模一样。
///
/// 容错取向与系统 OCR 那条一致：**逐条丢弃坏行，不整份抛**（一句时间戳错不该毁掉
/// 整本），但**整份缺时长**要抛——没有分母，进度和结尾 cue 都没法算。
AppleSpeechResult parseAppleSpeechPayload(Map<Object?, Object?> raw) {
  final int durationMs = _asInt(raw['durationMs']);
  if (durationMs <= 0) {
    throw const AppleSpeechUnavailable('invalid_duration');
  }
  final Object? rawSegments = raw['segments'];
  final List<AppleSpeechSegment> segments = <AppleSpeechSegment>[];
  if (rawSegments is List) {
    for (final Object? entry in rawSegments) {
      if (entry is! Map) continue;
      final Map<Object?, Object?> map = entry.cast<Object?, Object?>();
      final String text = (map['text'] ?? '').toString().trim();
      if (text.isEmpty) continue;
      final int startMs = _asInt(map['startMs']);
      final int endMs = _asInt(map['endMs']);
      // 退化区间：留着会在 SRT 里变成一条零长甚至倒挂的字幕。
      if (endMs <= startMs) continue;
      final List<String> tokens = <String>[];
      final List<int> offsets = <int>[];
      final Object? rawTokens = map['tokens'];
      if (rawTokens is List) {
        for (final Object? token in rawTokens) {
          if (token is! Map) continue;
          final Map<Object?, Object?> t = token.cast<Object?, Object?>();
          final String piece = (t['text'] ?? '').toString();
          if (piece.isEmpty) continue;
          tokens.add(piece);
          offsets.add(_asInt(t['startMs']));
        }
      }
      segments.add(
        AppleSpeechSegment(
          text: text,
          startMs: startMs,
          endMs: endMs,
          tokens: tokens,
          tokenOffsetsMs: offsets,
        ),
      );
    }
  }
  return AppleSpeechResult(segments: segments, durationMs: durationMs);
}

/// 纯函数：把原生结果拼成与 ONNX 后端同构的 cue 列表。
///
/// [fileIndex] 是这个音频在整本里的序号，[offsetMs] 是它在拼接时间轴上的起点——
/// 多文件有声书转出来的是**单时间轴** SRT（与 ONNX 后端一致），所以每个文件的时间
/// 都要加上前面所有文件的时长。
///
/// 逐词起点同样要平移；词数与 [AsrCue.tokens] 不等长会让下游一条都不挂
/// （`attachAsrCueTokenTiming` 的纪律），所以两个列表在这里就保持等长。
List<AsrCue> appleSpeechCues(
  List<AppleSpeechSegment> segments, {
  required int fileIndex,
  required int offsetMs,
}) {
  return <AsrCue>[
    for (final AppleSpeechSegment segment in segments)
      AsrCue(
        startMs: segment.startMs + offsetMs,
        endMs: segment.endMs + offsetMs,
        text: segment.text,
        audioFileIndex: fileIndex,
        tokens: segment.tokens,
        tokenOffsetsMs: <int>[
          for (final int offset in segment.tokenOffsetsMs) offset + offsetMs,
        ],
      ),
  ];
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}
