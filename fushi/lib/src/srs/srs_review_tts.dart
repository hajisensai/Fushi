/// 复习朗读（TTS）的偏好：复习页 ⋯「复习选项 › 朗读」里改，按 profile 存一个 JSON 偏好
/// `srs_review_tts`（拍板台 YmWT1x57XV）。
///
/// 卡面上的朗读键怎么来、怎么念见引擎侧 srs_card_tts.dart；合成与落盘缓存见
/// srs_card_tts_audio.dart。声音沿用「TTS 兜底声音」（与笔记编辑器「用 TTS 生成」同一项），
/// 模板 `voices=` 能点名某个朗读声音预设。
library;

import 'dart:convert';

import 'package:fushi_anki/fushi_anki_core.dart' show FushiCardFields;
import 'package:fushi_engine/srs/srs_card_tts.dart';
import 'package:meta/meta.dart' show immutable;

/// 复习朗读的几项开关。
@immutable
class SrsReviewTts {
  const SrsReviewTts({
    this.templateTags = true,
    this.speakSelection = true,
    this.fillMissing = false,
    this.fillFields = const <String>{kSrsSentenceAudioField},
    this.autoplay = true,
  });

  /// 认模板里的 Anki `{{tts}}` 标签（渲染成朗读键）。默认开：导入的 Anki 牌组零配置。
  final bool templateTags;

  /// 卡面选中文字后可以「朗读」。默认开。
  final bool speakSelection;

  /// 没有音频的字段出朗读键（[fillFields] 里的那几个）。默认关：不给所有牌组凭空多出按键。
  final bool fillMissing;

  /// 「没有音频时出朗读键」的音频字段（规范名，见 [kSrsTtsFillableAudioFields]）。
  final Set<String> fillFields;

  /// 自动播放（牌组「自动播放音频」开着时）也念朗读键。默认开（与 Anki 一致）。
  final bool autoplay;

  /// 渲染卡面时交给引擎的选项。
  SrsCardTtsOptions get renderOptions => SrsCardTtsOptions(
    templateTags: templateTags,
    fillAudioFields: fillMissing ? fillFields : const <String>{},
  );

  SrsReviewTts copyWith({
    bool? templateTags,
    bool? speakSelection,
    bool? fillMissing,
    Set<String>? fillFields,
    bool? autoplay,
  }) => SrsReviewTts(
    templateTags: templateTags ?? this.templateTags,
    speakSelection: speakSelection ?? this.speakSelection,
    fillMissing: fillMissing ?? this.fillMissing,
    fillFields: fillFields ?? this.fillFields,
    autoplay: autoplay ?? this.autoplay,
  );

  /// 持久化（偏好 `srs_review_tts` 的值，键名冻结）。
  String encode() => jsonEncode(<String, Object?>{
    'v': 1,
    'tags': templateTags,
    'selection': speakSelection,
    'fill': fillMissing,
    'fields': fillFields.toList()..sort(),
    'autoplay': autoplay,
  });

  /// 读偏好；空串 / 坏值 / 不认识的字段名回落默认。
  static SrsReviewTts decode(String raw) {
    if (raw.isEmpty) return const SrsReviewTts();
    final Object? m;
    try {
      m = jsonDecode(raw);
    } on FormatException {
      return const SrsReviewTts();
    }
    if (m is! Map) return const SrsReviewTts();
    const SrsReviewTts d = SrsReviewTts();
    final Object? fields = m['fields'];
    return SrsReviewTts(
      templateTags: m['tags'] is bool ? m['tags'] as bool : d.templateTags,
      speakSelection: m['selection'] is bool
          ? m['selection'] as bool
          : d.speakSelection,
      fillMissing: m['fill'] is bool ? m['fill'] as bool : d.fillMissing,
      fillFields: fields is List
          ? <String>{
              for (final Object? f in fields)
                if (f is String && kSrsTtsFillableAudioFields.contains(f)) f,
            }
          : d.fillFields,
      autoplay: m['autoplay'] is bool ? m['autoplay'] as bool : d.autoplay,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SrsReviewTts &&
      other.templateTags == templateTags &&
      other.speakSelection == speakSelection &&
      other.fillMissing == fillMissing &&
      other.autoplay == autoplay &&
      other.fillFields.length == fillFields.length &&
      other.fillFields.containsAll(fillFields);

  @override
  int get hashCode => Object.hash(
    templateTags,
    speakSelection,
    fillMissing,
    autoplay,
    Object.hashAllUnordered(fillFields),
  );
}

/// 「没有音频时出朗读键」可选的字段，按设置页里的顺序（例句在前：词头念读音，读音为空的
/// 汉字词头本来就不出）。
const List<String> kSrsReviewTtsFillFieldOrder = <String>[
  kSrsSentenceAudioField,
  FushiCardFields.termAudio,
];
