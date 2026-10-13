/// TTS 引擎层的值类型：请求、结果、能力、声音、错误。
///
/// 引擎层只认「一段文本进、一个音频文件出」：分句、ruby 读音、阅读器坐标都在调用方
/// 完成，这里不碰正文结构。
library;

/// 合成产物的容器格式。时长探测与播放器 MIME 都按它分派。
enum TtsAudioFormat {
  wav('wav', 'audio/wav'),
  mp3('mp3', 'audio/mpeg');

  const TtsAudioFormat(this.extension, this.mimeType);

  final String extension;
  final String mimeType;

  static TtsAudioFormat? parse(String? raw) {
    for (final TtsAudioFormat f in values) {
      if (f.extension == raw) return f;
    }
    return null;
  }
}

/// 引擎能给出的时间粒度。`sentence` = 只有整段音频时长（调用方一段一句）。
enum TtsTimingGranularity { sentence, word }

/// 引擎静态能力，供设置页标注与调度参数使用。
class TtsCapabilities {
  const TtsCapabilities({
    required this.timing,
    required this.online,
    required this.needsCredential,
    this.maxConcurrency = 1,
    this.maxInputLength = 300,
  });

  final TtsTimingGranularity timing;

  /// 正文会被发到第三方服务器（设置页据此给隐私提示）。自建服务不算。
  final bool online;

  /// 必须填 API key 才能用。
  final bool needsCredential;

  /// 同一时刻最多并发几个合成请求（自建 GPU 服务通常只能 1）。
  final int maxConcurrency;

  /// 单次合成文本上限（UTF-16 码元）。调用方分句时不得超过。
  final int maxInputLength;
}

/// 引擎可用的一个声音（列表展示 + 预设里存 [id]）。
class TtsVoice {
  const TtsVoice({
    required this.id,
    required this.displayName,
    required this.locale,
    this.gender,
  });

  final String id;
  final String displayName;

  /// BCP-47，如 `ja-JP`。
  final String locale;
  final String? gender;
}

/// 合成产物里的一个词边界：[textOffset]/[textLength] 是相对请求文本的 UTF-16
/// 偏移，[offsetMs] 相对本段音频起点。
class TtsBoundary {
  const TtsBoundary({
    required this.textOffset,
    required this.textLength,
    required this.offsetMs,
    required this.durationMs,
  });

  final int textOffset;
  final int textLength;
  final int offsetMs;
  final int durationMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'o': textOffset,
    'l': textLength,
    't': offsetMs,
    'd': durationMs,
  };

  static TtsBoundary? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? o = raw['o'], l = raw['l'], t = raw['t'], d = raw['d'];
    if (o is! int || l is! int || t is! int || d is! int) return null;
    return TtsBoundary(
      textOffset: o,
      textLength: l,
      offsetMs: t,
      durationMs: d,
    );
  }
}

/// 一次合成请求。[params] 是预设里与音色有关的引擎参数（不含凭据）。
class TtsRequest {
  const TtsRequest({
    required this.text,
    required this.outputPath,
    required this.params,
    this.locale = 'ja-JP',
  });

  final String text;

  /// 引擎把音频写到这里（调用方负责原子发布，见 `TtsAudioCache`）。
  final String outputPath;
  final Map<String, Object?> params;
  final String locale;
}

/// 合成产物。
class TtsResult {
  const TtsResult({
    required this.format,
    this.boundaries = const <TtsBoundary>[],
  });

  /// 引擎声称的格式。真实格式与时长由缓存层按内容探测（不信引擎自报）。
  final TtsAudioFormat format;
  final List<TtsBoundary> boundaries;
}

/// 稳定错误码：UI 只按它出文案，日志也只记它，不记响应正文 / 凭据。
enum TtsFailureCode {
  notConfigured,
  network,
  timeout,
  unauthorized,
  rateLimited,
  serverError,
  badResponse,

  /// 服务端拒绝了这一句（HTTP 400/404/422：文本或参数不被接受）。重试同一句通常无用。
  rejected,

  /// 服务正忙（HTTP 409：本机工作台有别的任务在跑）。稍后重试即可。
  busy,
  unsupported,
  cancelled,
}

class TtsFailure implements Exception {
  const TtsFailure(this.code, [this.detail]);

  final TtsFailureCode code;

  /// 只放可公开的诊断（HTTP 状态码等），绝不放响应正文或密钥。
  final String? detail;

  @override
  String toString() => detail == null
      ? 'TtsFailure(${code.name})'
      : 'TtsFailure(${code.name}: $detail)';
}

/// 取消令牌：调用方 [cancel] 后，引擎尽快中止并抛 [TtsFailureCode.cancelled]。
class TtsCancelToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final List<void Function()> listeners = List<void Function()>.of(
      _listeners,
    );
    _listeners.clear();
    for (final void Function() l in listeners) {
      l();
    }
  }

  /// 注册取消回调；已取消则立即执行。返回注销函数。
  void Function() onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void throwIfCancelled() {
    if (_cancelled) throw const TtsFailure(TtsFailureCode.cancelled);
  }
}
