/// 复习卡面的朗读（TTS）发音键：Anki `{{tts}}` 模板标签与「没有音频的字段出朗读键」
/// （拍板台 YmWT1x57XV，维护者选 A + B）。
///
/// ## 卡面上怎么表示
///
/// 渲染器把 `{{tts ja_JP:Sentence}}` 输出成 `[anki:tts lang=ja_JP]…[/anki:tts]`
/// （anki_template_render.dart 的 `ankiTtsFilter`，与 Anki 同形）。[srsRenderTtsTags] 在
/// 渲染后把它换成一个**伪声音标记** `[sound:fushi-tts:<载荷>]`（[SrsTtsSound.name]）：载荷里是
/// 要念的纯文字、语言、`voices=` 与 `speed=`。于是三套卡面（整面 WebView、原生 HTML、原生
/// Fushi 卡面）画发音键、页面上报可见发音、自动播放 / 重播 / R 键的清单全部沿用 `[sound:]`
/// 那一套，不另起一条播放链；只有「按名字找文件」那一步认出 `fushi-tts:` 前缀改去合成 /
/// 取缓存（app 侧 srs_card_tts_audio.dart）。
///
/// 「没有音频的字段出朗读键」（[SrsCardTtsOptions.fillAudioFields]）在**渲染前**把空的
/// `TermAudio`（旧名 `ExpressionAudio`）/ `SentenceAudio` 字段值换成同一种伪声音标记：模板里
/// 放这个字段的位置（Lapis 的音频容器、`{{#SentenceAudio}}` 区段、原生卡面的发音键）就自然
/// 出一颗朗读键，不改模板、不写回笔记。
///
/// ## 词头不按字形念
///
/// 词头含汉字时，TTS 念字形 = 机器推断读音（feature-blacklist「自动注音」同一条理由；「补全
/// 单词音频」也因此不用 TTS 兜底）。所以要念的文字等于词头、且含汉字时改念读音字段，读音为空
/// 就**不出**这颗键；词头是纯假名 / 拉丁字母时字形就是读音，照常念。例句与选中文字照常念。
///
/// 伪名字不是媒体库文件名（带 scheme 前缀，`srsIsBareMediaName` 不认），不进媒体同步、远程预取
/// 与媒体回收。纯 Dart，没有 Flutter 依赖。
library;

import 'dart:convert';

import 'package:fushi_anki/fushi_anki_core.dart'
    show FushiCardFields, ankiStripHtml;
import 'package:meta/meta.dart' show immutable;

/// 伪声音名的前缀（`[sound:fushi-tts:<载荷>]`）。
const String kSrsTtsSoundPrefix = 'fushi-tts:';

/// 例句音频字段名（Fushi 卡片与 Lapis 同名）。
const String kSrsSentenceAudioField = 'SentenceAudio';

/// 例句字段名（Fushi 卡片与 Lapis 同名）。
const String kSrsSentenceField = 'Sentence';

/// 一颗朗读键要念什么。
@immutable
class SrsTtsSound {
  const SrsTtsSound({
    required this.text,
    this.lang,
    this.voices = const <String>[],
    this.speed,
  });

  /// 要念的纯文字（已去标签 / 注音 / 实体）。
  final String text;

  /// Anki 的语言代码（`ja_JP`、`en_US`）；null = 不指定（app 按文字判语言）。
  final String? lang;

  /// Anki `voices=` 列的声音名（按优先级）；空 = 用复习朗读的默认声音。
  final List<String> voices;

  /// Anki `speed=`；null = 用 TTS 兜底倍速。
  final double? speed;

  /// 伪声音名（放进 `[sound:]`）：载荷是 base64url（不含 `]`、`&`、引号，HTML 属性与
  /// `[sound:]` 词法里都原样保留）。
  String get name {
    final Map<String, Object?> payload = <String, Object?>{
      't': text,
      if (lang != null) 'l': lang,
      if (voices.isNotEmpty) 'v': voices,
      if (speed != null) 's': speed,
    };
    final String encoded = base64Url
        .encode(utf8.encode(jsonEncode(payload)))
        .replaceAll('=', '');
    return '$kSrsTtsSoundPrefix$encoded';
  }

  /// [name] 的逆过程；不是伪声音名 / 载荷坏了返回 null。
  static SrsTtsSound? parse(String name) {
    if (!name.startsWith(kSrsTtsSoundPrefix)) return null;
    String body = name.substring(kSrsTtsSoundPrefix.length).trim();
    if (body.isEmpty) return null;
    body = body.padRight((body.length + 3) ~/ 4 * 4, '=');
    final Object? raw;
    try {
      raw = jsonDecode(utf8.decode(base64Url.decode(body)));
    } on FormatException {
      return null;
    }
    if (raw is! Map) return null;
    final Object? text = raw['t'];
    if (text is! String || text.trim().isEmpty) return null;
    final Object? lang = raw['l'];
    final Object? voices = raw['v'];
    final Object? speed = raw['s'];
    return SrsTtsSound(
      text: text,
      lang: lang is String && lang.isNotEmpty ? lang : null,
      voices: <String>[
        if (voices is List)
          for (final Object? v in voices)
            if (v is String && v.isNotEmpty) v,
      ],
      speed: speed is num && speed.isFinite && speed > 0
          ? speed.toDouble()
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SrsTtsSound &&
      other.text == text &&
      other.lang == lang &&
      other.speed == speed &&
      _sameList(other.voices, voices);

  @override
  int get hashCode => Object.hash(text, lang, speed, Object.hashAll(voices));

  @override
  String toString() =>
      'SrsTtsSound(${text.length} chars, lang=$lang, voices=$voices, '
      'speed=$speed)';
}

bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// [name]（`[sound:]` 里的名字）是不是朗读键。
bool srsIsTtsSoundName(String name) => name.startsWith(kSrsTtsSoundPrefix);

/// 渲染卡面时的朗读选项（复习页按「复习选项 › 朗读」给出；远程刷卡随请求带给主机）。
@immutable
class SrsCardTtsOptions {
  const SrsCardTtsOptions({
    this.templateTags = true,
    this.fillAudioFields = const <String>{},
  });

  /// 认模板里的 `{{tts}}`（[srsRenderTtsTags]）。false = 标签整段去掉（不显示原始标记）。
  final bool templateTags;

  /// 这些音频字段（规范名：[FushiCardFields.termAudio] / [kSrsSentenceAudioField]）没有音频时
  /// 填一颗朗读键（[srsFillTtsAudioFields]）。空 = 不填。
  final Set<String> fillAudioFields;

  Map<String, Object?> toJson() => <String, Object?>{
    'tags': templateTags,
    'fill': fillAudioFields.toList()..sort(),
  };

  /// 远程请求里的选项；缺省 / 坏值 = 默认（认 `{{tts}}`、不填字段）。
  static SrsCardTtsOptions fromJson(Object? raw) {
    if (raw is! Map) return const SrsCardTtsOptions();
    final Object? fill = raw['fill'];
    return SrsCardTtsOptions(
      templateTags: raw['tags'] != false,
      fillAudioFields: <String>{
        if (fill is List)
          for (final Object? f in fill)
            if (f is String && kSrsTtsFillableAudioFields.contains(f)) f,
      },
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SrsCardTtsOptions &&
      other.templateTags == templateTags &&
      other.fillAudioFields.length == fillAudioFields.length &&
      other.fillAudioFields.containsAll(fillAudioFields);

  @override
  int get hashCode =>
      Object.hash(templateTags, Object.hashAllUnordered(fillAudioFields));
}

/// 可以「没有音频时出朗读键」的音频字段（规范名）。
const Set<String> kSrsTtsFillableAudioFields = <String>{
  FushiCardFields.termAudio,
  kSrsSentenceAudioField,
};

final RegExp _rubyAnnotation = RegExp(
  r'<(rt|rp)\b[^>]*>.*?</\1\s*>',
  caseSensitive: false,
  dotAll: true,
);
final RegExp _soundTag = RegExp(r'\[sound:[^\]]*\]');
final RegExp _lineBreak = RegExp(r'<br\s*/?>', caseSensitive: false);
final RegExp _whitespace = RegExp(r'\s+');

/// 字段 / 模板片段 HTML 里要念出来的文字：去掉注音（`<rt>` / `<rp>` 内容，否则读音会被再念
/// 一遍）、`[sound:]` 与全部标签，解实体，空白收成单个空格。
String srsTtsSpeechText(String html) => ankiStripHtml(
  html
      .replaceAll(_rubyAnnotation, '')
      .replaceAll(_soundTag, '')
      .replaceAll(_lineBreak, ' '),
).replaceAll(_whitespace, ' ').trim();

final RegExp _han = RegExp(r'[々〆〇㐀-䶿一-鿿豈-﫿\u{20000}-\u{3134F}]', unicode: true);

/// [text] 含汉字（含「々」「〆」「〇」）：这时按字形念 = 机器推断读音。
bool srsTtsHasHan(String text) => _han.hasMatch(text);

/// 词头的朗读文字：读音非空念读音；读音为空时词头不含汉字（字形就是读音）念词头，否则
/// null（不出词头朗读，见库注释「词头不按字形念」）。
String? srsTtsHeadwordText({required String term, required String reading}) {
  final String r = srsTtsSpeechText(reading);
  if (r.isNotEmpty) return r;
  final String w = srsTtsSpeechText(term);
  if (w.isEmpty || srsTtsHasHan(w)) return null;
  return w;
}

final RegExp _mediaElement = RegExp(r'<(audio|video)\b', caseSensitive: false);

/// 字段值里已经有能出声的媒体（`[sound:]`、`<audio>` / `<video>`）。
bool srsFieldHasAudio(String value) =>
    value.contains('[sound:') || _mediaElement.hasMatch(value);

/// 渲染前：[fill] 里的音频字段没有音频时换成一颗朗读键（伪声音标记）。
///
/// - `TermAudio`（旧名 `ExpressionAudio`）念 [srsTtsHeadwordText]（读音为空且词头含汉字时
///   不填）；
/// - `SentenceAudio` 念 `Sentence`（空则不填）。
///
/// 返回新表；没有要填的原样返回 [fields]。
Map<String, String> srsFillTtsAudioFields(
  Map<String, String> fields,
  Set<String> fill,
) {
  if (fill.isEmpty) return fields;
  Map<String, String>? out;
  for (final MapEntry<String, String> e in fields.entries) {
    final String canonical = FushiCardFields.canonical(e.key);
    if (!fill.contains(canonical) || srsFieldHasAudio(e.value)) continue;
    final String? text = switch (canonical) {
      FushiCardFields.termAudio => srsTtsHeadwordText(
        term: FushiCardFields.value(fields, FushiCardFields.term) ?? '',
        reading:
            FushiCardFields.value(fields, FushiCardFields.termReading) ?? '',
      ),
      kSrsSentenceAudioField => _nonEmpty(
        srsTtsSpeechText(fields[kSrsSentenceField] ?? ''),
      ),
      _ => null,
    };
    if (text == null) continue;
    (out ??= Map<String, String>.of(fields))[e.key] =
        '[sound:${SrsTtsSound(text: text).name}]';
  }
  return out ?? fields;
}

String? _nonEmpty(String s) => s.isEmpty ? null : s;

final RegExp _ttsTag = RegExp(
  r'\[anki:tts\b([^\]]*)\]([\s\S]*?)\[/anki:tts\]',
  caseSensitive: false,
);

/// 渲染后：`[anki:tts lang=… voices=… speed=…]文字[/anki:tts]` → 朗读键（伪声音标记）。
///
/// [enabled] 为 false 时标签整段去掉（不在卡面上露出原始标记）。要念的文字为空时同样去掉。
/// 文字等于词头且含汉字时改念读音字段，读音为空就去掉（库注释「词头不按字形念」）；
/// [fields] 是这张卡的字段（按名字，新旧名都认）。
String srsRenderTtsTags(
  String html, {
  required Map<String, String> fields,
  bool enabled = true,
}) {
  if (!html.contains('[anki:tts')) return html;
  final String term = srsTtsSpeechText(
    FushiCardFields.value(fields, FushiCardFields.term) ?? '',
  );
  final String reading =
      FushiCardFields.value(fields, FushiCardFields.termReading) ?? '';
  return html.replaceAllMapped(_ttsTag, (Match m) {
    if (!enabled) return '';
    String text = srsTtsSpeechText(m.group(2)!);
    if (text.isEmpty) return '';
    if (term.isNotEmpty && text == term && srsTtsHasHan(text)) {
      final String? headword = srsTtsHeadwordText(term: term, reading: reading);
      if (headword == null) return '';
      text = headword;
    }
    final Map<String, String> attrs = _ttsAttrs(m.group(1)!);
    final double? speed = double.tryParse(attrs['speed'] ?? '');
    return '[sound:${SrsTtsSound(text: text, lang: _nonEmpty(attrs['lang'] ?? ''), voices: <String>[for (final String v in (attrs['voices'] ?? '').split(','))
      if (v.trim().isNotEmpty) v.trim()], speed: speed != null && speed.isFinite && speed > 0 ? speed : null).name}]';
  });
}

/// `lang=ja_JP voices=A,B speed=1.2` → 键值表（键小写；没有 `=` 的词忽略）。
Map<String, String> _ttsAttrs(String raw) => <String, String>{
  for (final String part in raw.trim().split(_whitespace))
    if (part.contains('='))
      part.substring(0, part.indexOf('=')).toLowerCase(): part.substring(
        part.indexOf('=') + 1,
      ),
};
