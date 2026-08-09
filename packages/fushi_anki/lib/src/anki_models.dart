import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'lapis_blocks.dart';

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

/// 查重（以及据同一条件反查已存在卡）的**搜索范围**。
///
/// 用户痛点：Anki 的 `deck:X` 搜索包含 X 的子卡组，但**不包含**它的父卡组与兄弟
/// 子卡组。所以把制卡目标选成 `Lapis::Vocab` 时，Hibiki 只能查到这个子卡组里的卡；
/// 同一个词早先制在 `Lapis::Sentences` 或 `Lapis` 本身，就查不到、被当成新词。
/// Yomitan 对此有 duplicate scope 设置，Hibiki 之前恒等于 [deck]。
///
/// - [deck]（默认，等于旧行为）：只查当前选中的卡组（含其子卡组）。
/// - [deckRoot]：查当前卡组的**根卡组**及其全部子卡组（`Lapis::Vocab` → `Lapis`），
///   即用户说的「选子卡组也能查到整个 Lapis 的卡」。
/// - [collection]：不限卡组，整个 Anki 收藏集。
///
/// 仅对 AnkiConnect（桌面 Anki）有意义。AnkiDroid 后端经 ContentProvider
/// `findDuplicateNotes` 按笔记类型全库查，本来就等价 [collection]，不读此设置。
enum AnkiDuplicateScope {
  /// 当前卡组（含子卡组）——旧行为。
  deck,

  /// 当前卡组的根卡组及其全部子卡组。
  deckRoot,

  /// 整个收藏集，不限卡组。
  collection,
}

/// 把持久化字符串解析回 [AnkiDuplicateScope]；未知/缺失值容错回
/// [AnkiDuplicateScope.deck]（旧用户存档没有此字段 → 等价现状，Never break userspace）。
AnkiDuplicateScope ankiDuplicateScopeFromName(String? name) {
  switch (name) {
    case 'deckRoot':
      return AnkiDuplicateScope.deckRoot;
    case 'collection':
      return AnkiDuplicateScope.collection;
    case 'deck':
    default:
      return AnkiDuplicateScope.deck;
  }
}

/// TODO-1007/1008：一张**已存在于 Anki**的、与当前查词同条件匹配的卡片的轻量引用。
///
/// 用户痛点（根因）：旧的「点 ✓ 默默 return / 只覆写本会话最近一张」把「別处或上次会话
/// 建的同词卡」挡死——`findOverwriteTargetNoteId` 在 `overwriteScope != all` 时恒返回
/// `null`，AnkiDroid 后端更是无法按内容反查 note id。本类是新可达性链路的数据载体：
/// 两后端用「与查重同一条件」（第一字段=expression）反查所有命中卡，返回它们的
/// [noteId] + 一行预览（[preview]），交给宿主弹操作选择（命中多张时让用户选哪张），
/// 而不再默默取最近一张或静默无反应。
///
/// - [noteId]：Anki note id（AnkiConnect = findNotes 返回的 id；AnkiDroid = NoteInfo.getId）。
/// - [preview]：给用户区分多张命中卡用的一行文本（第一字段去 HTML 后的纯文本，可能为空）。
@immutable
class MinedNoteRef {
  const MinedNoteRef({required this.noteId, this.preview = ''});

  factory MinedNoteRef.fromJson(Map<String, dynamic> json) => MinedNoteRef(
        noteId: (json['noteId'] as num).toInt(),
        preview: json['preview']?.toString() ?? '',
      );

  /// Anki note id（创建时间戳毫秒，越大越新）。
  final int noteId;

  /// 给用户区分多张命中卡用的一行预览文本（第一字段去 HTML 后的纯文本，可能为空）。
  final String preview;

  Map<String, Object?> toJson() => <String, Object?>{
        'noteId': noteId,
        'preview': preview,
      };

  @override
  bool operator ==(Object other) =>
      other is MinedNoteRef &&
      other.noteId == noteId &&
      other.preview == preview;

  @override
  int get hashCode => Object.hash(noteId, preview);

  @override
  String toString() => 'MinedNoteRef(noteId: $noteId, preview: "$preview")';
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
    this.duplicateScope = AnkiDuplicateScope.deck,
    this.ankiConnectHost = 'localhost',
    this.ankiConnectPort = 8765,
    this.ankiConnectApiKey = '',
    this.ankiConnectUseHttps = false,
    this.useAnkiConnectOnAndroid = false,
    this.lapisFontScalePercent = 100,
    this.lapisCustomCss = '',
    this.lapisAppliedCssSha,
    this.lapisMigratedBaselineSha,
    this.lapisCustomBlocks = const <LapisCustomBlock>[],
    this.lapisAppliedTemplateSha,
    this.lastMediaDedupAtMs,
    this.lastMediaDedupScanAtMs,
    this.mediaDedupAutoEnabled = false,
    this.mediaDedupAutoDelete = false,
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
        fieldMappings: Map<String, String>.from(
          json['fieldMappings'] as Map? ?? {},
        ),
        tags: json['tags'] as String? ?? '',
        tagIncludeHibiki: json['tagIncludeHibiki'] as bool? ?? true,
        tagIncludeCategory: json['tagIncludeCategory'] as bool? ?? true,
        allowDupes: json['allowDupes'] as bool? ?? false,
        compactGlossaries: json['compactGlossaries'] as bool? ?? false,
        embedMedia: json['embedMedia'] as bool? ?? true,
        overwriteScope: ankiOverwriteScopeFromName(
          json['overwriteScope'] as String?,
        ),
        duplicateScope: ankiDuplicateScopeFromName(
          json['duplicateScope'] as String?,
        ),
        ankiConnectHost: json['ankiConnectHost'] as String? ?? 'localhost',
        ankiConnectPort: json['ankiConnectPort'] as int? ?? 8765,
        ankiConnectApiKey: json['ankiConnectApiKey'] as String? ?? '',
        ankiConnectUseHttps: json['ankiConnectUseHttps'] as bool? ?? false,
        useAnkiConnectOnAndroid:
            json['useAnkiConnectOnAndroid'] as bool? ?? false,
        lapisFontScalePercent: json['lapisFontScalePercent'] as int? ?? 100,
        lapisCustomCss: json['lapisCustomCss'] as String? ?? '',
        lapisAppliedCssSha: json['lapisAppliedCssSha'] as String?,
        lapisMigratedBaselineSha: json['lapisMigratedBaselineSha'] as String?,
        lapisCustomBlocks: lapisBlocksFromJson(json['lapisCustomBlocks']),
        lapisAppliedTemplateSha: json['lapisAppliedTemplateSha'] as String?,
        lastMediaDedupAtMs: json['lastMediaDedupAtMs'] as int?,
        lastMediaDedupScanAtMs: json['lastMediaDedupScanAtMs'] as int?,
        // 缺键 = 老装置升级上来：两个自动开关都默认关，升级不会凭空获得
        // 一条会动 Anki 媒体文件的自动路径。
        mediaDedupAutoEnabled: json['mediaDedupAutoEnabled'] as bool? ?? false,
        mediaDedupAutoDelete: json['mediaDedupAutoDelete'] as bool? ?? false,
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

  /// 查重 / 反查已存在卡的搜索范围（默认 [AnkiDuplicateScope.deck] = 旧行为：
  /// 只查当前卡组及其子卡组）。仅 AnkiConnect 生效，见 [AnkiDuplicateScope]。
  final AnkiDuplicateScope duplicateScope;
  final String ankiConnectHost;
  final int ankiConnectPort;
  final String ankiConnectApiKey;
  final bool ankiConnectUseHttps;

  /// Android normally talks to AnkiDroid through its Content Provider. Users
  /// who deliberately run AnkiConnect on another reachable machine can opt in
  /// to the HTTP backend instead. Missing keys stay false so upgrades preserve
  /// the existing AnkiDroid route.
  final bool useAnkiConnectOnAndroid;

  /// Lapis 卡片字号整体缩放百分比（100 = 原样）。只影响 Hibiki 推送的
  /// styling 用户区段，不写卡片数据。
  final int lapisFontScalePercent;

  /// 追加到 Lapis styling 用户区段的自由 CSS（客制化显示效果）。
  final String lapisCustomCss;

  /// Hibiki 上次成功推送到 Anki 的 Lapis styling 指纹（sha256）。null =
  /// 本机从未推送。自动迁移用它区分「Anki 端还是我们写的内容（可安全更新）」
  /// 与「被用户手改（不得静默覆盖）」。
  final String? lapisAppliedCssSha;

  /// Hibiki 上次把**出厂基线**（`LapisNoteType.template.css`）迁移到 Anki 时，
  /// 那份基线的指纹（sha256）。null = 本机从未记录过。
  ///
  /// 启动自动迁移的闸门（PR#457 审查 §10-3，用户拍板方案甲）：只有基线**真的
  /// 变了**（vendored Lapis 或 Hibiki delta 升级）才自动推送；用户改了字号/
  /// 自定义 CSS 但没点「应用样式到 Anki」时，绝不自动写 Anki。
  /// 与 [lapisAppliedCssSha] 分工不同：后者是「上次推了什么完整 styling」，
  /// 用于漂移判定（区分自有产物与手改）。
  final String? lapisMigratedBaselineSha;

  /// Lapis 卡片上的**自定义区域**（把已有字段摆到模板的另一个位置）。
  ///
  /// 这是区域的**单一真相源**：推送到 Anki 的背面模板由它派生
  /// （[composeLapisBackTemplate]），区域的样式 CSS 也由它派生。区域只改显示，
  /// 不新增/删除任何 Anki 字段——所以增删区域不会让 Anki 要求 full sync，也
  /// 永远不会删掉卡片数据。
  final List<LapisCustomBlock> lapisCustomBlocks;

  /// Hibiki 上次成功推送到 Anki 的**卡模板**指纹（sha256）。null = 本机从未推过
  /// 模板。与 [lapisAppliedCssSha] 同一套语义、各管一边：模板写坏是「卡片内容
  /// 不显示」，比 CSS 写坏严重一个量级，必须有自己的「是不是我们写的」判据，
  /// 不能借用 CSS 的指纹。
  final String? lapisAppliedTemplateSha;

  /// 上次媒体字节级去重**真删**完成时刻（epoch ms）。null = 从未跑过。
  final int? lastMediaDedupAtMs;

  /// 上次媒体去重**扫描**（含自动干跑）完成时刻（epoch ms）。null = 从未扫过。
  /// 自动处理据此按周期节流，避免每次启动都全量哈希媒体目录。
  final int? lastMediaDedupScanAtMs;

  /// 是否启用媒体去重的自动处理。**默认 false**（用户拍板方案 A 的核心：
  /// Hibiki 不会主动帮你省空间）；用户可以在设置页主动打开。
  ///
  /// 打开之后的行为仍然保守：自动路径只做**干跑**并把清单提示给用户，
  /// 必须用户确认才真删——除非用户另外显式打开 [mediaDedupAutoDelete]。
  final bool mediaDedupAutoEnabled;

  /// 自动处理是否可以**跳过确认直接删**。默认 false。只有
  /// [mediaDedupAutoEnabled] 也为 true 时才有意义（UI 上是它的从属开关）。
  ///
  /// 单独一个字段而不是把「自动 = 直接删」并进上面那个开关，是因为原实现的
  /// 缺陷正是「自动路径绕过确认框」；加回自动开关不能把这个坑一起加回来。
  final bool mediaDedupAutoDelete;

  bool get isConfigured => selectedDeckId != null && selectedNoteTypeId != null;

  AnkiNoteType? get selectedNoteType =>
      availableNoteTypes.firstWhereOrNull((t) => t.id == selectedNoteTypeId) ??
      (selectedNoteTypeName != null
          ? availableNoteTypes.firstWhereOrNull(
              (t) => t.name == selectedNoteTypeName,
            )
          : null);

  AnkiSettings copyWith({
    int? selectedDeckId,
    String? selectedDeckName,
    int? selectedNoteTypeId,
    String? selectedNoteTypeName,
    bool clearSelectedDeck = false,
    bool clearSelectedNoteType = false,
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
    AnkiDuplicateScope? duplicateScope,
    String? ankiConnectHost,
    int? ankiConnectPort,
    String? ankiConnectApiKey,
    bool? ankiConnectUseHttps,
    bool? useAnkiConnectOnAndroid,
    int? lapisFontScalePercent,
    String? lapisCustomCss,
    String? lapisAppliedCssSha,
    bool clearLapisAppliedCssSha = false,
    String? lapisMigratedBaselineSha,
    List<LapisCustomBlock>? lapisCustomBlocks,
    String? lapisAppliedTemplateSha,
    bool clearLapisAppliedTemplateSha = false,
    int? lastMediaDedupAtMs,
    int? lastMediaDedupScanAtMs,
    bool? mediaDedupAutoEnabled,
    bool? mediaDedupAutoDelete,
  }) =>
      AnkiSettings(
        selectedDeckId:
            clearSelectedDeck ? null : (selectedDeckId ?? this.selectedDeckId),
        selectedDeckName: clearSelectedDeck
            ? null
            : (selectedDeckName ?? this.selectedDeckName),
        selectedNoteTypeId: clearSelectedNoteType
            ? null
            : (selectedNoteTypeId ?? this.selectedNoteTypeId),
        selectedNoteTypeName: clearSelectedNoteType
            ? null
            : (selectedNoteTypeName ?? this.selectedNoteTypeName),
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
        duplicateScope: duplicateScope ?? this.duplicateScope,
        ankiConnectHost: ankiConnectHost ?? this.ankiConnectHost,
        ankiConnectPort: ankiConnectPort ?? this.ankiConnectPort,
        ankiConnectApiKey: ankiConnectApiKey ?? this.ankiConnectApiKey,
        ankiConnectUseHttps: ankiConnectUseHttps ?? this.ankiConnectUseHttps,
        useAnkiConnectOnAndroid:
            useAnkiConnectOnAndroid ?? this.useAnkiConnectOnAndroid,
        lapisFontScalePercent:
            lapisFontScalePercent ?? this.lapisFontScalePercent,
        lapisCustomCss: lapisCustomCss ?? this.lapisCustomCss,
        // 恢复「无标记区段」的备份时需要把指纹清回 null（视 Anki 端为来历
        // 不明，自动迁移不再动它），?? 链表达不了清空，故给显式清空开关。
        lapisAppliedCssSha: clearLapisAppliedCssSha
            ? null
            : (lapisAppliedCssSha ?? this.lapisAppliedCssSha),
        lapisMigratedBaselineSha:
            lapisMigratedBaselineSha ?? this.lapisMigratedBaselineSha,
        lapisCustomBlocks: lapisCustomBlocks ?? this.lapisCustomBlocks,
        lapisAppliedTemplateSha: clearLapisAppliedTemplateSha
            ? null
            : (lapisAppliedTemplateSha ?? this.lapisAppliedTemplateSha),
        lastMediaDedupAtMs: lastMediaDedupAtMs ?? this.lastMediaDedupAtMs,
        lastMediaDedupScanAtMs:
            lastMediaDedupScanAtMs ?? this.lastMediaDedupScanAtMs,
        mediaDedupAutoEnabled:
            mediaDedupAutoEnabled ?? this.mediaDedupAutoEnabled,
        mediaDedupAutoDelete: mediaDedupAutoDelete ?? this.mediaDedupAutoDelete,
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
        'duplicateScope': duplicateScope.name,
        'ankiConnectHost': ankiConnectHost,
        'ankiConnectPort': ankiConnectPort,
        'ankiConnectApiKey': ankiConnectApiKey,
        'ankiConnectUseHttps': ankiConnectUseHttps,
        'useAnkiConnectOnAndroid': useAnkiConnectOnAndroid,
        'lapisFontScalePercent': lapisFontScalePercent,
        'lapisCustomCss': lapisCustomCss,
        'lapisAppliedCssSha': lapisAppliedCssSha,
        'lapisMigratedBaselineSha': lapisMigratedBaselineSha,
        'lapisCustomBlocks': lapisBlocksToJson(lapisCustomBlocks),
        'lapisAppliedTemplateSha': lapisAppliedTemplateSha,
        'lastMediaDedupAtMs': lastMediaDedupAtMs,
        'lastMediaDedupScanAtMs': lastMediaDedupScanAtMs,
        'mediaDedupAutoEnabled': mediaDedupAutoEnabled,
        'mediaDedupAutoDelete': mediaDedupAutoDelete,
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
    this.phoneticTranscriptions = '',
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
      phoneticTranscriptions: json['phoneticTranscriptions'] as String? ?? '',
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

  /// Yomitan `ipa`-mode 词典的音标（IPA）HTML；纯声调（positions）词典恒为空。
  /// `{pitch-accent-positions}` 已默认并入音标（popup.js 制卡侧），本字段只服务
  /// 想把音标单独映射到独立字段的用户（Yomitan 命名 `{phonetic-transcriptions}`）。
  final String phoneticTranscriptions;
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

  /// galgame Hook 制卡（场景卡 / texthooker 行卡）—— 归「游戏」分类标签
  /// （写入 Anki 的标签字面量为 `game`）。BUG-1137：此前枚举没有游戏来源，
  /// gal 制卡链路吃 `video` 默认值，卡片被误标成视频。
  game,
}

class AnkiMiningContext {
  const AnkiMiningContext({
    required this.sentence,
    this.cueSentence,
    this.documentTitle,
    this.coverPath,
    this.sentenceAudioPath,
    this.sentenceOffset,
    this.source,
    this.bookTitleTag,
    this.collectionTag,
  });
  final String sentence;
  final String? cueSentence;
  final String? documentTitle;
  final String? coverPath;
  final String? sentenceAudioPath;
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

  /// 「自动添加书名到标签」开关开启且当前条目**归属某合集**时，调用方（reader / video）
  /// 算好的**已清洗合集名标签**（空格/Tab→下划线，单个 Anki tag 字面量）；不属任何合集、
  /// 开关关闭或无合集名时为 `null`，[BaseAnkiRepository.buildNoteTags] 不追加。
  ///
  /// 与 [bookTitleTag] 并列：视频从播放列表（系列）名取、reader 从书所属合集反查取，
  /// 二者字面量不同则各成一个 tag（Anki 里可按系列聚合、也可按单集/单本区分）；相同时由
  /// [buildNoteTags] 去重合并。见视频 `lookup_mining` / reader `mining` 注入点。
  final String? collectionTag;
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
        _singleGlossaryPrefix.length,
        handlebar.length - 1,
      );
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
      // BUG-1035：「首选词典释义」= 用户在弹窗里长按选中的那本，没长按才退回排在第一位
      // 的那本（[AnkiMiningPayload.glossaryFirst]，popup.js 的 singleGlossaries 首项）。
      //
      // 此前这里只读 glossaryFirst，而全模板里只有 {selected-glossary} 消费
      // [AnkiMiningPayload.selectedDictionary]。Lapis 出厂默认把 MainDefinition 映射成
      // {glossary-first}（lapis_note_type.dart），于是长按选词典对绝大多数用户是**死交互**：
      // 弹窗把词典标题染成主题色加粗（popup.css `.dict-label.selected`）给了明确「已选中」
      // 反馈，制出来的卡片主释义却恒是第一本。长按选中本就是「这张卡我要这本词典的释义」，
      // 让 first 退化成「无选中时的兜底」消除了这个特殊情况，无需任何用户改字段映射。
      //
      // 零破坏：没长按 → selectedDictionary 为空 → _singleGlossaryForDictionary 返回 ''
      // → 原样退回 glossaryFirst，行为逐字节不变。选中的词典名在 singleGlossaries 里查
      // 不到（理论上不该发生：两者同源于同一 dictName）时同样退回，不产出空字段。
      case '{glossary-first}':
        final String selectedGlossary = _singleGlossaryForDictionary(
          payload,
          payload.selectedDictionary,
        );
        return selectedGlossary.isNotEmpty
            ? selectedGlossary
            : payload.glossaryFirst;
      case '{selected-glossary}':
        return _singleGlossaryForDictionary(
          payload,
          payload.selectedDictionary,
        );
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
      case '{phonetic-transcriptions}':
        return payload.phoneticTranscriptions;
      case '{document-title}':
        return context.documentTitle ?? '';
      // {card-image} 是通用图片键（书籍封面 / 视频 GIF 共用，语义中性、名副其实）：
      // 阅读器场景 coverPath 是书籍封面，视频场景 coverPath 是 GIF/降级帧（见 video
      // lookup_mining）。这是 Lapis Picture 字段的默认映射（TODO-1298）。
      case '{card-image}':
        return context.coverPath ?? '';
      // {book-cover} / {video-clip} 是 {card-image} 的旧别名（历史命名），保留以兼容
      // 老配置与老卡片模板：三者都读同一个 coverPath，运行时零分叉、媒体嵌入零改动。
      case '{book-cover}':
        return context.coverPath ?? '';
      case '{video-clip}':
        return context.coverPath ?? '';
      // {sentence-audio} 是句子音频的通用键（语义中性、名副其实）：对应 Lapis
      // SentenceAudio 字段的默认映射，值就是 sentenceAudioPath（有声书 cue / 视频
      // 例句音频片段）。旧别名 {sasayaki-audio} 已由 BaseAnkiRepository 的
      // 载入期迁移一次性改写为本键，渲染器不再受理。
      case '{sentence-audio}':
        return context.sentenceAudioPath ?? '';
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
    '{phonetic-transcriptions}',
    '{document-title}',
    '{card-image}',
    '{book-cover}',
    '{video-clip}',
    '{sentence-audio}',
  ];

  static List<String> forTermDictionaries(List<String> dictionaryNames) => [
        ...coreOptions,
        ...dictionaryNames.toSet().map((name) => '{single-glossary-$name}'),
      ];

  /// 旧别名（历史命名）：语义与新键完全等价、渲染同一个值，保留只为兼容老配置与
  /// 老卡片模板——`{book-cover}` / `{video-clip}` → `{card-image}`（都读
  /// `context.coverPath`）。**渲染器永远继续认它们**，此集合只影响选择器
  /// 展示与「已弃用」标注，不改变任何写进 `fieldMappings` 的字面量真值。
  /// （音频旧别名 `{sasayaki-audio}` 不在此列：它已由 BaseAnkiRepository 的
  /// 载入期迁移一次性改写为 `{sentence-audio}`，运行时零残留。）
  static const Set<String> deprecatedAliases = <String>{
    '{book-cover}',
    '{video-clip}',
  };

  /// 字段占位符选择器的候选项：默认隐藏**没被用到的**旧别名（新用户只看到新键，
  /// 少三个等价重复项），但当前字段已经用着的旧别名必须继续出现——否则候选列表
  /// 不含当前值，当前选中项在 picker 里不可见、容易被误改成别的（同 BUG-952 那类
  /// 「value 不在 items」坑）。
  ///
  /// [currentValue] 是该字段当前映射的字面量：可能是裸 token，也可能是把多个 token
  /// 拼进 HTML 的大模板，故按子串包含判断（与 [anyFieldConsumesToken] 同一套语义）。
  static List<String> optionsForField({
    required List<String> dictionaryNames,
    required String currentValue,
  }) =>
      forTermDictionaries(dictionaryNames)
          .where(
            (String option) =>
                !deprecatedAliases.contains(option) ||
                currentValue.contains(option),
          )
          .toList();

  /// TODO-948/952 诊断（纯函数）：当前 note-type 的 [fieldMappings]（Anki 字段名 →
  /// handlebar 模板）里是否**有任何一个字段消费了** [token]（如 `{sentence}` /
  /// `{sentence-audio}`）。字段模板可以是裸 token，也可以是把多个 token 拼进 HTML 的
  /// 大模板，故按子串包含判断（与 [AnkiHandlebarRenderer.render] 用同一套 `{...}`
  /// token 语义）。fieldMappings 为空、或所有字段都映成 `-`/纯字面量时返回 false——
  /// 这正是「句子写进了 context 但卡片没字段接它 → 字段恒空」的可见判据。
  ///
  /// 注意：这只回答「**有没有字段引用这个 token**」，不渲染、不触碰运行时数据，纯
  /// 静态读 [fieldMappings]，因此可单元测试、零副作用。
  static bool anyFieldConsumesToken(
    Map<String, String> fieldMappings,
    String token,
  ) =>
      fieldMappings.values.any((String template) => template.contains(token));

  /// TODO-948/952：是否有字段消费句子文本（`{sentence}` 或语义等价的
  /// `{cue-sentence}`，后者在有声书 cue 场景下也渲染句子文本）。两者任一被引用即视为
  /// 「句子有去处」，避免把只用了 `{cue-sentence}` 的 Lapis 变体误报成未映射。
  static bool anyFieldConsumesSentence(Map<String, String> fieldMappings) =>
      anyFieldConsumesToken(fieldMappings, '{sentence}') ||
      anyFieldConsumesToken(fieldMappings, '{cue-sentence}');

  /// 是否有字段消费句子音频（`{sentence-audio}`）。旧别名 `{sasayaki-audio}`
  /// 已由载入期迁移一次性改写，不再参与判定。
  static bool anyFieldConsumesSentenceAudio(
    Map<String, String> fieldMappings,
  ) =>
      anyFieldConsumesToken(fieldMappings, '{sentence-audio}');

  /// 是否有字段消费卡片图片（`{card-image}` 或语义等价的旧别名 `{book-cover}` /
  /// `{video-clip}`）。三者任一被引用即视为「卡片图片有去处」，避免把 TODO-1298
  /// 改名前建的、Picture 仍映射到旧别名 `{book-cover}` 的老配置误报成未映射（与
  /// [AnkiHandlebarRenderer.render] 同一套别名语义：三者都渲染 context.coverPath）。
  static bool anyFieldConsumesCardImage(Map<String, String> fieldMappings) =>
      anyFieldConsumesToken(fieldMappings, '{card-image}') ||
      anyFieldConsumesToken(fieldMappings, '{book-cover}') ||
      anyFieldConsumesToken(fieldMappings, '{video-clip}');
}

/// 扩展名（小写、不含点）→ MIME（**镜像副本**，命名统一轮 G8）。
///
/// 真相源是 hibiki_core `kMimeTypeByExtension`（单一 MIME 映射表）。hibiki_anki
/// 是刻意无 hibiki_core 依赖的独立模块，无法直接查那张表，故持有此逐项镜像；
/// `fushi/test/sync/mime_types_test.dart` 的守卫测试锁定两表完全一致——改动任一侧
/// 必须同步另一侧，否则该测试红。
const Map<String, String> kAnkiMimeTypeByExtension = <String, String>{
  // ── 文档 / 容器 ──
  'json': 'application/json',
  'epub': 'application/epub+zip',
  'css': 'text/css',
  'js': 'application/javascript',
  'xhtml': 'text/html',
  'html': 'text/html',
  'htm': 'text/html',
  'xht': 'text/html',
  // ── 图片 ──
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'gif': 'image/gif',
  'webp': 'image/webp',
  // 制卡封面动图的默认格式（`MiningAnimatedFormat.avif`），见 hibiki_core 侧同项注释。
  'avif': 'image/avif',
  'svg': 'image/svg+xml',
  // ── 字体 ──
  'woff': 'font/woff',
  'woff2': 'font/woff2',
  'ttf': 'font/ttf',
  'otf': 'font/otf',
  // ── 音频 ──
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'm4b': 'audio/mp4',
  'aac': 'audio/aac',
  'wav': 'audio/wav',
  'ogg': 'audio/ogg',
  'flac': 'audio/flac',
  // ── 视频 ──
  'mp4': 'video/mp4',
  'm4v': 'video/mp4',
  'mkv': 'video/x-matroska',
  'webm': 'video/webm',
  'avi': 'video/x-msvideo',
  'mov': 'video/quicktime',
  'ts': 'video/mp2t',
  'm2ts': 'video/mp2t',
  'mts': 'video/mp2t',
  'flv': 'video/x-flv',
  'wmv': 'video/x-ms-wmv',
  'mpg': 'video/mpeg',
  'mpeg': 'video/mpeg',
  'ogv': 'video/ogg',
  '3gp': 'video/3gpp',
  // ── 字幕 ──
  'srt': 'text/plain; charset=utf-8',
  'ass': 'text/plain; charset=utf-8',
  'ssa': 'text/plain; charset=utf-8',
  'vtt': 'text/vtt; charset=utf-8',
};

/// 按 [path] 的扩展名推断 Anki 媒体上传的 MIME；无扩展名或未知扩展名回退
/// application/octet-stream。查 [kAnkiMimeTypeByExtension]（hibiki_core 单一
/// MIME 表的镜像，见其 doc）。
String mimeTypeForPath(String path) {
  int slash = -1;
  for (int i = path.length - 1; i >= 0; i--) {
    final String c = path[i];
    if (c == '/' || c == r'\') {
      slash = i;
      break;
    }
  }
  final String name = path.substring(slash + 1);
  final int dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) {
    return 'application/octet-stream';
  }
  final String ext = name.substring(dot + 1).toLowerCase();
  return kAnkiMimeTypeByExtension[ext] ?? 'application/octet-stream';
}

/// 制卡时词典媒体（gaiji 外字、词典内嵌图等）落盘缓存目录。
///
/// 流程：主 app 在收到 JS `mineEntry` 负载后，把每个 [DictionaryMedia] 的字节
/// （`FushiDicts.getMediaFile`）写到这个目录；两个 Anki repo（AnkiConnect /
/// AnkiDroid）再从这里 **按同一命名** 读出并 storeMediaFile。writer 与 reader
/// 必须共用 [ankiDictionaryMediaCacheDirPath] + [ankiDictionaryMediaCacheFilename]，
/// 否则文件名对不上 → repo 读不到 → 卡片留下未替换的 `fushi_dict_N.ext` 坏图。
String ankiDictionaryMediaCacheDirPath() =>
    '${Directory.systemTemp.path}/anki-media';

/// 词典媒体在缓存目录中的文件名：`hibiki_dict_<sha1(dictionary NUL path)>.<ext>`。
///
/// 哈希输入是 **词典名 + NUL(`\u0000`) 分隔 + 相对路径**（BUG-904）：只对 `path`
/// 求哈希时，两本词典含同一相对路径的外字（例如都叫 `gaiji/参照.svg`）会算出同一
/// 文件名 → 后制卡的词典嵌入前者的图片（跨词典串味）。把词典名纳入哈希输入即可让
/// 同 path 不同词典产生不同文件名；用 NUL 分隔避免 `('ab','c')` 与 `('a','bc')`
/// 拼接后相同的歧义。writer 与各 Anki backend 都传各自 [DictionaryMedia] 的
/// `dictionary`，共用这个 helper 读写缓存，命名才对得上。
///
/// 无扩展名（path 不含 `.` 或以 `.` 结尾）时回退 `bin`（HBK-AUDIT-062：旧
/// `split('.').last` 在无点时返回整串当扩展名）。
///
/// 不使用 [String.hashCode]：它不是持久化文件名契约，跨运行时/平台/编译模式不保证
/// 稳定（BUG-640）。稳定 SHA-1 文件名可避免 iOS/Android/桌面制卡时偶发读不到外字 SVG。
String ankiDictionaryMediaCacheFilename(String dictionary, String path) {
  final lastDot = path.lastIndexOf('.');
  final ext = (lastDot >= 0 && lastDot < path.length - 1)
      ? path.substring(lastDot + 1)
      : 'bin';
  final digest = sha1.convert(utf8.encode('$dictionary\u0000$path')).toString();
  return 'hibiki_dict_$digest.$ext';
}

/// Kind of audio reference resolved by [WordAudioResolver] and handed to the
/// repo media-store paths.
enum AnkiAudioRefKind { empty, remoteUrl, dataUri, localFile }

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
    // BUG-1050：查词弹窗把命中本地音频库的单词发音编码成 `data:<mime>;base64,…`
    // （audioRefToWebViewUrl，本为弹窗 HTML5 <audio> 播放而生）。视频/沉浸制卡时该
    // URI 原样进 fields['audio']；它既不是 http 也不是真实文件路径——早先落到
    // localFile 分支被当成不存在的文件（existsSync()==false）静默丢弃，导致本地源
    // 单词发音永远进不了卡。识别为独立 kind，由各 repo 解码内联字节入库（远程 http
    // 发音源本就正常，不受影响）。
    if (ref.startsWith('data:')) return AnkiAudioRefKind.dataUri;
    return AnkiAudioRefKind.localFile;
  }

  /// Resolves a [AnkiAudioRefKind.localFile] ref to a filesystem path,
  /// decoding `file://` URIs and returning bare paths unchanged.
  static String localPath(String ref) =>
      ref.startsWith('file://') ? Uri.parse(ref).toFilePath() : ref;

  /// Decodes a [AnkiAudioRefKind.dataUri] ref (`data:<mime>;base64,<payload>`,
  /// produced by `audioRefToWebViewUrl` for popup HTML5 playback and reused
  /// verbatim as the mine payload's audio field) into its raw bytes plus a
  /// filename extension derived from the MIME type. Returns null when [ref] is
  /// not a well-formed data: URI or carries no bytes, so callers fall back to
  /// "no audio" instead of writing a broken media file into the card.
  static AnkiAudioData? decodeDataUri(String ref) {
    if (!ref.startsWith('data:')) return null;
    final UriData data;
    try {
      data = UriData.parse(ref);
    } catch (_) {
      return null;
    }
    final Uint8List bytes;
    try {
      bytes = data.contentAsBytes();
    } catch (_) {
      return null;
    }
    if (bytes.isEmpty) return null;
    return AnkiAudioData(
      bytes: bytes,
      extension: _audioExtForMime(data.mimeType),
    );
  }

  /// Inverse of `audioMimeForPath`: the filename extension to store a decoded
  /// `data:` audio payload under, from its MIME type. Unknown types fall back to
  /// `mp3` (the dominant word-audio format).
  static String _audioExtForMime(String mime) {
    switch (mime.toLowerCase()) {
      case 'audio/mpeg':
        return 'mp3';
      case 'audio/ogg':
        return 'ogg';
      case 'audio/mp4':
      case 'audio/aac':
        return 'm4a';
      case 'audio/wav':
      case 'audio/x-wav':
        return 'wav';
      case 'audio/flac':
        return 'flac';
      case 'audio/webm':
        return 'webm';
      default:
        return 'mp3';
    }
  }
}

/// Decoded inline audio payload from a [AnkiAudioRefKind.dataUri] ref: the raw
/// [bytes] and the filename [extension] to store them under in Anki media.
class AnkiAudioData {
  const AnkiAudioData({required this.bytes, required this.extension});
  final Uint8List bytes;
  final String extension;
}

String ankiInlineMediaReference(String addMediaResult) {
  final imageSrc = RegExp(
    r'''<img\s+[^>]*src=["']([^"']+)["'][^>]*>''',
  ).firstMatch(addMediaResult);
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

  /// BUG-824：AnkiDroid 运行时权限（`READ_WRITE_DATABASE`）未授予的稳定分类码。
  /// native `requirePermission` 守卫返回的 `PERMISSION_DENIED` 码（见
  /// AnkiChannelHandler.java）映射到这里，让主 app 用本地化、可操作的文案提醒用户
  /// «请在弹出的系统对话框中授予权限后重试»，而不是把 provider 抛出的英文
  /// «Permission not granted for: CardContentProvider.query /decks» 直接塞进 toast。
  static const String permissionDenied = 'ANKI_PERMISSION_DENIED';

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
    this.audioWarning,
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
  ///
  /// TODO-779：[audioWarning] 是**部分成功**信号——卡片已建好，但单词远程音频下载
  /// 失败（非 200 / 网络异常），`[sound:]` 落空。非空时带**简短人类可读原因**
  /// （含 HTTP 码/URL，由 [BaseAnkiRepository.audioFetchHttpFailureReason] /
  /// [BaseAnkiRepository.audioFetchErrorReason] 生成），让主 app 在成功 toast 后追加
  /// 「音频获取失败: …」提示，终结用户「没音频不知为何」的盲猜。默认 `null`（音频本就
  /// 没有、或下载成功）时行为与旧版一致（Never break userspace）。
  const MineOutcome.success({this.noteId, this.audioWarning})
      : result = MineResult.success,
        errorDetail = null,
        errorCode = null,
        error = null,
        stackTrace = null;

  const MineOutcome.duplicate()
      : result = MineResult.duplicate,
        noteId = null,
        audioWarning = null,
        errorDetail = null,
        errorCode = null,
        error = null,
        stackTrace = null;

  const MineOutcome.notConfigured()
      : result = MineResult.notConfigured,
        noteId = null,
        audioWarning = null,
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
        audioWarning = null,
        errorDetail = detail,
        errorCode = errorCode,
        error = error,
        stackTrace = stackTrace;

  final MineResult result;

  /// 仅在 [result] == [MineResult.success] 时可能非空：后端返回的 note id。
  /// 用于「制卡后更新同一张卡片字段」（[updateMinedNote]）。AnkiDroid 暂为 `null`。
  final int? noteId;

  /// 仅在 [result] == [MineResult.success] 时可能非空：单词远程音频下载失败的
  /// **简短人类可读原因**（含 HTTP 码/URL）。卡片仍已建好，只是 `[sound:]` 落空；
  /// 主 app 据它在成功 toast 后追加「音频获取失败」提示。`null` = 音频本就没有或
  /// 下载成功（TODO-779）。
  final String? audioWarning;

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
