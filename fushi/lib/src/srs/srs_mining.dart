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

import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
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
    }
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
  final String typeId = destination.noteTypeId;
  if (typeId.isNotEmpty && typeId != store.lapisNoteTypeId) {
    final SrsNoteTypeView? view = await store.noteType(typeId);
    if (view != null && view.deletedAt == null && view.fields.isNotEmpty) {
      noteType = view;
    } else {
      noteTypeFellBack = true;
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
/// （映射成空串 = 明确不填）；没映射过、且字段名与 Lapis 同名的，沿用 Lapis 默认模板。
Map<String, String> srsEffectiveFieldMappings(
  SrsNoteTypeView noteType,
  Map<String, String>? stored,
) => <String, String>{
  for (final SrsFieldDef f in noteType.fields)
    f.id: stored?[f.id] ?? LapisNoteType.defaultFieldMappings[f.name] ?? '',
};

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
    final AnkiMiningPayload payload;
    try {
      payload = AnkiMiningPayload.fromJson(
        Map<String, dynamic>.from(jsonDecode(rawPayloadJson) as Map),
      );
    } catch (e, stack) {
      return MineOutcome.failure(
        'Invalid card data (payload parse failed): $e',
        error: e,
        stackTrace: stack,
      );
    }
    final bool allowDuplicate = settings.allowDupes || payload.allowDuplicate;
    if (!allowDuplicate &&
        await isDuplicate(payload.expression, payload.reading)) {
      return const MineOutcome.duplicate();
    }

    final SrsResolvedMiningDestination target =
        await resolveSrsMiningDestination(store, destination);
    final SrsNoteTypeView? noteType = target.noteType;

    // 字段映射：Lapis 固定用 Lapis 默认映射（按 fieldKey 换成 SRS 的 fieldId）；
    // 其它笔记类型用按类型存的映射，渲染时直接以 fieldId 为键。标签、紧凑释义等
    // 其余设置沿用用户的制卡设置。
    if (noteType == null) {
      final RenderedMinedFields rendered = await _render(
        settings: settings.copyWith(
          fieldMappings: LapisNoteType.defaultFieldMappings,
          selectedNoteTypeName: LapisNoteType.modelName,
        ),
        payload: payload,
        context: context,
      );
      final Set<String> lapisFields = LapisNoteType.fields.toSet();
      return _create(
        fieldsById: <String, String>{
          for (final MapEntry<String, String> e in rendered.fields.entries)
            if (lapisFields.contains(e.key) && e.value.isNotEmpty)
              srsLapisFieldId(store.profileUid, e.key): e.value,
        },
        noteTypeId: store.lapisNoteTypeId,
        firstFieldId: srsLapisFieldId(store.profileUid, 'Expression'),
        firstFieldName: 'Expression',
        target: target,
        settings: settings,
        context: context,
        audioWarning: rendered.audioWarning,
      );
    }
    final RenderedMinedFields rendered = await _render(
      settings: settings.copyWith(
        fieldMappings: srsEffectiveFieldMappings(
          noteType,
          destination.fieldMappingsByType[noteType.id],
        ),
        selectedNoteTypeName: noteType.name,
      ),
      payload: payload,
      context: context,
    );
    final Set<String> typeFields = <String>{
      for (final SrsFieldDef f in noteType.fields) f.id,
    };
    return _create(
      fieldsById: <String, String>{
        for (final MapEntry<String, String> e in rendered.fields.entries)
          if (typeFields.contains(e.key) && e.value.isNotEmpty) e.key: e.value,
      },
      noteTypeId: noteType.id,
      firstFieldId: noteType.fields.first.id,
      firstFieldName: noteType.fields.first.name,
      target: target,
      settings: settings,
      context: context,
      audioWarning: rendered.audioWarning,
    );
  }

  Future<MineOutcome> _create({
    required Map<String, String> fieldsById,
    required String noteTypeId,
    required String firstFieldId,
    required String firstFieldName,
    required SrsResolvedMiningDestination target,
    required AnkiSettings settings,
    required AnkiMiningContext context,
    required String? audioWarning,
  }) async {
    // 与 Anki 同一条规则：第一字段为空的笔记不建。
    if ((fieldsById[firstFieldId] ?? '').trim().isEmpty) {
      return MineOutcome.failure(
        'The first field "$firstFieldName" is empty; refusing to create the card.',
        errorCode: AnkiErrorCode.firstFieldEmpty,
      );
    }
    await store.createNote(
      noteTypeId: noteTypeId,
      fieldsById: fieldsById,
      deckId: target.deckId,
      tags: buildNoteTags(
        settings.tags,
        source: context.source,
        includeHibiki: settings.tagIncludeHibiki,
        includeCategory: settings.tagIncludeCategory,
        titleTag: context.bookTitleTag,
        collectionTag: context.collectionTag,
        charPositionTag: context.charPositionTag,
      ),
      source: srsSourceRefFromMiningContext(context),
    );
    return MineOutcome.success(
      deckName: target.deckName,
      audioWarning: audioWarning,
    );
  }

  /// 与 Anki 同步客户端同一形状：四路媒体并发准备，交给 [renderMediaPayload] 统一渲染。
  Future<RenderedMinedFields> _render({
    required AnkiSettings settings,
    required AnkiMiningPayload payload,
    required AnkiMiningContext context,
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
    );
  }
}

/// 打开 SRS 制卡所需的 store + 媒体目录（模块关着 / 打开失败时为 null）。
typedef SrsMinerResolver = Future<SrsMiner?> Function();

/// `ankiRepositoryProvider` 装饰链里的 SRS 层（见文件头）：制卡与判重都只走
/// Fushi 复习，不再发往内层 Anki。其余操作（设置、牌组、打开笔记等）照旧委托内层。
class SrsMiningAnkiRepository extends DelegatingAnkiRepository {
  SrsMiningAnkiRepository({
    required super.inner,
    required SrsMinerResolver miner,
  }) : _miner = miner;

  final SrsMinerResolver _miner;

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    final SrsMiner? miner = await _miner();
    if (miner == null) {
      return MineOutcome.failure('Fushi review is not available.');
    }
    return miner.mine(
      settings: await inner.loadSettings(),
      rawPayloadJson: rawPayloadJson,
      context: context,
    );
  }

  @override
  Future<bool> isDuplicate(String expression, String reading) async {
    final SrsMiner? miner = await _miner();
    return miner != null && await miner.isDuplicate(expression, reading);
  }
}
