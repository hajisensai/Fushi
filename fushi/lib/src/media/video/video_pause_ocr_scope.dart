/// 暂停时识别画面文字（OCR 点字查词）的范围。
///
/// 图形字幕（PGS / VobSub / DVB）由 libmpv 画进画面、没有 Dart 侧文字，暂停 OCR 是它
/// 唯一的查词途径；其它视频里画面上的字（硬字幕、标题卡、招牌）同样只能靠 OCR 查。
/// 每次暂停都要截帧跑一遍整帧检测，低置信度还会按漫画 OCR 档位交给大模型，选了
/// Google Lens 引擎还会把画面上传给 Google，所以给用户一个范围开关。
///
/// BUG-3342（用户 2026-10-14）：默认 [off]，由用户手动开启；只在暂停到图片字幕帧时
/// 提示「可开启」（[offersEnableHint]），文本字幕或没有字幕的视频一律不提示。
library;

enum VideoPauseOcrScope {
  /// 所有视频（硬字幕、画面文字；2026-10-13 加入，需用户手动选）。
  all('all'),

  /// 只在播放图形字幕时识别（扩大前的行为）。
  graphicSubtitles('graphic_subtitles'),

  /// 不识别（默认，BUG-3342）。
  off('off');

  /// 没存过偏好（或存的值认不出）时的取值：不自动识别，由用户手动开启。
  static const VideoPauseOcrScope defaultScope = VideoPauseOcrScope.off;

  const VideoPauseOcrScope(this.wireName);

  /// 偏好持久化用的稳定字符串键（勿随枚举名改动）。
  final String wireName;

  static VideoPauseOcrScope fromWireName(String? name) {
    for (final VideoPauseOcrScope scope in VideoPauseOcrScope.values) {
      if (scope.wireName == name) return scope;
    }
    return defaultScope;
  }

  /// 暂停的这一帧要不要提示「可开启 OCR 识别」：只有识别关着、画面上又是图片字幕
  /// （没有 Dart 侧文字、OCR 是唯一查词途径）时才提示。文本字幕、无字幕不提示。
  bool offersEnableHint({required bool graphicSubtitleActive}) =>
      this == VideoPauseOcrScope.off && graphicSubtitleActive;

  /// 暂停的这一帧该不该识别。
  ///
  /// [graphicSubtitleActive]：libmpv 正在自绘字幕轨（画面里的字幕没有 Dart 文字）。
  ///
  /// [all] 识别的是画面里烧进去的字（硬字幕、标题卡、招牌），与文字字幕轨无关：
  /// Fushi 自绘的文字字幕不在 libmpv 截帧里，OCR 本来就识别不到它。以前文字字幕
  /// 在屏 / 内封文字字幕还在抽取时整帧让位，暂停落在台词显示期间（想看这句时最常见）
  /// 就静默不识别（BUG-3560，用户 2026-10-19：「字幕和 OCR 有什么关系，我要看的是
  /// 视频里的文字」）。
  bool shouldRecognize({required bool graphicSubtitleActive}) => switch (this) {
    VideoPauseOcrScope.off => false,
    VideoPauseOcrScope.graphicSubtitles => graphicSubtitleActive,
    VideoPauseOcrScope.all => true,
  };
}
