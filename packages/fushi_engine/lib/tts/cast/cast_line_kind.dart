/// 台词类型与情绪词表：漫画演出稿与小说选角表共用一套（类型决定转场停顿、声音
/// 指派与是否合成；情绪只标注、不参与合成）。wire 名冻结。
library;

/// 一句的类型（决定转场停顿、声音指派与是否合成）。
enum CastLineKind {
  /// 叙述：第三人称旁白、说明框、标题、信件等成段的正式文字。
  narration('narration'),

  /// 独白字幕（方框里的第一人称内心叙述）。
  monologue('monologue'),

  /// 心声气泡（云朵状的心里话）。
  thought('thought'),

  /// 说出口的台词。
  spoken('spoken'),

  /// 喊。
  shout('shout'),

  /// 嘟囔（小声自言自语）。
  mutter('mutter'),

  /// 不读：拟声词、手写旁注、OCR 噪声。
  skip('skip');

  const CastLineKind(this.wire);

  /// 持久化 / AI 输出里的名字（冻结，不随 Dart 枚举名改）。
  final String wire;

  /// 内心类（独白 / 心声 / 嘟囔）：与说出口之间切换时用更长的转场停顿。
  bool get isInner =>
      this == CastLineKind.monologue ||
      this == CastLineKind.thought ||
      this == CastLineKind.mutter;

  /// 有声音（会进合成与时间表）。
  bool get isAudible => this != CastLineKind.skip;

  static CastLineKind? parse(Object? raw) {
    for (final CastLineKind k in values) {
      if (k.wire == raw) return k;
    }
    return null;
  }
}

/// 情绪封闭词表（只标注、不参与合成，见设计 §5 末）。
enum CastEmotion {
  neutral('neutral'),
  joy('joy'),
  sadness('sadness'),
  anger('anger'),
  surprise('surprise'),
  fear('fear'),
  disgust('disgust'),
  embarrassment('embarrassment'),
  tenderness('tenderness'),
  tension('tension');

  const CastEmotion(this.wire);

  final String wire;

  static CastEmotion? parse(Object? raw) {
    for (final CastEmotion e in values) {
      if (e.wire == raw) return e;
    }
    return null;
  }
}
