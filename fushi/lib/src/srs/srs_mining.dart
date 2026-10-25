/// 挖词目标「Fushi SRS」（计划 PR3a）：制卡时把卡写进内置复习，而不是发往 Anki。
///
/// - [SrsMiner]：一次制卡落进 [SrsDbStore]。字段渲染与 Anki 三个后端是同一套
///   [AnkiNoteComposer]（`renderMediaPayload` → `buildMinedFields`），映射固定用
///   Lapis 的默认映射，按 [srsLapisFieldId] 换成 SRS 的 fieldId；媒体（单词音频、
///   句子音频、截图 / 封面、词典图片）存进 [SrsMediaStore]，字段里的引用换成存储后的
///   内容哈希文件名。查重用 SRS 的词状态（词形 + 读音，同形异读不算重复）。
/// - [SrsMiningAnkiRepository]：`ankiRepositoryProvider` 装饰链最外层。只有复习模块
///   开着且目标是「Fushi 复习」时才包这一层（见 anki_view_model.dart），模块关着时链上
///   根本没有它。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';

import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/anki/delegating_anki_repository.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_mining_target.dart';

/// 制卡上下文 → 笔记出处（拿不到定位时为 manual）。
SrsSourceRef srsSourceRefFromMiningContext(AnkiMiningContext context) {
  final CardSourceLink? link = context.sourceLink;
  final String? title = (context.documentTitle?.trim().isEmpty ?? true)
      ? null
      : context.documentTitle!.trim();
  if (link != null) {
    switch (link.kind) {
      case CardSourceKind.book:
        final String bookKey = link.bookKey ?? link.uid;
        if (link.chapterIndex == null &&
            link.charOffset == null &&
            link.startMs != null) {
          // 有声书时间轴（没有正文定位）。
          return SrsSourceRef.media(
            kind: SrsSourceKind.audiobook,
            mediaKey: bookKey,
            startMs: link.startMs!,
            endMs: link.endMs,
            title: title,
          );
        }
        return SrsSourceRef.book(
          bookKey: bookKey,
          sectionIndex: link.chapterIndex ?? 0,
          charStart: link.charOffset ?? 0,
          charLength: link.charLength,
          title: title,
        );
      case CardSourceKind.manga:
        return SrsSourceRef.manga(
          mangaKey: link.bookKey ?? link.uid,
          chapterKey: link.chapterId ?? '${link.chapterIndex ?? 0}',
          page: link.pageIndex ?? 0,
          title: title,
        );
      case CardSourceKind.video:
        final int start = context.clipStartMs ?? link.startMs ?? 0;
        final int? end = context.clipEndMs ?? link.endMs;
        final SrsSourceRef? online = _onlineVideoRef(
          link.uid,
          start,
          end,
          title,
        );
        if (online != null) return online;
        return SrsSourceRef.media(
          kind: SrsSourceKind.video,
          // 指纹（整文件 sha256）跨设备稳定；旧链接没有时退回库 uid。
          mediaKey: link.fingerprint ?? link.uid,
          startMs: start,
          endMs: end,
          title: title,
        );
      case CardSourceKind.game:
        return SrsSourceRef(SrsSourceKind.game, <String, Object?>{
          'gameId': link.uid,
          if (title != null) 'title': title,
        });
      case CardSourceKind.music:
        return SrsSourceRef.media(
          kind: SrsSourceKind.music,
          mediaKey: link.uid,
          startMs: context.clipStartMs ?? link.startMs ?? 0,
          endMs: context.clipEndMs ?? link.endMs,
          title: title,
        );
    }
  }
  // 外部网页（app 内浏览器制卡）：没有库内定位时按网址记出处。
  final Uri? webUrl = AnkiHandlebarRenderer.webSourceUrlOf(context.sourceUrl);
  if (webUrl != null) {
    return SrsSourceRef.web(webUrl.toString(), title: title);
  }
  if (context.source == AnkiMiningSource.game) {
    return SrsSourceRef(SrsSourceKind.game, <String, Object?>{
      if (title != null) 'title': title,
    });
  }
  return SrsSourceRef(SrsSourceKind.manual, <String, Object?>{
    if (title != null) 'title': title,
  });
}

/// Aniyomi 在线视频的库 uid：`anime-source:<扩展包>:<源 id>:<源内集 URL>`。
SrsSourceRef? _onlineVideoRef(String uid, int start, int? end, String? title) {
  const String prefix = 'anime-source:';
  if (!uid.startsWith(prefix)) return null;
  final List<String> parts = uid.substring(prefix.length).split(':');
  if (parts.length < 3) return null;
  return SrsSourceRef.onlineVideo(
    sourceId: '${parts[0]}:${parts[1]}',
    // 作品 URL 不在集 uid 里；集 URL 本身就是源内稳定身份。
    animeUrl: '',
    episodeUrl: parts.sublist(2).join(':'),
    startMs: start,
    endMs: end,
    title: title,
  );
}

/// [SrsMiningDestination] 解析后真正落地的牌组 / 笔记类型。
class SrsResolvedMiningDestination {
  const SrsResolvedMiningDestination({
    required this.deckId,
    required this.deckName,
    required this.noteType,
    required this.deckFellBack,
    required this.noteTypeFellBack,
  });

  final String deckId;
  final String? deckName;

  /// null = 内置 Lapis。
  final SrsNoteTypeView? noteType;

  /// 偏好里选的牌组 / 笔记类型已被删除（或不可用），回落到默认牌组 / Lapis。
  final bool deckFellBack;
  final bool noteTypeFellBack;

  bool get usesLapis => noteType == null;
}

/// 把偏好解析成落地位置：选中的牌组 / 笔记类型不存在（被删）时回落默认牌组 / Lapis。
/// 没有字段的笔记类型做不出卡，同样回落 Lapis。
Future<SrsResolvedMiningDestination> resolveSrsMiningDestination(
  SrsDbStore store,
  SrsMiningDestination destination,
) async {
  final SrsDeckTree tree = await store.deckTree();
  final bool wantsDeck = destination.deckId.isNotEmpty;
  final bool deckExists = wantsDeck && tree[destination.deckId] != null;
  final String deckId = deckExists ? destination.deckId : store.defaultDeckId;

  SrsNoteTypeView? noteType;
  bool noteTypeFellBack = false;
  // 从没选过（空串）= 内置 Fushi 卡片（2026-10-16 起的默认）；用户明确选过的（含 Lapis）原样。
  final bool chosen = destination.noteTypeId.isNotEmpty;
  final String typeId = chosen
      ? destination.noteTypeId
      : store.fushiCardNoteTypeId;
  if (typeId != store.lapisNoteTypeId) {
    final SrsNoteTypeView? view = await store.noteType(typeId);
    if (view != null && view.deletedAt == null && view.fields.isNotEmpty) {
      noteType = view;
    } else {
      // 内置 Fushi 卡片缺席（内置记录尚未播种）不算「选的被删了」，静默回落 Lapis。
      noteTypeFellBack = chosen;
    }
  }
  return SrsResolvedMiningDestination(
    deckId: deckId,
    deckName: tree[deckId] == null ? null : tree.fullName(deckId),
    noteType: noteType,
    deckFellBack: wantsDeck && !deckExists,
    noteTypeFellBack: noteTypeFellBack,
  );
}

/// 非 Lapis 笔记类型实际生效的字段映射（fieldId → 模板）：用户映射过的字段用用户的
/// （映射成空串 = 明确不填）；没映射过的按字段名猜（[srsGuessFieldMapping]：Lapis
/// 同名字段沿用 Lapis 默认模板，常见的「Front / Word / 单词」「Back / 意味」等
/// 同义名对到对应的制卡内容槽）；猜不到的留空。
///
/// 此前只认与 Lapis **完全同名**的字段，自建的「正面 / 背面」「Front / Back」类型
/// 设为挖词目标后所有字段都是「未映射」，不配置就制出空卡（截图巡检）。猜测只是
/// 默认值、不落库：用户在设置里改过的映射一律优先。
Map<String, String> srsEffectiveFieldMappings(
  SrsNoteTypeView noteType,
  Map<String, String>? stored,
) => <String, String>{
  for (final SrsFieldDef f in noteType.fields)
    f.id: stored?[f.id] ?? srsGuessFieldMapping(f.name) ?? '',
};

/// 制卡时字段实际用的映射（fieldId → 制卡占位符）：内置类型（[builtinKey] 非空）固定用各自的
/// 默认映射（按字段键定位，不受改名影响）；其它类型走 [srsEffectiveFieldMappings]。
/// 制卡与字段说明页（「制卡时自动填入什么」）共用这一处。
Map<String, String> srsMiningFieldMappingsFor({
  SrsNoteTypeView? type,
  required String? builtinKey,
  required String profileUid,
  Map<String, String>? stored,
}) {
  final SrsBuiltinNoteTypeSpec? builtin = srsBuiltinNoteTypeSpec(builtinKey);
  if (builtin != null) {
    return <String, String>{
      for (final MapEntry<String, String> e
          in builtin.defaultFieldMappings.entries)
        srsBuiltinFieldId(profileUid, builtin.key, e.key): e.value,
    };
  }
  return type == null
      ? const <String, String>{}
      : srsEffectiveFieldMappings(type, stored);
}

/// 字段名归一：小写、去掉空白与常见分隔符（`Expression Audio` = `expression_audio`）。
String _normalizeFieldName(String name) =>
    name.toLowerCase().replaceAll(RegExp(r'[\s_\-\.:/·・（）()\[\]【】「」]'), '');

/// Lapis 字段按归一名索引。
final Map<String, String> _lapisByNormalizedName = <String, String>{
  for (final MapEntry<String, String> e
      in LapisNoteType.defaultFieldMappings.entries)
    _normalizeFieldName(e.key): e.value,
};

/// 常见字段名（英 / 中 / 日，已归一）→ 制卡内容槽。只收语义明确的名字；拿不准的
/// （如裸 `notes` / `extra`）不猜，宁可留「未映射」让用户自己选。
const Map<String, String> _fieldNameSynonyms = <String, String>{
  // 词形
  'front': '{expression}',
  'word': '{expression}',
  'term': '{expression}',
  'vocab': '{expression}',
  'vocabulary': '{expression}',
  'targetword': '{expression}',
  'kanji': '{expression}',
  '单词': '{expression}',
  '生词': '{expression}',
  '词语': '{expression}',
  '词汇': '{expression}',
  '正面': '{expression}',
  '単語': '{expression}',
  '語彙': '{expression}',
  '表面': '{expression}',
  '見出し語': '{expression}',
  // 读音
  'reading': '{reading}',
  'kana': '{reading}',
  'hiragana': '{reading}',
  'wordreading': '{reading}',
  '读音': '{reading}',
  '读法': '{reading}',
  '假名': '{reading}',
  '読み': '{reading}',
  '読み方': '{reading}',
  'よみ': '{reading}',
  // 注音
  'furigana': '{furigana-plain}',
  'wordfurigana': '{furigana-plain}',
  '注音': '{furigana-plain}',
  '振假名': '{furigana-plain}',
  'ふりがな': '{furigana-plain}',
  // 释义
  'back': '{glossary-first}',
  'meaning': '{glossary-first}',
  'definition': '{glossary-first}',
  'translation': '{glossary-first}',
  'english': '{glossary-first}',
  '释义': '{glossary-first}',
  '意思': '{glossary-first}',
  '词义': '{glossary-first}',
  '翻译': '{glossary-first}',
  '中文': '{glossary-first}',
  '背面': '{glossary-first}',
  '意味': '{glossary-first}',
  '定義': '{glossary-first}',
  '訳': '{glossary-first}',
  '裏面': '{glossary-first}',
  'definitions': '{glossary}',
  'dictionary': '{glossary}',
  '词典': '{glossary}',
  '辞書': '{glossary}',
  // 例句
  'sentence': '{sentence}',
  'example': '{sentence}',
  'examplesentence': '{sentence}',
  'context': '{sentence}',
  '例句': '{sentence}',
  '句子': '{sentence}',
  '例文': '{sentence}',
  '文': '{sentence}',
  // 音频
  'audio': '{audio}',
  'sound': '{audio}',
  'wordaudio': '{audio}',
  'pronunciation': '{audio}',
  '发音': '{audio}',
  '音频': '{audio}',
  '音声': '{audio}',
  '発音': '{audio}',
  'sentenceaudio': '{sentence-audio}',
  'sentencesound': '{sentence-audio}',
  '例句音频': '{sentence-audio}',
  '例句发音': '{sentence-audio}',
  '例文音声': '{sentence-audio}',
  // 图片
  'picture': '{card-image}',
  'image': '{card-image}',
  'screenshot': '{card-image}',
  '图片': '{card-image}',
  '截图': '{card-image}',
  '图像': '{card-image}',
  '画像': '{card-image}',
  // 来源
  'source': '{source-link}',
  '来源': '{source-link}',
  '出典': '{source-link}',
  '出处': '{source-link}',
};

/// 按字段名猜一个制卡内容槽：Lapis 同名字段（大小写 / 分隔符不敏感）→ Lapis 默认；
/// 再查常见同义名表。猜不到返回 null。
String? srsGuessFieldMapping(String fieldName) {
  final String key = _normalizeFieldName(fieldName);
  if (key.isEmpty) return null;
  return _lapisByNormalizedName[key] ?? _fieldNameSynonyms[key];
}

/// 必须映射的字段：第一个字段（为空时制卡被拒，与 Anki 同规则）+ 任一卡片模板
/// **正面**直接引用的字段（`{{字段}}` / `{{kanji:字段}}`；只出现在 `{{#字段}}`
/// 条件段里的不算）——正面为空的卡片不会生成，那张卡就白建了。
Set<String> srsRequiredFieldIds(SrsNoteTypeView noteType) {
  final List<SrsFieldDef> fields = noteType.fields;
  if (fields.isEmpty) return const <String>{};
  final Map<String, String> idByName = <String, String>{
    for (final SrsFieldDef f in fields) f.name: f.id,
  };
  final Set<String> out = <String>{fields.first.id};
  final RegExp ref = RegExp(r'\{\{([^{}#^/!][^{}]*)\}\}');
  for (final SrsTemplateDef tpl in noteType.templates) {
    for (final RegExpMatch m in ref.allMatches(tpl.front)) {
      final String raw = m.group(1)!.trim();
      final String name = raw.substring(raw.lastIndexOf(':') + 1).trim();
      final String? id = idByName[name];
      if (id != null) out.add(id);
    }
  }
  return out;
}

/// 一次制卡落进 Fushi 复习（见文件头）。永不抛：失败一律变成 [MineOutcome]。
class SrsMiner with AnkiNoteComposer {
  SrsMiner({
    required this.store,
    required this.media,
    this.destination = const SrsMiningDestination(),
  });

  final SrsDbStore store;
  final SrsMediaStore media;
  final SrsMiningDestination destination;

  /// 这个词（词形 + 读音）SRS 里有没有卡。读音为空时按词形匹配。
  Future<bool> isDuplicate(String expression, String reading) async {
    if (expression.trim().isEmpty) return false;
    final Map<String, SrsTermStatus> hit = await store.lookupTermStatus(
      <SrsTermQuery>[
        SrsTermQuery(expression, reading.trim().isEmpty ? null : reading),
      ],
    );
    return hit.isNotEmpty;
  }

  /// 同词（词形 + 读音，口径同 [isDuplicate]）的全部现存笔记，新建的在前。
  Future<List<SrsNoteCacheRow>> matchingNotes(
    String expression,
    String reading,
  ) async {
    if (expression.trim().isEmpty) return const <SrsNoteCacheRow>[];
    final SrsTermQuery q = SrsTermQuery(
      expression,
      reading.trim().isEmpty ? null : reading,
    );
    final String key = q.termKey;
    if (key.isEmpty) return const <SrsNoteCacheRow>[];
    final SrsDatabase db = store.db;
    final List<SrsNoteCacheRow> rows =
        await (db.select(db.srsNotesCache)..where(
              (n) =>
                  n.profileUid.equals(store.profileUid) &
                  n.termKey.equals(key) &
                  n.deletedAt.isNull(),
            ))
            .get();
    final String rk = q.readingKey;
    return rows
        .where(
          (SrsNoteCacheRow n) =>
              rk.isEmpty || n.readingKey.isEmpty || n.readingKey == rk,
        )
        .toList()
      ..sort(
        (SrsNoteCacheRow a, SrsNoteCacheRow b) =>
            b.createdAt.compareTo(a.createdAt),
      );
  }

  /// 一条现存笔记及其笔记类型（不存在 / 已删为 null）。
  Future<(SrsNoteView, SrsNoteTypeView)?> _live(String noteId) async {
    final SrsNoteView? note = await store.note(noteId);
    if (note == null || note.deletedAt != null) return null;
    final SrsNoteTypeView? type = await store.noteType(note.noteTypeId);
    if (type == null) return null;
    return (note, type);
  }

  /// 现存笔记的字段（字段名 → 值）；不存在 / 已删为 null。
  ///
  /// 释义样式去重的引用行展开回内联 `<style>`：调用方（制卡回填出处卡片的乐观并发检查）
  /// 拿到的与它写进来的逐字节相同。
  Future<Map<String, String>?> fieldsByName(String noteId) async {
    final (SrsNoteView, SrsNoteTypeView)? live = await _live(noteId);
    if (live == null) return null;
    final (SrsNoteView note, SrsNoteTypeView type) = live;
    return <String, String>{
      for (final SrsFieldDef f in type.fields)
        f.name: await store.expandStyles(note.field(f.id)),
    };
  }

  /// 按字段名写一条现存笔记的部分字段（未给出的字段、标签、排程都不动）。
  Future<void> writeFieldsByName(
    String noteId,
    Map<String, String> fields,
  ) async {
    final (SrsNoteView, SrsNoteTypeView)? live = await _live(noteId);
    if (live == null) throw StateError('Fushi review note not found');
    final Map<String, String> idByName = <String, String>{
      for (final SrsFieldDef f in live.$2.fields) f.name: f.id,
    };
    for (final String name in fields.keys) {
      if (!idByName.containsKey(name)) {
        throw StateError('Fushi review note has no field "$name"');
      }
    }
    await store.updateNote(
      noteId,
      fieldsById: <String, String>{
        for (final MapEntry<String, String> e in fields.entries)
          idByName[e.key]!: e.value,
      },
    );
  }

  /// 字段里出现 [sourceId] 的现存笔记（只是候选：调用方再解析 href 确认身份）。
  Future<List<String>> sourceNoteCandidates(String sourceId) async {
    final SrsDatabase db = store.db;
    final query = db.selectOnly(db.srsFieldEdits, distinct: true)
      ..addColumns(<Expression<Object>>[db.srsFieldEdits.entityId])
      ..where(
        db.srsFieldEdits.profileUid.equals(store.profileUid) &
            db.srsFieldEdits.entityKind.equals(SrsEntityKind.note.wire) &
            db.srsFieldEdits.fieldKey.like('${SrsFieldKeys.noteField('')}%') &
            db.srsFieldEdits.json.like('%$sourceId%'),
      );
    final List<String> out = <String>[];
    for (final TypedResult r in await query.get()) {
      final String id = r.read(db.srsFieldEdits.entityId)!;
      if (await _live(id) != null) out.add(id);
    }
    return out;
  }

  bool _isLapis(SrsNoteTypeView? type) =>
      type == null || type.id == store.lapisNoteTypeId;

  /// [type] 制卡时实际用的字段映射（fieldId → 制卡占位符），同 [_mappingFor]。
  Map<String, String> miningFieldMappingsFor(SrsNoteTypeView type) =>
      _mappingFor(type);

  /// 笔记类型 → 渲染用的字段映射（键 = fieldId）。内置类型（Lapis、Fushi 卡片）固定用
  /// 各自的默认映射（按字段键定位，不受改名影响）；其它类型用按类型存的映射。
  Map<String, String> _mappingFor(SrsNoteTypeView? type) => _isLapis(type)
      ? srsMiningFieldMappingsFor(
          builtinKey: kSrsBuiltinLapisKey,
          profileUid: store.profileUid,
        )
      : srsMiningFieldMappingsFor(
          type: type,
          builtinKey: type!.builtinKey,
          profileUid: store.profileUid,
          stored: destination.fieldMappingsByType[type.id],
        );

  /// 同一套渲染（媒体存进 [media]，字段键 = fieldId）。标签、紧凑释义等其余设置
  /// 沿用用户的制卡设置。
  Future<RenderedMinedFields> _renderFor({
    required AnkiSettings settings,
    required AnkiMiningPayload payload,
    required AnkiMiningContext context,
    required SrsNoteTypeView? noteType,
    bool keepEmpty = false,
  }) => _render(
    settings: settings.copyWith(
      fieldMappings: _mappingFor(noteType),
      selectedNoteTypeName: _isLapis(noteType)
          ? LapisNoteType.modelName
          : noteType!.name,
    ),
    payload: payload,
    context: context,
    keepEmpty: keepEmpty,
  );

  List<String> _buildTags(AnkiSettings settings, AnkiMiningContext context) =>
      buildNoteTags(
        settings.noteTags,
        source: context.source,
        includeHibiki: settings.tagIncludeHibiki,
        includeCategory: settings.tagIncludeCategory,
        titleTag: context.bookTitleTag,
        collectionTag: context.collectionTag,
        charPositionTag: context.charPositionTag,
      );

  static MineOutcome? _parse(
    String rawPayloadJson,
    void Function(AnkiMiningPayload) onPayload,
  ) {
    try {
      onPayload(
        AnkiMiningPayload.fromJson(
          Map<String, dynamic>.from(jsonDecode(rawPayloadJson) as Map),
        ),
      );
      return null;
    } catch (e, stack) {
      return MineOutcome.failure(
        'Invalid card data (payload parse failed): $e',
        error: e,
        stackTrace: stack,
      );
    }
  }

  Future<MineOutcome> mine({
    required AnkiSettings settings,
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    try {
      return await _mine(settings, rawPayloadJson, context);
    } catch (e, stack) {
      return MineOutcome.failure(
        'Fushi review: $e',
        error: e,
        stackTrace: stack,
      );
    }
  }

  Future<MineOutcome> _mine(
    AnkiSettings settings,
    String rawPayloadJson,
    AnkiMiningContext context,
  ) async {
    late final AnkiMiningPayload payload;
    final MineOutcome? invalid = _parse(
      rawPayloadJson,
      (AnkiMiningPayload p) => payload = p,
    );
    if (invalid != null) return invalid;
    final bool allowDuplicate = settings.allowDupes || payload.allowDuplicate;
    if (!allowDuplicate &&
        await isDuplicate(payload.expression, payload.reading)) {
      return const MineOutcome.duplicate();
    }

    final SrsResolvedMiningDestination target =
        await resolveSrsMiningDestination(store, destination);
    final SrsNoteTypeView? noteType = target.noteType;
    final RenderedMinedFields rendered = await _renderFor(
      settings: settings,
      payload: payload,
      context: context,
      noteType: noteType,
    );
    final Map<String, String> mapping = _mappingFor(noteType);
    final Map<String, String> fieldsById = <String, String>{
      for (final MapEntry<String, String> e in rendered.fields.entries)
        if (mapping.containsKey(e.key) && e.value.isNotEmpty) e.key: e.value,
    };
    // 与 Anki 同一条规则：第一字段为空的笔记不建。
    final String firstFieldId = noteType == null
        ? srsLapisFieldId(store.profileUid, 'Expression')
        : noteType.fields.first.id;
    final String firstFieldName = noteType == null
        ? 'Expression'
        : noteType.fields.first.name;
    if ((fieldsById[firstFieldId] ?? '').trim().isEmpty) {
      return MineOutcome.failure(
        'The first field "$firstFieldName" is empty; refusing to create the card.',
        errorCode: AnkiErrorCode.firstFieldEmpty,
      );
    }
    final String noteId = await store.createNote(
      noteTypeId: noteType?.id ?? store.lapisNoteTypeId,
      fieldsById: fieldsById,
      deckId: target.deckId,
      tags: _buildTags(settings, context),
      source: srsSourceRefFromMiningContext(context),
    );
    return MineOutcome.success(
      // 整数句柄（与 AnkiConnect 兼容端点同一个派生）：弹窗据此进「可覆写」态，
      // 覆写 / 打开时由 [SrsDbStore.noteIdForAnkiNumericId] 换回笔记 id。
      noteId: SrsIds.ankiNumericId(noteId),
      deckName: target.deckName,
      audioWarning: rendered.audioWarning,
    );
  }

  /// 覆写一条现存笔记：按**它自己的**笔记类型用同一套渲染重写全部字段（没映射到的
  /// 字段写空，与 Anki 覆写同口径，BUG-2606），标签只增不减，牌组与排程不动。
  Future<MineOutcome> overwrite({
    required String noteId,
    required AnkiSettings settings,
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    try {
      final (SrsNoteView, SrsNoteTypeView)? live = await _live(noteId);
      if (live == null) {
        return MineOutcome.failure(
          'Fushi review: the card to overwrite no longer exists.',
        );
      }
      final (SrsNoteView note, SrsNoteTypeView type) = live;
      late final AnkiMiningPayload payload;
      final MineOutcome? invalid = _parse(
        rawPayloadJson,
        (AnkiMiningPayload p) => payload = p,
      );
      if (invalid != null) return invalid;
      final RenderedMinedFields rendered = await _renderFor(
        settings: settings,
        payload: payload,
        context: context,
        noteType: _isLapis(type) ? null : type,
        keepEmpty: true,
      );
      final Map<String, String> fields = <String, String>{
        for (final SrsFieldDef f in type.fields)
          f.id: rendered.fields[f.id] ?? '',
      };
      if (fields.values.every((String v) => v.trim().isEmpty)) {
        return MineOutcome.failure(
          'All fields are empty — refusing to clear an existing card.',
          errorCode: AnkiErrorCode.allFieldsEmpty,
        );
      }
      await store.updateNote(
        noteId,
        fieldsById: fields,
        tags: <String>{...note.tags, ..._buildTags(settings, context)}.toList(),
      );
      if (context.sourceLink != null ||
          AnkiHandlebarRenderer.webSourceUrlOf(context.sourceUrl) != null) {
        await store.editFields(SrsEntityKind.note, noteId, <String, Object?>{
          SrsFieldKeys.noteSource: srsSourceRefFromMiningContext(
            context,
          ).toJson(),
        });
      }
      final SrsDeckTree tree = await store.deckTree();
      final String? deckId = note.deckId;
      return MineOutcome.success(
        noteId: SrsIds.ankiNumericId(noteId),
        deckName: deckId == null || tree[deckId] == null
            ? null
            : tree.fullName(deckId),
        audioWarning: rendered.audioWarning,
      );
    } catch (e, stack) {
      return MineOutcome.failure(
        'Fushi review: $e',
        error: e,
        stackTrace: stack,
      );
    }
  }

  /// 「回到出处改卡」的候选字段（字段名 → 渲染值），按 [noteId] 这条笔记自己的类型
  /// 渲染。不建卡、不改卡；媒体先存进 [media]。
  Future<Map<String, String>> prepareFieldsFor({
    required String noteId,
    required AnkiSettings settings,
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    final (SrsNoteView, SrsNoteTypeView)? live = await _live(noteId);
    if (live == null) throw StateError('Fushi review note not found');
    final SrsNoteTypeView type = live.$2;
    final AnkiMiningPayload payload = AnkiMiningPayload.fromJson(
      Map<String, dynamic>.from(jsonDecode(rawPayloadJson) as Map),
    );
    final RenderedMinedFields rendered = await _renderFor(
      settings: settings,
      payload: payload,
      context: context,
      noteType: _isLapis(type) ? null : type,
      keepEmpty: true,
    );
    if (rendered.audioWarning != null) throw StateError(rendered.audioWarning!);
    return <String, String>{
      for (final SrsFieldDef f in type.fields)
        if (rendered.fields.containsKey(f.id)) f.name: rendered.fields[f.id]!,
    };
  }

  /// 与 Anki 同步客户端同一形状：四路媒体并发准备，交给 [renderMediaPayload] 统一渲染。
  Future<RenderedMinedFields> _render({
    required AnkiSettings settings,
    required AnkiMiningPayload payload,
    required AnkiMiningContext context,
    bool keepEmpty = false,
  }) async {
    Future<String?> addFile(String path) async {
      try {
        return await media.storeFile(File(path), name: p.basename(path));
      } on FileSystemException {
        return null;
      }
    }

    Future<AudioFetchOutcome> wordAudio() async {
      if (payload.audio.isEmpty) return const AudioFetchOutcome.none();
      final AnkiLocalAudio local = await materializeAnkiWordAudio(
        payload.audio,
        httpFailureReason: audioFetchHttpFailureReason,
        errorReason: audioFetchErrorReason,
      );
      final String? failure = local.failureReason;
      if (failure != null) return AudioFetchOutcome.failed(failure);
      final File? file = local.file;
      if (file == null) return const AudioFetchOutcome.none();
      final String? name = await addFile(file.path);
      return name == null
          ? const AudioFetchOutcome.none()
          : AudioFetchOutcome.stored(name);
    }

    Future<String?> dictionaryMedia(DictionaryMedia m) async {
      final String name = ankiDictionaryMediaCacheFilename(
        m.dictionary,
        m.path,
      );
      return addFile(
        '${ankiDictionaryMediaCacheDirPath()}${Platform.pathSeparator}$name',
      );
    }

    final List<Object?> results = await Future.wait<Object?>(<Future<Object?>>[
      context.coverPath != null
          ? addFile(context.coverPath!)
          : Future<String?>.value(),
      context.sentenceAudioPath != null && !context.synchronizedVideo
          ? addFile(context.sentenceAudioPath!)
          : Future<String?>.value(),
      wordAudio(),
      buildDictionaryMediaTags(payload.dictionaryMedia, dictionaryMedia),
    ]);
    final String? cover = results[0] as String?;
    final String? sentenceAudio = results[1] as String?;
    final AudioFetchOutcome audio = results[2]! as AudioFetchOutcome;
    return renderMediaPayload(
      settings: settings,
      payload: payload,
      context: context,
      coverRef: cover != null ? coverMediaRef(cover) : null,
      sentenceAudioRef: sentenceAudio != null ? '[sound:$sentenceAudio]' : null,
      processedAudio: audio.ref != null ? '[sound:${audio.ref}]' : '',
      dictionaryMediaTags: results[3]! as Map<String, String>,
      audioWarning: audio.failureReason,
      keepEmpty: keepEmpty,
    );
  }
}

/// 打开 SRS 制卡所需的 store + 媒体目录（模块关着 / 打开失败时为 null）。
typedef SrsMinerResolver = Future<SrsMiner?> Function();

/// 打开一条 SRS 笔记的编辑页（导航器不可用时返回 false）。
typedef SrsNoteOpener = Future<bool> Function(String noteId);

/// `ankiRepositoryProvider` 装饰链里的 SRS 层（见文件头）。挖词目标 = Fushi 复习时
/// 制卡链路上**会写卡或依赖 Anki 连接**的操作一律走复习，不再碰 Anki：
///
/// - 制卡 / 查重 / 覆写 / 同词反查 / 读字段 / 打开笔记 / 已删复核：走 SRS。笔记的
///   整数句柄 = [SrsIds.ankiNumericId]（与 AnkiConnect 兼容端点同一个派生）。
/// - 「回到出处改卡」：先在复习里找带这个出处的笔记；复习里没有才交给 Anki——出处
///   链接可能来自切换前制进 Anki 的卡，那张卡本来就在 Anki 里。
/// - 新卡按词频重排：走复习（[listNewCards] / [setNewCardPositions] 读写卡片的
///   新卡位置，见 [SrsDbStore.newCardsInDeck]），手动重排与制卡后自动重排都可用。
/// - Anki 专属能力（建笔记类型 / 牌组、改模板样式、媒体去重、同步片段模板探测）：
///   在此模式下关闭（能力位为 false / 明确报不可用），设置页对应入口已隐藏。
/// - 只读写本机偏好的设置读写（loadSettings / saveSettings / updateSettings /
///   readSettingsJson）照旧委托：标签、允许重复等共用设置就存在那里。
/// - fetchConfiguration：照旧委托（只读 Anki 的牌组 / 笔记类型清单，不写任何东西；
///   刷新入口在此模式下已隐藏）。
class SrsMiningAnkiRepository extends DelegatingAnkiRepository {
  SrsMiningAnkiRepository({
    required super.inner,
    required SrsMinerResolver miner,
    SrsNoteOpener? openNote,
    void Function()? onCardsAdded,
  }) : _miner = miner,
       _openNote = openNote,
       _onCardsAdded = onCardsAdded;

  final SrsMinerResolver _miner;
  final SrsNoteOpener? _openNote;

  /// 制卡成功写进复习后调用（装配处递增 `srsRevisionProvider`，牌组列表与首页
  /// 复习条的计数随之重读）。
  final void Function()? _onCardsAdded;

  /// 本仓库读到过的「出处 → 复习笔记」（[readSourceNote] 命中复习时记下），
  /// [prepareSourceNoteFields] 据此决定按哪条笔记的类型渲染。
  final Map<String, String> _srsSourceNotes = <String, String>{};

  static const String _unavailable = 'Fushi review is not available.';

  Future<SrsMiner> _requireMiner() async {
    final SrsMiner? miner = await _miner();
    if (miner == null) throw StateError(_unavailable);
    return miner;
  }

  /// 整数句柄 → 现存 SRS 笔记 id（不存在 / 已删 / 复习不可用为 null）。
  Future<String?> _noteIdOf(SrsMiner miner, int handle) async {
    final String? id = await miner.store.noteIdForAnkiNumericId(handle);
    if (id == null) return null;
    final SrsNoteView? note = await miner.store.note(id);
    return note == null || note.deletedAt != null ? null : id;
  }

  // ------------------------------------------------------------ 制卡 / 查重

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    final SrsMiner? miner = await _miner();
    if (miner == null) return MineOutcome.failure(_unavailable);
    final MineOutcome outcome = await miner.mine(
      settings: await inner.loadSettings(),
      rawPayloadJson: rawPayloadJson,
      context: context,
    );
    if (outcome.result == MineResult.success) _onCardsAdded?.call();
    return outcome;
  }

  @override
  Future<bool> isDuplicate(String expression, String reading) async {
    final SrsMiner? miner = await _miner();
    return miner != null && await miner.isDuplicate(expression, reading);
  }

  // ------------------------------------------------------------ 覆写 / 反查

  @override
  Future<MineOutcome> updateMinedNote({
    required int noteId,
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    final SrsMiner? miner = await _miner();
    if (miner == null) return MineOutcome.failure(_unavailable);
    final String? id = await _noteIdOf(miner, noteId);
    if (id == null) {
      return MineOutcome.failure(
        'Fushi review: the card to overwrite no longer exists.',
      );
    }
    try {
      // 出处身份跟着原卡走（与 Anki 覆写同口径）：覆写换了句子位置，sourceId 不变。
      context = await contextForExistingSourceNote(
        noteId,
        context,
        existingFields: await miner.fieldsByName(id),
      );
    } catch (e, stack) {
      return MineOutcome.failure(
        'Fushi review: $e',
        error: e,
        stackTrace: stack,
      );
    }
    return miner.overwrite(
      noteId: id,
      settings: await inner.loadSettings(),
      rawPayloadJson: rawPayloadJson,
      context: context,
    );
  }

  /// 「覆写范围 = 全部」时返回这个词最新的一条复习笔记；「仅最近一张」恒 null。
  @override
  Future<int?> findOverwriteTargetNoteId(
    String expression,
    String reading,
  ) async {
    final AnkiSettings settings = await inner.loadSettings();
    if (settings.overwriteScope != AnkiOverwriteScope.all) return null;
    final SrsMiner? miner = await _miner();
    if (miner == null) return null;
    final List<SrsNoteCacheRow> notes = await miner.matchingNotes(
      expression,
      reading,
    );
    return notes.isEmpty ? null : SrsIds.ankiNumericId(notes.first.id);
  }

  /// 新建的在前（句柄是哈希、大小不代表新旧，顺序以创建时间为准）。
  @override
  Future<List<MinedNoteRef>> findMatchingNotes(
    String expression,
    String reading,
  ) async {
    final SrsMiner? miner = await _miner();
    if (miner == null) return const <MinedNoteRef>[];
    return <MinedNoteRef>[
      for (final SrsNoteCacheRow n in await miner.matchingNotes(
        expression,
        reading,
      ))
        MinedNoteRef(
          noteId: SrsIds.ankiNumericId(n.id),
          preview: BaseAnkiRepository.previewFromFieldValue(n.sortField),
        ),
    ];
  }

  @override
  Future<Map<String, String>?> noteFields(int noteId) async {
    final SrsMiner? miner = await _miner();
    if (miner == null) return null;
    final String? id = await _noteIdOf(miner, noteId);
    return id == null ? null : miner.fieldsByName(id);
  }

  /// 复习是本机库，能回读：用户在复习里删掉的卡下次查词就变回「可制卡」。
  @override
  bool get canVerifyExistingCards => true;

  @override
  bool get switchesAppPerNote => false;

  @override
  Future<bool> forgetMinedCard(String expression) async => false;

  /// 只返回明确已不在复习里的句柄（复习不可用时返回空集：不知道 ≠ 已删）。
  @override
  Future<Set<int>> findDeletedNotes(Set<int> noteIds) async {
    final SrsMiner? miner = await _miner();
    if (miner == null) return const <int>{};
    return <int>{
      for (final int handle in noteIds)
        if (await _noteIdOf(miner, handle) == null) handle,
    };
  }

  // ------------------------------------------------------------ 打开笔记

  /// BUG-3783：笔记住在 Fushi 复习里，界面不能再说「Anki」。
  @override
  MinedNoteHome get minedNoteHome => MinedNoteHome.fushiReview;

  /// 打开走装配处注入的复习笔记打开器；没注入就打不开。
  @override
  bool get canOpenMinedNote => _openNote != null;

  @override
  Future<bool> openNoteInAnki(int noteId) async {
    final SrsNoteOpener? open = _openNote;
    final SrsMiner? miner = await _miner();
    if (open == null || miner == null) return false;
    final String? id = await _noteIdOf(miner, noteId);
    return id != null && await open(id);
  }

  /// 打开这个词**最新**的一条复习笔记（基类按句柄取最大，对哈希句柄不成立）。
  @override
  Future<AnkiOpenWordOutcome> openWordInAnki(
    String expression,
    String reading,
  ) async {
    if (expression.isEmpty) return AnkiOpenWordOutcome.failed;
    final SrsNoteOpener? open = _openNote;
    final SrsMiner? miner = await _miner();
    if (open == null || miner == null) return AnkiOpenWordOutcome.failed;
    final List<SrsNoteCacheRow> notes = await miner.matchingNotes(
      expression,
      reading,
    );
    if (notes.isEmpty) return AnkiOpenWordOutcome.noMatch;
    return await open(notes.first.id)
        ? AnkiOpenWordOutcome.opened
        : AnkiOpenWordOutcome.failed;
  }

  // ------------------------------------------------------------ 回到出处改卡

  /// 复习里带这个出处的笔记优先；复习里没有才问 Anki（切换前制进 Anki 的卡）。
  @override
  Future<AnkiSourceNote?> readSourceNote(String sourceId) async {
    CardSourceLink.validateSourceId(sourceId);
    final SrsMiner miner = await _requireMiner();
    final Map<String, Map<String, String>> matches =
        <String, Map<String, String>>{};
    for (final String id in await miner.sourceNoteCandidates(sourceId)) {
      final Map<String, String>? fields = await miner.fieldsByName(id);
      if (fields == null) continue;
      final bool carries = fields.values.any(
        (String f) => CardSourceLink.fromHtml(
          f,
        ).any((CardSourceLink l) => l.sourceId == sourceId),
      );
      if (carries) matches[id] = fields;
    }
    if (matches.isEmpty) {
      _srsSourceNotes.remove(sourceId);
      return inner.readSourceNote(sourceId);
    }
    if (matches.length != 1) {
      throw StateError('Card source identity is not unique');
    }
    final MapEntry<String, Map<String, String>> match = matches.entries.single;
    _srsSourceNotes[sourceId] = match.key;
    return AnkiSourceNote(
      sourceId: sourceId,
      noteId: SrsIds.ankiNumericId(match.key),
      fields: match.value,
    );
  }

  /// 乐观并发检查同 Anki（写前重读比对、写后复核）；原卡在 Anki 时交给 Anki。
  @override
  Future<void> patchSourceNote({
    required AnkiSourceNote original,
    required Map<String, String> fields,
  }) async {
    if (fields.isEmpty) return;
    final AnkiSourceNote? current = await readSourceNote(original.sourceId);
    final String? srsId = _srsSourceNotes[original.sourceId];
    if (srsId == null) {
      return inner.patchSourceNote(original: original, fields: fields);
    }
    if (current == null || current.noteId != original.noteId) {
      throw StateError('Source note identity changed');
    }
    for (final String field in fields.keys) {
      if (!original.fields.containsKey(field) ||
          !current.fields.containsKey(field) ||
          current.fields[field] != original.fields[field]) {
        throw StateError('Source note field changed: $field');
      }
    }
    await (await _requireMiner()).writeFieldsByName(srsId, fields);
    final AnkiSourceNote? verified = await readSourceNote(original.sourceId);
    if (verified == null || verified.noteId != current.noteId) {
      throw StateError('Source note identity changed after writing');
    }
    for (final MapEntry<String, String> entry in fields.entries) {
      if (verified.fields[entry.key] != entry.value) {
        throw StateError(
          'Source note field changed after writing: ${entry.key}',
        );
      }
    }
  }

  /// 出处在复习里时按那条笔记自己的类型渲染（媒体进复习的媒体库）；否则交给 Anki。
  @override
  Future<Map<String, String>> prepareSourceNoteFields({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    final String? sourceId = context.sourceLink?.sourceId;
    final String? srsId = sourceId == null ? null : _srsSourceNotes[sourceId];
    if (srsId == null) {
      return inner.prepareSourceNoteFields(
        rawPayloadJson: rawPayloadJson,
        context: context,
      );
    }
    return (await _requireMiner()).prepareFieldsFor(
      noteId: srsId,
      settings: await inner.loadSettings(),
      rawPayloadJson: rawPayloadJson,
      context: context,
    );
  }

  // ------------------------------------------------------------ Anki 专属：关闭

  @override
  bool get supportsNoteTypeEditing => false;

  @override
  Future<AnkiNoteTypeDefinition?> readNoteTypeDefinition(
    String modelName,
  ) async => null;

  @override
  Future<bool> updateNoteTypeStyling(String modelName, String css) async =>
      false;

  @override
  Future<bool> updateNoteTypeTemplates(
    String modelName,
    List<AnkiCardTemplate> templates,
  ) async => false;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async =>
      throw UnsupportedError(
        'Creating Anki note types is off while mining into Fushi review.',
      );

  @override
  Future<bool> createDeck(String name) async => throw UnsupportedError(
    'Creating Anki decks is off while mining into Fushi review.',
  );

  /// 复习卡面不是 Anki 模板，这条判据无从判定：null = 保持用户偏好。
  @override
  Future<bool?> rendersSynchronizedClip() async => null;

  @override
  bool get supportsMediaMaintenance => false;

  @override
  Future<bool> probeMediaMaintenance() async => false;

  @override
  Future<AnkiMediaDedupReport?> runMediaDedup({
    bool dryRun = false,
    Future<void> Function(Map<String, dynamic> entry)? onJournal,
    AnkiMediaDedupOnProgress? onProgress,
    bool Function()? shouldCancel,
  }) async => null;

  // ------------------------------------------------------------ 新卡按词频重排

  @override
  bool get supportsDeckReposition => true;

  /// [deckName]（复习牌组全名，含子牌组）里的新卡，形状对齐 AnkiConnect `cardsInfo`：
  /// 整数 id = [SrsIds.ankiNumericId]，`due` = 此刻的出卡位置，`fields` 只给重排取 rank
  /// 用的三种角色（见 [srsRepositionRoleFields]）。
  @override
  Future<List<AnkiCardInfo>> listNewCards(String deckName) async {
    final SrsMiner miner = await _requireMiner();
    final List<SrsNewCardEntry> entries = await miner.store.newCardsInDeck(
      deckName,
    );
    final Map<String, Map<String, String>> mappingByType =
        <String, Map<String, String>>{};
    return <AnkiCardInfo>[
      for (final SrsNewCardEntry e in entries)
        AnkiCardInfo(
          cardId: SrsIds.ankiNumericId(e.card.id),
          noteId: SrsIds.ankiNumericId(e.note.id),
          ord: e.ord,
          due: e.position,
          type: 0,
          queue: e.card.suspended ? -1 : 0,
          modelName: e.noteType.name,
          deckName: deckName,
          fields: srsRepositionRoleFields(
            e.note,
            e.noteType,
            mappingByType.putIfAbsent(
              e.noteType.id,
              () => miner.miningFieldMappingsFor(e.noteType),
            ),
          ),
        ),
    ];
  }

  /// 写回新卡位置。此刻已不是新卡（学过了 / 删了）或找不到的卡记进 failures、不写。
  @override
  Future<AnkiCardDueWriteResult> setNewCardPositions(
    List<AnkiCardDueUpdate> updates,
  ) async {
    if (updates.isEmpty) {
      return const AnkiCardDueWriteResult(
        written: 0,
        failures: <int, String>{},
      );
    }
    final SrsMiner miner = await _requireMiner();
    final Map<String, int> positions = <String, int>{};
    final Map<String, int> handleOf = <String, int>{};
    final Map<int, String> failures = <int, String>{};
    for (final AnkiCardDueUpdate u in updates) {
      final String? id = await miner.store.cardIdForAnkiNumericId(u.cardId);
      if (id == null) {
        failures[u.cardId] = 'card not found in Fushi review';
        continue;
      }
      positions[id] = u.due;
      handleOf[id] = u.cardId;
    }
    final Set<String> accepted = await miner.store.setNewCardPositions(
      positions,
    );
    for (final String id in positions.keys) {
      if (!accepted.contains(id)) {
        failures[handleOf[id]!] = 'card is no longer new';
      }
    }
    return AnkiCardDueWriteResult(written: accepted.length, failures: failures);
  }
}

/// 重排取 rank 用的字段：按这条笔记的类型**实际制卡用的映射**（[mapping]，fieldId →
/// 制卡占位符）找出表达式 / 读音 / 词频序三种角色落在哪个字段，以 Lapis 字段名
/// （`Expression` / `ExpressionReading` / `FreqSort`）交出去。`resolveNoteFieldRoles`
/// 的 Lapis 兜底按这些名字认，于是内置类型改过字段名、自建类型字段叫「正面 / 单词」
/// 都能认出词形，而不是落到「第一个字段」或整批判无词频。表达式没有映射时退到
/// 类型的词形字段，再退到第一个字段。
Map<String, String> srsRepositionRoleFields(
  SrsNoteView note,
  SrsNoteTypeView noteType,
  Map<String, String> mapping,
) {
  String? byToken(String token) {
    for (final SrsFieldDef f in noteType.fields) {
      if ((mapping[f.id] ?? '').contains(token)) return f.id;
    }
    return null;
  }

  final String? expression =
      byToken('{expression}') ??
      noteType.termFieldId ??
      noteType.fields.firstOrNull?.id;
  final String? reading = byToken('{reading}');
  final String? rank = byToken('{frequency-harmonic-rank}');
  return <String, String>{
    'Expression': expression == null ? '' : note.field(expression),
    if (reading != null) 'ExpressionReading': note.field(reading),
    if (rank != null) 'FreqSort': note.field(rank),
  };
}
