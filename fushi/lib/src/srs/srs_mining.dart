/// 挖词目标「Fushi SRS」（计划 PR3a）：制卡时把卡写进内置复习，而不是（或同时）发往 Anki。
///
/// - [SrsMiner]：一次制卡落进 [SrsDbStore]。字段渲染与 Anki 三个后端是同一套
///   [AnkiNoteComposer]（`renderMediaPayload` → `buildMinedFields`），映射固定用
///   Lapis 的默认映射，按 [srsLapisFieldId] 换成 SRS 的 fieldId；媒体（单词音频、
///   句子音频、截图 / 封面、词典图片）存进 [SrsMediaStore]，字段里的引用换成存储后的
///   内容哈希文件名。查重用 SRS 的词状态（词形 + 读音，同形异读不算重复）。
/// - [SrsMiningAnkiRepository]：`ankiRepositoryProvider` 装饰链最外层。只有复习模块
///   开着且目标不是「仅 Anki」时才包这一层（见 anki_view_model.dart），模块关着时链上
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

/// 一次制卡落进 Fushi 复习（见文件头）。永不抛：失败一律变成 [MineOutcome]。
class SrsMiner with AnkiNoteComposer {
  SrsMiner({required this.store, required this.media});

  final SrsDbStore store;
  final SrsMediaStore media;

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

    // 映射固定用 Lapis 默认映射（SRS 的内置笔记类型就是 Lapis）；标签、紧凑释义等
    // 其余设置沿用用户的 Anki 设置。
    final AnkiSettings lapis = settings.copyWith(
      fieldMappings: LapisNoteType.defaultFieldMappings,
      selectedNoteTypeName: LapisNoteType.modelName,
    );
    final RenderedMinedFields rendered = await _render(
      settings: lapis,
      payload: payload,
      context: context,
    );
    final Set<String> lapisFields = LapisNoteType.fields.toSet();
    final Map<String, String> fieldsById = <String, String>{
      for (final MapEntry<String, String> e in rendered.fields.entries)
        if (lapisFields.contains(e.key) && e.value.isNotEmpty)
          srsLapisFieldId(store.profileUid, e.key): e.value,
    };
    if ((fieldsById[srsLapisFieldId(store.profileUid, 'Expression')] ?? '')
        .trim()
        .isEmpty) {
      return MineOutcome.failure(
        'The first field "Expression" is empty; refusing to create the card.',
        errorCode: AnkiErrorCode.firstFieldEmpty,
      );
    }
    final String deckId = store.defaultDeckId;
    await store.createNote(
      noteTypeId: store.lapisNoteTypeId,
      fieldsById: fieldsById,
      deckId: deckId,
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
    final SrsDeckTree tree = await store.deckTree();
    return MineOutcome.success(
      deckName: tree[deckId] == null ? null : tree.fullName(deckId),
      audioWarning: rendered.audioWarning,
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

/// `ankiRepositoryProvider` 装饰链里的 SRS 层（见文件头）。
///
/// 两边结果的合并规则（目标 = 两者时）：
/// - 任一边失败 → 失败（用户必须知道有一边没进去；另一边已写入的不回滚）；
/// - 任一边新建成功 → 成功（Anki 边成功时用它的结果，保留 noteId / 牌组名）；
/// - Anki 边进了待发队列 → queued；
/// - 两边都重复 → 重复；Anki 未配置而 SRS 成功 → 成功。
class SrsMiningAnkiRepository extends DelegatingAnkiRepository {
  SrsMiningAnkiRepository({
    required super.inner,
    required SrsMiningTarget Function() target,
    required SrsMinerResolver miner,
  }) : _target = target,
       _miner = miner;

  final SrsMiningTarget Function() _target;
  final SrsMinerResolver _miner;

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    final SrsMiningTarget target = _target();
    if (!target.includesSrs) {
      return inner.mineEntry(rawPayloadJson: rawPayloadJson, context: context);
    }
    final SrsMiner? miner = await _miner();
    final MineOutcome srs = miner == null
        ? MineOutcome.failure('Fushi review is not available.')
        : await miner.mine(
            settings: await inner.loadSettings(),
            rawPayloadJson: rawPayloadJson,
            context: context,
          );
    if (!target.includesAnki) return srs;
    final MineOutcome anki = await inner.mineEntry(
      rawPayloadJson: rawPayloadJson,
      context: context,
    );
    return combineSrsAndAnkiOutcomes(srs: srs, anki: anki);
  }

  @override
  Future<bool> isDuplicate(String expression, String reading) async {
    final SrsMiningTarget target = _target();
    if (!target.includesSrs) return inner.isDuplicate(expression, reading);
    final SrsMiner? miner = await _miner();
    if (miner != null && await miner.isDuplicate(expression, reading)) {
      return true;
    }
    if (!target.includesAnki) return false;
    return inner.isDuplicate(expression, reading);
  }
}

/// 目标 = 两者时两边结果的合并（规则见 [SrsMiningAnkiRepository]）。
MineOutcome combineSrsAndAnkiOutcomes({
  required MineOutcome srs,
  required MineOutcome anki,
}) {
  if (anki.result == MineResult.error) return anki;
  if (srs.result == MineResult.error) return srs;
  if (anki.result == MineResult.success) return anki;
  if (anki.result == MineResult.queued) return anki;
  if (srs.result == MineResult.success) return srs;
  if (anki.result == MineResult.duplicate &&
      srs.result == MineResult.duplicate) {
    return anki;
  }
  // Anki 未配置、SRS 重复：这个词已经在复习里了。
  if (srs.result == MineResult.duplicate) return srs;
  return anki;
}
