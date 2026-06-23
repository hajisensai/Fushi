import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

class AnkiDeck {
  const AnkiDeck({required this.id, required this.name});

  factory AnkiDeck.fromJson(Map<String, dynamic> json) =>
      AnkiDeck(id: json['id'] as int, name: json['name'] as String);
  final int id;
  final String name;

  Map<String, dynamic> toJson() => {'id': id, 'name': name};
}

class AnkiNoteType {
  const AnkiNoteType({
    required this.id,
    required this.name,
    required this.fields,
  });

  factory AnkiNoteType.fromJson(Map<String, dynamic> json) => AnkiNoteType(
        id: json['id'] as int,
        name: json['name'] as String,
        fields: List<String>.from(json['fields'] as List),
      );
  final int id;
  final String name;
  final List<String> fields;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'fields': fields};
}

/// TODO-614：「给已制卡片开启覆写」的范围。
///
/// 用户痛点：弹窗里点绿色 ✓↩ 只能覆写**本会话刚制的最近一张**卡（`lastMinedNoteId`
/// 内存态，换词/重查即丢）；想覆写「更早制的卡」时按钮只是普通 ✓，点了会按查重
/// 拦下或新建。本枚举把覆写范围做成单选（**不是**多选）：
///
/// - [latest]（默认）：维持旧行为——只有本会话最近一张可改（Never break userspace）。
/// - [all]：查词渲染时用**与查重同一条件**（第一字段=expression）反查 Anki 已存在的
///   note id（多张取最近一张），灌进弹窗的「最新可改」态，使更早的卡也亮起 ✓↩、点它
///   按 id 覆写。AnkiDroid 后端拿不到真实 note id（只回 bool）→ 仍优雅降级为不可覆写
///   更早卡，与现状一致。
enum AnkiOverwriteScope {
  /// 仅覆写本会话最近制的一张卡（旧行为）。
  latest,

  /// 覆写任意同条件已存在的卡（多张命中取最近一张）。
  all,
}

/// 把持久化字符串解析回 [AnkiOverwriteScope]；未知/缺失值容错回 [AnkiOverwriteScope.latest]
/// （旧用户存档没有此字段 → 等价现状，Never break userspace）。
AnkiOverwriteScope ankiOverwriteScopeFromName(String? name) {
  switch (name) {
    case 'all':
      return AnkiOverwriteScope.all;
    case 'latest':
    default:
      return AnkiOverwriteScope.latest;
  }
}

class AnkiSettings {
  const AnkiSettings({
    this.selectedDeckId,
    this.selectedDeckName,
    this.selectedNoteTypeId,
    this.selectedNoteTypeName,
    this.availableDecks = const [],
    this.availableNoteTypes = const [],
    this.fieldMappings = const {},
    this.tags = '',
    this.tagIncludeHibiki = true,
    this.tagIncludeCategory = true,
    this.allowDupes = false,
    this.compactGlossaries = false,
    this.embedMedia = true,
    this.overwriteScope = AnkiOverwriteScope.latest,
    this.ankiConnectHost = 'localhost',
    this.ankiConnectPort = 8765,
    this.ankiConnectApiKey = '',
  });

  factory AnkiSettings.fromJson(Map<String, dynamic> json) => AnkiSettings(
        selectedDeckId: json['selectedDeckId'] as int?,
        selectedDeckName: json['selectedDeckName'] as String?,
        selectedNoteTypeId: json['selectedNoteTypeId'] as int?,
        selectedNoteTypeName: json['selectedNoteTypeName'] as String?,
        availableDecks: (json['availableDecks'] as List?)
                ?.map((e) => AnkiDeck.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
        availableNoteTypes: (json['availableNoteTypes'] as List?)
                ?.map((e) => AnkiNoteType.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
        fieldMappings:
            Map<String, String>.from(json['fieldMappings'] as Map? ?? {}),
        tags: json['tags'] as String? ?? '',
        tagIncludeHibiki: json['tagIncludeHibiki'] as bool? ?? true,
        tagIncludeCategory: json['tagIncludeCategory'] as bool? ?? true,
        allowDupes: json['allowDupes'] as bool? ?? false,
        compactGlossaries: json['compactGlossaries'] as bool? ?? false,
        embedMedia: json['embedMedia'] as bool? ?? true,
        overwriteScope:
            ankiOverwriteScopeFromName(json['overwriteScope'] as String?),
        ankiConnectHost: json['ankiConnectHost'] as String? ?? 'localhost',
        ankiConnectPort: json['ankiConnectPort'] as int? ?? 8765,
        ankiConnectApiKey: json['ankiConnectApiKey'] as String? ?? '',
      );
  final int? selectedDeckId;
  final String? selectedDeckName;
  final int? selectedNoteTypeId;
  final String? selectedNoteTypeName;
  final List<AnkiDeck> availableDecks;
  final List<AnkiNoteType> availableNoteTypes;
  final Map<String, String> fieldMappings;
  final String tags;

  /// 是否给每张 Hibiki 制出的卡片追加固定的 `hibiki` 默认标签（TODO-117 开关）。
  /// 默认 `true`（保持 TODO-115/062 现状）。
  final bool tagIncludeHibiki;

  /// 是否按制卡来源追加分类默认标签（书籍→`book` / 视频→`video`，TODO-117/TODO-185）。
  /// 默认 `true`（保持 TODO-115 现状）。来源为 `null` 时本就不追加分类标签。
  final bool tagIncludeCategory;
  final bool allowDupes;
  final bool compactGlossaries;
  final bool embedMedia;

  /// TODO-614：覆写已制卡片的范围（默认 [AnkiOverwriteScope.latest] = 仅最近一张）。
  final AnkiOverwriteScope overwriteScope;
  final String ankiConnectHost;
  final int ankiConnectPort;
  final String ankiConnectApiKey;

  bool get isConfigured => selectedDeckId != null && selectedNoteTypeId != null;

  AnkiNoteType? get selectedNoteType =>
      availableNoteTypes.firstWhereOrNull((t) => t.id == selectedNoteTypeId) ??
      (selectedNoteTypeName != null
          ? availableNoteTypes
              .firstWhereOrNull((t) => t.name == selectedNoteTypeName)
          : null);

  AnkiSettings copyWith({
    int? selectedDeckId,
    String? selectedDeckName,
    int? selectedNoteTypeId,
    String? selectedNoteTypeName,
    List<AnkiDeck>? availableDecks,
    List<AnkiNoteType>? availableNoteTypes,
    Map<String, String>? fieldMappings,
    String? tags,
    bool? tagIncludeHibiki,
    bool? tagIncludeCategory,
    bool? allowDupes,
    bool? compactGlossaries,
    bool? embedMedia,
    AnkiOverwriteScope? overwriteScope,
    String? ankiConnectHost,
    int? ankiConnectPort,
    String? ankiConnectApiKey,
  }) =>
      AnkiSettings(
        selectedDeckId: selectedDeckId ?? this.selectedDeckId,
        selectedDeckName: selectedDeckName ?? this.selectedDeckName,
        selectedNoteTypeId: selectedNoteTypeId ?? this.selectedNoteTypeId,
        selectedNoteTypeName: selectedNoteTypeName ?? this.selectedNoteTypeName,
        availableDecks: availableDecks ?? this.availableDecks,
        availableNoteTypes: availableNoteTypes ?? this.availableNoteTypes,
        fieldMappings: fieldMappings ?? this.fieldMappings,
        tags: tags ?? this.tags,
        tagIncludeHibiki: tagIncludeHibiki ?? this.tagIncludeHibiki,
        tagIncludeCategory: tagIncludeCategory ?? this.tagIncludeCategory,
        allowDupes: allowDupes ?? this.allowDupes,
        compactGlossaries: compactGlossaries ?? this.compactGlossaries,
        embedMedia: embedMedia ?? this.embedMedia,
        overwriteScope: overwriteScope ?? this.overwriteScope,
        ankiConnectHost: ankiConnectHost ?? this.ankiConnectHost,
        ankiConnectPort: ankiConnectPort ?? this.ankiConnectPort,
        ankiConnectApiKey: ankiConnectApiKey ?? this.ankiConnectApiKey,
      );

  Map<String, dynamic> toJson() => {
        'selectedDeckId': selectedDeckId,
        'selectedDeckName': selectedDeckName,
        'selectedNoteTypeId': selectedNoteTypeId,
        'selectedNoteTypeName': selectedNoteTypeName,
        'availableDecks': availableDecks.map((d) => d.toJson()).toList(),
        'availableNoteTypes':
            availableNoteTypes.map((t) => t.toJson()).toList(),
        'fieldMappings': fieldMappings,
        'tags': tags,
        'tagIncludeHibiki': tagIncludeHibiki,
        'tagIncludeCategory': tagIncludeCategory,
        'allowDupes': allowDupes,
        'compactGlossaries': compactGlossaries,
        'embedMedia': embedMedia,
        'overwriteScope': overwriteScope.name,
        'ankiConnectHost': ankiConnectHost,
        'ankiConnectPort': ankiConnectPort,
        'ankiConnectApiKey': ankiConnectApiKey,
      };
}

class AnkiMiningPayload {
  const AnkiMiningPayload({
    required this.expression,
    this.reading = '',
    this.matched = '',
    this.furiganaPlain = '',
    this.frequenciesHtml = '',
    this.freqHarmonicRank = '',
    this.glossary = '',
    this.glossaryFirst = '',
    this.singleGlossaries = const {},
    this.pitchPositions = '',
    this.pitchCategories = '',
    this.popupSelectionText = '',
    this.audio = '',
    this.selectedDictionary = '',
    this.dictionaryMedia = const [],
  });

  factory AnkiMiningPayload.fromJson(Map<String, dynamic> json) {
    var singleGlossaries = <String, String>{};
    final sgRaw = json['singleGlossaries'];
    if (sgRaw is String && sgRaw.isNotEmpty) {
      try {
        singleGlossaries = Map<String, String>.from(jsonDecode(sgRaw) as Map);
      } catch (e, stack) {
        debugPrint('AnkiMiningPayload.singleGlossaries: $e\n$stack');
      }
    } else if (sgRaw is Map) {
      singleGlossaries = Map<String, String>.from(sgRaw);
    }

    var dictionaryMedia = <DictionaryMedia>[];
    final dmRaw = json['dictionaryMedia'];
    if (dmRaw is String && dmRaw.isNotEmpty) {
      try {
        dictionaryMedia = (jsonDecode(dmRaw) as List)
            .map((e) => DictionaryMedia.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (e, stack) {
        debugPrint('AnkiMiningPayload.dictionaryMedia: $e\n$stack');
      }
    } else if (dmRaw is List) {
      dictionaryMedia = dmRaw
          .map((e) => DictionaryMedia.fromJson(e as Map<String, dynamic>))
          .toList();
    }

    return AnkiMiningPayload(
      expression: json['expression'] as String? ?? '',
      reading: json['reading'] as String? ?? '',
      matched: json['matched'] as String? ?? '',
      furiganaPlain: json['furiganaPlain'] as String? ?? '',
      frequenciesHtml: json['frequenciesHtml'] as String? ?? '',
      freqHarmonicRank: json['freqHarmonicRank'] as String? ?? '',
      glossary: json['glossary'] as String? ?? '',
      glossaryFirst: json['glossaryFirst'] as String? ?? '',
      singleGlossaries: singleGlossaries,
      pitchPositions: json['pitchPositions'] as String? ?? '',
      pitchCategories: json['pitchCategories'] as String? ?? '',
      popupSelectionText: json['popupSelectionText'] as String? ?? '',
      audio: json['audio'] as String? ?? '',
      selectedDictionary: json['selectedDictionary'] as String? ?? '',
      dictionaryMedia: dictionaryMedia,
    );
  }
  final String expression;
  final String reading;
  final String matched;
  final String furiganaPlain;
  final String frequenciesHtml;
  final String freqHarmonicRank;
  final String glossary;
  final String glossaryFirst;
  final Map<String, String> singleGlossaries;
  final String pitchPositions;
  final String pitchCategories;
  final String popupSelectionText;
  final String audio;
  final String selectedDictionary;
  final List<DictionaryMedia> dictionaryMedia;
}

class DictionaryMedia {
  const DictionaryMedia({
    required this.dictionary,
    required this.path,
    required this.filename,
  });

  factory DictionaryMedia.fromJson(Map<String, dynamic> json) =>
      DictionaryMedia(
        dictionary: json['dictionary'] as String? ?? '',
        path: json['path'] as String? ?? '',
        filename: json['filename'] as String? ?? '',
      );
  final String dictionary;
  final String path;
  final String filename;
}

/// 制卡来源类别：用于给卡片追加分类标签（书籍 vs 视频）。
///
/// 与 `kStatSourceBook`/`kStatSourceVideo`（主 app 的统计/收藏来源标识）一一对应，
/// 但 hibiki_anki 是独立包不能依赖主 app，故在此重新声明一个无关枚举；调用方
/// （reader/video/mixin）在构造 [AnkiMiningContext] 时按各自的 `dictionarySourceType`
/// 映射进来。`null`（未指定）时不追加任何分类标签，只保留固定的 `hibiki` 标签。
enum AnkiMiningSource {
  /// 书籍/EPUB 阅读、独立查词页、有声书 —— 归「书籍」分类标签。
  book,

  /// 视频字幕查词 —— 归「视频」分类标签（写入 Anki 的标签字面量为 `video`）。
  video,
}

class AnkiMiningContext {
  const AnkiMiningContext({
    required this.sentence,
    this.cueSentence,
    this.documentTitle,
    this.coverPath,
    this.sasayakiAudioPath,
    this.sentenceOffset,
    this.source,
    this.bookTitleTag,
  });
  final String sentence;
  final String? cueSentence;
  final String? documentTitle;
  final String? coverPath;
  final String? sasayakiAudioPath;
  final int? sentenceOffset;

  /// 制卡来源类别；决定追加哪个分类标签（见 [AnkiMiningSource]）。`null` 时不追加分类标签。
  final AnkiMiningSource? source;

  /// TODO-681 / BUG-393：「自动添加书名到标签」开关开启时，调用方（reader / video）
  /// 算好的**已清洗书名/番名标签**（空格/Tab→下划线，单个 Anki tag 字面量）；开关关闭
  /// 或无标题时为 `null`，[BaseAnkiRepository.buildNoteTags] 不追加。
  ///
  /// 为什么放 context 而非 [AnkiSettings]：开关真值源是主 app 的
  /// `PreferencesRepository.autoAddBookNameToTags`，而 hibiki_anki 是独立包不能依赖主
  /// app；标题来源也按来源不同（书=书名 / 视频=番名）。故由调用方读开关 + 取标题 + 清洗后
  /// 注入，本包只负责按既有 [buildNoteTags] 去重规则追加，与 `book`/`video` 分类标签同构。
  final String? bookTitleTag;
}

class AnkiHandlebarRenderer {
  static final _handlebarRegex = RegExp(r'\{[^}]*\}');
  static const _singleGlossaryPrefix = '{single-glossary-';

  static String render(
    String template,
    AnkiMiningPayload payload,
    AnkiMiningContext context,
  ) =>
      template.replaceAllMapped(
        _handlebarRegex,
        (match) => _handlebarToValue(match.group(0)!, payload, context),
      );

  static String _handlebarToValue(
    String handlebar,
    AnkiMiningPayload payload,
    AnkiMiningContext context,
  ) {
    if (handlebar.startsWith(_singleGlossaryPrefix)) {
      final dictionary = handlebar.substring(
          _singleGlossaryPrefix.length, handlebar.length - 1);
      return _singleGlossaryForDictionary(payload, dictionary);
    }
    switch (handlebar) {
      case '{expression}':
        return payload.expression;
      case '{reading}':
        return payload.reading;
      case '{furigana-plain}':
        return payload.furiganaPlain;
      case '{audio}':
        return payload.audio;
      case '{glossary}':
        return payload.glossary;
      case '{glossary-first}':
        return payload.glossaryFirst;
      case '{selected-glossary}':
        return _singleGlossaryForDictionary(
            payload, payload.selectedDictionary);
      case '{popup-selection-text}':
        return payload.popupSelectionText;
      case '{sentence}':
        return _sentenceValue(payload, context);
      case '{cue-sentence}':
        return _cueSentenceValue(payload, context);
      case '{frequencies}':
        return payload.frequenciesHtml;
      case '{frequency-harmonic-rank}':
        return payload.freqHarmonicRank;
      case '{pitch-accent-positions}':
        return payload.pitchPositions;
      case '{pitch-accent-categories}':
        return payload.pitchCategories;
      case '{document-title}':
        return context.documentTitle ?? '';
      case '{book-cover}':
        return context.coverPath ?? '';
      case '{sasayaki-audio}':
        return context.sasayakiAudioPath ?? '';
      default:
        return '';
    }
  }

  static String _singleGlossaryForDictionary(
    AnkiMiningPayload payload,
    String dictionary,
  ) {
    if (dictionary.isEmpty) return '';
    final direct = payload.singleGlossaries[dictionary];
    if (direct != null) return direct;
    final normalized = _normalizeDictionaryName(dictionary);
    for (final entry in payload.singleGlossaries.entries) {
      if (_normalizeDictionaryName(entry.key) == normalized) return entry.value;
    }
    return '';
  }

  static String _normalizeDictionaryName(String name) =>
      name.trim().replaceAll(RegExp(r'\s*\[[^\]]+\]\s*$'), '');

  static String _sentenceValue(
    AnkiMiningPayload payload,
    AnkiMiningContext context,
  ) {
    final matched = payload.matched;
    if (matched.isEmpty) return context.sentence;
    final offset = context.sentenceOffset;
    if (offset != null &&
        offset >= 0 &&
        offset + matched.length <= context.sentence.length &&
        context.sentence.substring(offset, offset + matched.length) ==
            matched) {
      return '${context.sentence.substring(0, offset)}'
          '<b>$matched</b>'
          '${context.sentence.substring(offset + matched.length)}';
    }
    return context.sentence.replaceFirst(matched, '<b>$matched</b>');
  }

  static String _cueSentenceValue(
    AnkiMiningPayload payload,
    AnkiMiningContext context,
  ) {
    final String text = context.cueSentence ?? context.sentence;
    final String matched = payload.matched;
    if (matched.isEmpty) return text;
    return text.replaceFirst(matched, '<b>$matched</b>');
  }
}

class AnkiHandlebarOptions {
  static const coreOptions = [
    '-',
    '{expression}',
    '{reading}',
    '{furigana-plain}',
    '{audio}',
    '{glossary}',
    '{glossary-first}',
    '{selected-glossary}',
    '{popup-selection-text}',
    '{sentence}',
    '{cue-sentence}',
    '{frequencies}',
    '{frequency-harmonic-rank}',
    '{pitch-accent-positions}',
    '{pitch-accent-categories}',
    '{document-title}',
    '{book-cover}',
    '{sasayaki-audio}',
  ];

  static List<String> forTermDictionaries(List<String> dictionaryNames) => [
        ...coreOptions,
        ...dictionaryNames.toSet().map((name) => '{single-glossary-$name}'),
      ];
}

String mimeTypeForPath(String path) {
  final ext = path.split('.').last.toLowerCase();
  switch (ext) {
    case 'mp3':
      return 'audio/mpeg';
    case 'aac':
      return 'audio/aac';
    case 'm4a':
      return 'audio/mp4';
    case 'wav':
      return 'audio/wav';
    case 'ogg':
      return 'audio/ogg';
    case 'png':
      return 'image/png';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'gif':
      return 'image/gif';
    case 'webp':
      return 'image/webp';
    case 'svg':
      return 'image/svg+xml';
    default:
      return 'application/octet-stream';
  }
}

/// 制卡时词典媒体（gaiji 外字、词典内嵌图等）落盘缓存目录。
///
/// 流程：主 app 在收到 JS `mineEntry` 负载后，把每个 [DictionaryMedia] 的字节
/// （`HoshiDicts.getMediaFile`）写到这个目录；两个 Anki repo（AnkiConnect /
/// AnkiDroid）再从这里 **按同一命名** 读出并 storeMediaFile。writer 与 reader
/// 必须共用 [ankiDictionaryMediaCacheDirPath] + [ankiDictionaryMediaCacheFilename]，
/// 否则文件名对不上 → repo 读不到 → 卡片留下未替换的 `hoshi_dict_N.ext` 坏图。
String ankiDictionaryMediaCacheDirPath() =>
    '${Directory.systemTemp.path}/anki-media';

/// 词典媒体在缓存目录中的文件名：`hibiki_dict_<path.hashCode>.<ext>`。
///
/// 无扩展名（path 不含 `.` 或以 `.` 结尾）时回退 `bin`（HBK-AUDIT-062：旧
/// `split('.').last` 在无点时返回整串当扩展名）。
String ankiDictionaryMediaCacheFilename(String path) {
  final lastDot = path.lastIndexOf('.');
  final ext = (lastDot >= 0 && lastDot < path.length - 1)
      ? path.substring(lastDot + 1)
      : 'bin';
  return 'hibiki_dict_${path.hashCode}.$ext';
}

/// Kind of audio reference resolved by [WordAudioResolver] and handed to the
/// repo media-store paths.
enum AnkiAudioRefKind { empty, remoteUrl, localFile }

/// Classifies a word-audio reference for Anki media storage, decided purely
/// from its string form so the repo audio paths are unit-testable.
///
/// `http(s)://…` is a remote URL to download; **everything else** is a local
/// file: a `file://` URI **or** a bare absolute path, Unix (`/…`) **or**
/// Windows (`C:\…`). The repo media-store helpers used to branch on
/// `file://` / `/` / `http` only and silently dropped Windows drive-letter
/// paths, so local word pronunciation never reached the card on Windows
/// (sibling of BUG-046). Treating any non-URL ref as a file removes that
/// special case instead of bolting on another `startsWith` branch.
class AnkiAudioRef {
  const AnkiAudioRef._();

  static AnkiAudioRefKind classify(String ref) {
    if (ref.isEmpty) return AnkiAudioRefKind.empty;
    if (ref.startsWith('http')) return AnkiAudioRefKind.remoteUrl;
    return AnkiAudioRefKind.localFile;
  }

  /// Resolves a [AnkiAudioRefKind.localFile] ref to a filesystem path,
  /// decoding `file://` URIs and returning bare paths unchanged.
  static String localPath(String ref) =>
      ref.startsWith('file://') ? Uri.parse(ref).toFilePath() : ref;
}

String ankiInlineMediaReference(String addMediaResult) {
  final imageSrc = RegExp(r'''<img\s+[^>]*src=["']([^"']+)["'][^>]*>''')
      .firstMatch(addMediaResult);
  if (imageSrc != null) {
    final src = imageSrc.group(1);
    if (src != null && src.isNotEmpty) return src;
  }
  final soundFile = RegExp(r'\[sound:([^\]]+)\]').firstMatch(addMediaResult);
  if (soundFile != null) {
    final file = soundFile.group(1);
    if (file != null) return file;
  }
  return addMediaResult;
}

String normalizeAnkiDictionaryHtml(String value) {
  if (!value.contains('data-sc-img') || !value.contains('gloss-image')) {
    return value;
  }
  return value + _ankiGaijiImageStyle;
}

// 外字（gaiji）中和样式：把内联外字框（义项序号 ❶❷、［参照］［参考］等）强制收回
// 到 ~1em 内联尺寸，否则会被正文压重叠。
//
// **特异性铁律**：词典自带 CSS 常用更具体的选择器把同一个 `.gloss-image-container`
// 撑大——明鏡国語辞典 第三版就有一条
// `.yomitan-glossary [data-dictionary="…"] span[data-sc-img][data-sc-class="gaiji"]
//  .gloss-image-container{width:15em!important}`（特异性 0,5,1）。本中和样式虽追加在
// 末尾，但只有当选择器特异性 **不低于** 词典规则时，等特异性才靠靠后的源码顺序取胜；
// 旧版前缀只有 `.yomitan-glossary [data-sc-img][data-sc-class="gaiji"] …`（0,4,0）反被
// 词典压住→外字框 15em 撑爆重叠正文。故现在每条规则做到 (0,6,1)（前缀
// `.yomitan-glossary [data-dictionary]` + 完整 `span[data-sc-img][data-sc-class="gaiji"]
//  .gloss-image-link` 后代链），稳压词典 (0,5,1)。守卫见
// test/anki/anki_gaiji_style_test.dart。
const _ankiGaijiSel =
    '.yomitan-glossary [data-dictionary] span[data-sc-img][data-sc-class="gaiji"]';
const _ankiGaijiImageStyle = '<style>'
    '$_ankiGaijiSel'
    '{display:inline!important;white-space:nowrap!important;vertical-align:baseline!important}'
    '$_ankiGaijiSel .gloss-image-link'
    '{display:inline-block!important;vertical-align:text-bottom!important;max-width:1.2em!important}'
    '$_ankiGaijiSel .gloss-image-link .gloss-image-container'
    '{display:inline-block!important;width:1em!important;height:1em!important;max-width:1em!important;max-height:1em!important;vertical-align:text-bottom!important;font-size:1em!important}'
    '$_ankiGaijiSel .gloss-image-link .gloss-image-sizer'
    '{display:none!important}'
    '$_ankiGaijiSel .gloss-image-link .gloss-image'
    '{position:static!important;width:1em!important;height:1em!important;vertical-align:text-bottom!important}'
    '</style>';

/// TODO-292: stable error codes carried back from the AnkiDroid platform
/// channel so the UI layer can map a known failure to a localized, actionable
/// hint instead of surfacing AnkiDroid's raw (English) exception text.
///
/// `collectionUnavailable` is raised when AnkiDroid's `AddContentApi` cannot
/// open the collection database (collection in use / mid-sync / corrupt,
/// AnkiDroid never opened once, API disabled, background process killed). This
/// is *external app state* the host app cannot fix; the app's job is to
/// classify it and tell the user what to do.
class AnkiErrorCode {
  const AnkiErrorCode._();

  /// Mirror of the Java `ANKI_COLLECTION_UNAVAILABLE` channel error code.
  static const String collectionUnavailable = 'ANKI_COLLECTION_UNAVAILABLE';

  /// TODO-752a：AnkiConnect 网络错误的稳定分类码。给用户看的 toast 文案必须由
  /// 主 app 按这些**与 locale 无关、永不乱码**的码映射本地化文案，而不是透传
  /// `SocketException`/`http.ClientException` 的 `toString()`——后者既是英文，又会在
  /// 「连远端进程/代理而非真 AnkiConnect」时把无 charset 的 GBK/UTF-8 错误页经
  /// package:http 的 latin1 默认解码弄成乱码。OS 原文只进诊断日志（[MineOutcome.error]）。
  ///
  /// `connectionRefused`：连接被拒（AnkiConnect 没在监听 / Anki 没开）。
  /// `connectionTimeout`：连接/响应超时（[TimeoutException]）。
  /// `httpError`：HTTP 层错误（http.ClientException，非超时非 socket）。
  /// `connectionUnknown`：其余无法分类的连接异常。
  static const String connectionRefused = 'ANKI_CONNECTION_REFUSED';
  static const String connectionTimeout = 'ANKI_CONNECTION_TIMEOUT';
  static const String httpError = 'ANKI_HTTP_ERROR';
  static const String connectionUnknown = 'ANKI_CONNECTION_UNKNOWN';
}

sealed class AnkiFetchResult {
  const AnkiFetchResult();
  const factory AnkiFetchResult.success({
    required List<AnkiDeck> decks,
    required List<AnkiNoteType> noteTypes,
  }) = AnkiFetchSuccess;
  const factory AnkiFetchResult.error(String message, {String? code}) =
      AnkiFetchError;
}

class AnkiFetchSuccess extends AnkiFetchResult {
  const AnkiFetchSuccess({required this.decks, required this.noteTypes});
  final List<AnkiDeck> decks;
  final List<AnkiNoteType> noteTypes;
}

class AnkiFetchError extends AnkiFetchResult {
  const AnkiFetchError(this.message, {this.code});
  final String message;

  /// Stable classification code (see [AnkiErrorCode]); null for unclassified
  /// errors, in which case [message] is shown verbatim as before.
  final String? code;
}

enum MineResult { success, duplicate, notConfigured, error }

/// 制卡（mineEntry）的结果。
///
/// [result] 是分类枚举，所有调用点据此 `switch` 分支（成功/重复/未配置/错误）。
/// 当 [result] == [MineResult.error] 时，[errorDetail] 带**简短的人类可读原因**
/// （用于 toast，例如 AnkiConnect 自身返回的错误文本、"字段全空" 等），
/// [error] / [stackTrace] 带**完整诊断**（由主 app 的 UI 层写入 ErrorLogService）。
///
/// BUG-089：旧实现 `mineEntry` 返回裸 `MineResult.error`，把真实失败原因丢在
/// 各后端的 `debugPrint`（默认不落 ErrorLogService），用户既看不到 toast 原因、
/// 错误日志页也查不到。hibiki_anki 是独立包、不能直接引用主 app 的
/// `ErrorLogService`，故把原因作为返回值带出，由主 app 负责记日志 + 展示。
class MineOutcome {
  const MineOutcome(
    this.result, {
    this.noteId,
    this.errorDetail,
    this.errorCode,
    this.error,
    this.stackTrace,
  });

  /// TODO-270：成功时可携带后端返回的 note id（AnkiConnect `addNote` 返回的整数
  /// 主键），供后续「更新已制卡片」（[updateMinedNote]）按 id 覆盖字段。
  /// [noteId] 默认为 `null`，现有不关心 id 的调用点 `MineOutcome.success()` 行为
  /// 不变（向后兼容，Never break userspace）。AnkiDroid 后端暂不回传 id（子任务 B），
  /// 仍走默认 `null`。
  const MineOutcome.success({this.noteId})
      : result = MineResult.success,
        errorDetail = null,
        errorCode = null,
        error = null,
        stackTrace = null;

  const MineOutcome.duplicate()
      : result = MineResult.duplicate,
        noteId = null,
        errorDetail = null,
        errorCode = null,
        error = null,
        stackTrace = null;

  const MineOutcome.notConfigured()
      : result = MineResult.notConfigured,
        noteId = null,
        errorDetail = null,
        errorCode = null,
        error = null,
        stackTrace = null;

  /// 失败：[detail] 简短原因（toast 的**回退**文案），[error]/[stackTrace] 完整诊断
  /// （错误日志）。[errorCode] 非空时表示这是一个**已分类**的失败（见 [AnkiErrorCode]），
  /// 主 app 据它映射本地化 toast 文案，[detail] 仅作为映射缺失时的英文回退；OS 原文
  /// 不进 [detail]，只进 [error]（TODO-752a：避免英文/latin1 乱码透传给用户）。
  MineOutcome.failure(
    String detail, {
    String? errorCode,
    Object? error,
    StackTrace? stackTrace,
  })  : result = MineResult.error,
        noteId = null,
        errorDetail = detail,
        errorCode = errorCode,
        error = error,
        stackTrace = stackTrace;

  final MineResult result;

  /// 仅在 [result] == [MineResult.success] 时可能非空：后端返回的 note id。
  /// 用于「制卡后更新同一张卡片字段」（[updateMinedNote]）。AnkiDroid 暂为 `null`。
  final int? noteId;

  /// 仅在 [result] == [MineResult.error] 时非空：简短的人类可读失败原因（回退文案）。
  final String? errorDetail;

  /// 仅在 [result] == [MineResult.error] 且失败**已分类**时非空：稳定分类码
  /// （见 [AnkiErrorCode]）。主 app 据它映射本地化 toast；为 `null` 时退回
  /// [errorDetail]（既有未分类失败的行为不变，Never break userspace）。
  final String? errorCode;

  /// 仅在错误时可能非空：原始异常对象（写入错误日志，含完整信息）。
  final Object? error;

  /// 仅在错误时可能非空：异常栈（写入错误日志）。
  final StackTrace? stackTrace;
}
