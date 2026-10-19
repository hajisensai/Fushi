/// 字幕管线各阶段之间传递的一条字幕（识别稿 → 校对 → 写法统一 → 拆分 → 导出）。
///
/// 时间轴永远来自识别阶段（S1/S2）；后续阶段只改 [SubtitleDraftCue.text]。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_asr_core/asr_core.dart' show AsrCueTokenTiming;

/// 一条字幕稿。
class SubtitleDraftCue {
  const SubtitleDraftCue({
    required this.startMs,
    required this.endMs,
    required this.text,
    this.speaker,
    this.alternatives = const <String>[],
    this.tokenTiming,
  });

  factory SubtitleDraftCue.fromJson(Map<String, Object?> json) {
    final Object? timing = json['tokenTiming'];
    return SubtitleDraftCue(
      startMs: (json['startMs'] as num).round(),
      endMs: (json['endMs'] as num).round(),
      text: json['text'] as String? ?? '',
      speaker: json['speaker'] as String?,
      alternatives: <String>[
        for (final Object? a
            in (json['alternatives'] as List<Object?>? ?? const <Object?>[]))
          if (a is String) a,
      ],
      tokenTiming: timing is Map ? _timingFromJson(timing) : null,
    );
  }

  final int startMs;
  final int endMs;
  final String text;

  /// 说话人标签（MOSS 等带分离的后端才有）；null = 未知。
  final String? speaker;

  /// 其它识别稿在同一时段的文本（S3 的候选稿）；主稿就是 [text]。
  final List<String> alternatives;

  /// 主稿的逐 token 时间（形状同上游 `AsrCueTokenTiming`：拼接即 [text] 的听写
  /// 文本，偏移相对 [startMs]）；校对改过文字后只能当切点参考。
  final AsrCueTokenTiming? tokenTiming;

  SubtitleDraftCue copyWith({
    int? startMs,
    int? endMs,
    String? text,
    String? speaker,
    List<String>? alternatives,
    AsrCueTokenTiming? tokenTiming,
  }) => SubtitleDraftCue(
    startMs: startMs ?? this.startMs,
    endMs: endMs ?? this.endMs,
    text: text ?? this.text,
    speaker: speaker ?? this.speaker,
    alternatives: alternatives ?? this.alternatives,
    tokenTiming: tokenTiming ?? this.tokenTiming,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'startMs': startMs,
    'endMs': endMs,
    'text': text,
    if (speaker != null) 'speaker': speaker,
    if (alternatives.isNotEmpty) 'alternatives': alternatives,
    if (tokenTiming != null)
      'tokenTiming': <String, Object?>{
        'tokens': tokenTiming!.tokens,
        'offsetsMs': tokenTiming!.offsetsMs,
        // token 终点（sidecar 的 `e`）：显示拆分（S5）按它量停顿、定切点。
        if (tokenTiming!.endOffsetsMs != null)
          'endOffsetsMs': tokenTiming!.endOffsetsMs,
      },
  };

  static AsrCueTokenTiming? _timingFromJson(Map<Object?, Object?> json) {
    final Object? tokens = json['tokens'];
    final Object? offsets = json['offsetsMs'];
    final Object? ends = json['endOffsetsMs'];
    if (tokens is! List ||
        offsets is! List ||
        tokens.length != offsets.length ||
        (ends != null && (ends is! List || ends.length != tokens.length))) {
      return null;
    }
    return AsrCueTokenTiming(
      tokens: <String>[for (final Object? t in tokens) '$t'],
      offsetsMs: <int>[for (final Object? o in offsets) (o as num).round()],
      endOffsetsMs: ends is List
          ? <int>[for (final Object? e in ends) (e as num).round()]
          : null,
    );
  }
}

/// 一组字幕稿 → JSON 文本（`{"cues": [...]}`）。
String encodeSubtitleDraftCues(List<SubtitleDraftCue> cues) =>
    const JsonEncoder.withIndent(' ').convert(<String, Object?>{
      'cues': <Map<String, Object?>>[
        for (final SubtitleDraftCue c in cues) c.toJson(),
      ],
    });

/// [encodeSubtitleDraftCues] 的逆；形状不对抛 [FormatException]。
List<SubtitleDraftCue> decodeSubtitleDraftCues(String text) {
  final Object? decoded = jsonDecode(text);
  if (decoded is! Map || decoded['cues'] is! List) {
    throw const FormatException('subtitle draft: missing "cues"');
  }
  return <SubtitleDraftCue>[
    for (final Object? c in decoded['cues'] as List<Object?>)
      if (c is Map) SubtitleDraftCue.fromJson(c.cast<String, Object?>()),
  ];
}

/// 统一成全角的感叹号 / 问号（S3、S4 的产物都过这一道）。
String fullWidthSubtitlePunctuation(String text) =>
    text.replaceAll('!', '！').replaceAll('?', '？');

/// 先写 `.tmp` 再改名：进程中途被杀不会留下半截的「已完成」产物。
Future<void> writeSubtitleJobFileAtomic(File file, String content) async {
  await file.parent.create(recursive: true);
  final File tmp = File('${file.path}.tmp');
  await tmp.writeAsString(content, flush: true);
  if (file.existsSync()) await file.delete();
  await tmp.rename(file.path);
}
