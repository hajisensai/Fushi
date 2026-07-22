import 'dart:convert';
import 'dart:typed_data';

/// 互联「制卡到服务端」转发载体（`POST /api/mine/forward`）。
///
/// 客户端把一次**未渲染**的制卡请求（`repo.mineEntry(rawPayloadJson, context)` 的三要素）
/// 连同**所有本地媒体字节**序列化后发给已配对主机；主机用**它自己的** Anki 后端 +
/// 字段映射/牌组渲染并落卡（服务端拥有制卡配置）。这与浏览器扩展用的 `/api/mine`
/// （[ImmersionMinePayload]，携带已渲染 fields + 视频截图/clip）是**两条独立路径**，
/// 互不影响契约。
///
/// 媒体的四个来源（见 `docs` / 映射结论）：
/// * [coverBase64]      ← `context.coverPath`（EPUB 封面 / 视频 GIF·帧·截图临时文件）
/// * [sentenceAudioBase64] ← `context.sasayakiAudioPath`（有声书裁句 / 视频音频临时文件）
/// * [wordAudioBase64]  ← `fields['audio']` 为**本地文件**时的单词发音（`http(s)` URL 时
///   不搬字节，原样留在 [rawPayloadJson] 由服务端下载）
/// * [dictionaryMedia]  ← 每条 `DictionaryMedia{dictionary,path}` 经 `HoshiDicts.getMediaFile`
///   取到的外字/词典内嵌图字节（服务端未必装同款词典，必须由客户端搬字节）
///
/// 所有字节字段可空：缺失即降级（服务端少一样媒体，卡仍建），绝不因单个媒体坏掉整卡。
class ForwardedMinePayload {
  const ForwardedMinePayload({
    required this.rawPayloadJson,
    required this.sentence,
    this.cueSentence,
    this.documentTitle,
    this.sentenceOffset,
    this.source,
    this.bookTitleTag,
    this.coverBytes,
    this.coverExt,
    this.sentenceAudioBytes,
    this.sentenceAudioExt,
    this.wordAudioBytes,
    this.wordAudioExt,
    this.dictionaryMedia = const <ForwardedDictMedia>[],
  });

  /// 逐字转发的 JS 制卡 fields JSON（与本地 `repo.mineEntry` 的 `rawPayloadJson` 完全一致）。
  final String rawPayloadJson;
  final String sentence;
  final String? cueSentence;
  final String? documentTitle;
  final int? sentenceOffset;

  /// `AnkiMiningSource.name`（`'book'` / `'video'`）；null = 不追加分类标签。
  final String? source;
  final String? bookTitleTag;

  final Uint8List? coverBytes;

  /// 封面原文件扩展名（不含点，如 `jpg`/`gif`/`png`），供服务端命名临时文件、保留容器类型。
  final String? coverExt;
  final Uint8List? sentenceAudioBytes;
  final String? sentenceAudioExt;
  final Uint8List? wordAudioBytes;
  final String? wordAudioExt;
  final List<ForwardedDictMedia> dictionaryMedia;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'rawPayloadJson': rawPayloadJson,
        'sentence': sentence,
        if (cueSentence != null) 'cueSentence': cueSentence,
        if (documentTitle != null) 'documentTitle': documentTitle,
        if (sentenceOffset != null) 'sentenceOffset': sentenceOffset,
        if (source != null) 'source': source,
        if (bookTitleTag != null) 'bookTitleTag': bookTitleTag,
        if (coverBytes != null) 'coverBase64': base64Encode(coverBytes!),
        if (coverExt != null) 'coverExt': coverExt,
        if (sentenceAudioBytes != null)
          'sentenceAudioBase64': base64Encode(sentenceAudioBytes!),
        if (sentenceAudioExt != null) 'sentenceAudioExt': sentenceAudioExt,
        if (wordAudioBytes != null)
          'wordAudioBase64': base64Encode(wordAudioBytes!),
        if (wordAudioExt != null) 'wordAudioExt': wordAudioExt,
        if (dictionaryMedia.isNotEmpty)
          'dictionaryMedia': dictionaryMedia
              .map((ForwardedDictMedia m) => m.toJson())
              .toList(),
      };

  /// `fields` 缺失/非法（[rawPayloadJson] 不是字符串）→ 抛 [FormatException]（真正的坏请求，
  /// 由调用方转 400）。媒体字节 base64 坏了只当该媒体缺失（降级），不抛。
  static ForwardedMinePayload fromJson(Map<String, dynamic> json) {
    final Object? raw = json['rawPayloadJson'];
    if (raw is! String || raw.isEmpty) {
      throw const FormatException('rawPayloadJson must be a non-empty string');
    }
    final Object? dmRaw = json['dictionaryMedia'];
    final List<ForwardedDictMedia> media = dmRaw is List
        ? dmRaw
            .whereType<Map>()
            .map((Map e) =>
                ForwardedDictMedia.fromJson(Map<String, dynamic>.from(e)))
            .where((ForwardedDictMedia m) => m.bytes != null)
            .toList(growable: false)
        : const <ForwardedDictMedia>[];
    return ForwardedMinePayload(
      rawPayloadJson: raw,
      sentence: json['sentence'] as String? ?? '',
      cueSentence: json['cueSentence'] as String?,
      documentTitle: json['documentTitle'] as String?,
      sentenceOffset: (json['sentenceOffset'] as num?)?.toInt(),
      source: json['source'] as String?,
      bookTitleTag: json['bookTitleTag'] as String?,
      coverBytes: tryDecodeBase64(json['coverBase64']),
      coverExt: sanitizeExt(json['coverExt']),
      sentenceAudioBytes: tryDecodeBase64(json['sentenceAudioBase64']),
      sentenceAudioExt: sanitizeExt(json['sentenceAudioExt']),
      wordAudioBytes: tryDecodeBase64(json['wordAudioBase64']),
      wordAudioExt: sanitizeExt(json['wordAudioExt']),
      dictionaryMedia: media,
    );
  }

  /// 容错 base64 解码：非字符串/空/格式错都返回 null（媒体缺失即降级，不抛）。
  static Uint8List? tryDecodeBase64(Object? value) {
    if (value is! String || value.isEmpty) return null;
    try {
      return base64Decode(value);
    } on FormatException {
      return null;
    }
  }

  /// 规范化扩展名：只保留字母数字，截断到 8 字符，空则返回 null。防止客户端塞入路径分隔符
  /// 或过长串影响服务端临时文件命名。
  static String? sanitizeExt(Object? value) {
    if (value is! String) return null;
    final String cleaned =
        value.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toLowerCase();
    if (cleaned.isEmpty) return null;
    return cleaned.length > 8 ? cleaned.substring(0, 8) : cleaned;
  }
}

/// 转发的单条词典媒体：词典名 `dictionary` + 原 `path`（服务端据此按
/// `ankiDictionaryMediaCacheFilename(dictionary, path)` 落缓存，与 repo 读取命名对齐——
/// BUG-904 起缓存文件名同时取词典名+路径以避免跨词典同 path 串味，故必须一并转发）+ 字节。
class ForwardedDictMedia {
  const ForwardedDictMedia({
    this.dictionary = '',
    required this.path,
    required this.bytes,
  });

  final String dictionary;
  final String path;
  final Uint8List? bytes;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (dictionary.isNotEmpty) 'dictionary': dictionary,
        'path': path,
        if (bytes != null) 'base64': base64Encode(bytes!),
      };

  static ForwardedDictMedia fromJson(Map<String, dynamic> json) =>
      ForwardedDictMedia(
        dictionary: json['dictionary'] as String? ?? '',
        path: json['path'] as String? ?? '',
        bytes: ForwardedMinePayload.tryDecodeBase64(json['base64']),
      );
}
