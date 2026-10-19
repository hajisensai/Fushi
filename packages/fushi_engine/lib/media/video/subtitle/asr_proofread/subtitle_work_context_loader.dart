/// 从本机库组装视频字幕 AI 校对的作品上下文（spec
/// `2026-10-19-video-asr-llm-subtitle-pipeline` 第 3 节 S0「刮削数据（权威，免查）」）。
///
/// 只读 Drift：app 与无头服务端都能用。逻辑与 app 侧
/// `VideoMetadataCreditRepository.forCollection / forBook`（角色与声优）、
/// `libraryVideoSubtitleTarget`（成员 → 合集 → 作品的解析）同源，在引擎里用
/// drift 查询重新组装，不依赖 app 包。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';
import 'package:path/path.dart' as p;

/// 没有库内身份（未入库的文件 / CLI）时的作品键：有目录用 `folder:<sha1(目录)>`，
/// 否则 `title:<sha1(标题)>`。
///
/// 目录归一化：`\` 统一成 `/`、折叠 `.` / `..` / 重复分隔符、去掉末尾分隔符——同一
/// 目录换个写法不该换一张专名表。不做大小写折叠（Linux 路径区分大小写）。
/// 标题归一化：去首尾空白、连续空白折成一个、转小写。标题去掉空白后为空且没有
/// 目录时抛 [ArgumentError]：空键会让所有无名视频共用一张表。
String fallbackSubtitleWorkKey({String? folderPath, required String title}) {
  final String folder = folderPath?.trim() ?? '';
  if (folder.isNotEmpty) {
    String normalized = p.posix.normalize(folder.replaceAll(r'\', '/'));
    while (normalized.length > 1 && normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return 'folder:${_sha1(normalized)}';
  }
  final String normalizedTitle = title
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ')
      .toLowerCase();
  if (normalizedTitle.isEmpty) {
    throw ArgumentError.value(title, 'title', 'empty title and no folder');
  }
  return 'title:${_sha1(normalizedTitle)}';
}

String _sha1(String text) => sha1.convert(utf8.encode(text)).toString();

/// 视频成员在 `media_collection_items.media_type` 里的值。
const String _kVideoMediaType = 'video';

/// `media_collections.collection_type` 的播放列表值：播放列表可以混排多部作品，
/// 一个视频在播放列表里不代表它属于那部「作品」。
const String _kPlaylistCollectionType = 'playlist';

/// `video_metadata_credits.credit_kind` 的声优值（见 `VideoMetadataDatabaseStore`）。
const String _kVoiceActorCreditKind = 'voice_actor';

/// SQLite 绑定参数上限以内的分块大小。
const int _kInChunk = 500;

/// 作品键的判定（[SubtitleWorkContext.workKey]）：
///
/// - 合集：`collection:<合集 id>`。一个视频属于某个**非播放列表**合集、且该合集
///   解析得到作品行（合集自己的行，或成员上唯一的一条单集行——
///   `resolveVideoMetadataWorkForCollection` 同一判据）时也取这个键，于是从合集页
///   与从这一集进来拿到的是同一张表；合集日后从「按单集刮」变成「整体刮」时键不变。
/// - 单个视频自己挂着作品行、又不在上面那种合集里（独立电影 / 按集各自刮的
///   电影合集）：`work:<video_metadata_works.id>`。
/// - 没刮削但在非播放列表合集里：`collection:<合集 id>`（各集仍共用一张表）。
/// - 都不是：返回 null，由调用方用 [fallbackSubtitleWorkKey]（目录 / 标题）兜底。
class SubtitleWorkContextLoader {
  const SubtitleWorkContextLoader(this.database);

  final FushiDatabase database;

  /// 合集（显式给出的合集 id，含播放列表——调用方点名要它）。合集不存在返回 null。
  Future<SubtitleWorkContext?> forCollection(int collectionId) async {
    final MediaCollectionRow? collection = await database
        .getMediaCollectionById(collectionId);
    if (collection == null) return null;
    final VideoMetadataWorkRow? work = await database
        .resolveVideoMetadataWorkForCollection(collectionId);
    return _build(
      workKey: 'collection:$collectionId',
      fallbackTitle: collection.name,
      work: work,
      videoPaths: await _videoPathsOf(await _memberBookUids(collectionId)),
    );
  }

  /// 库内一个视频（`video_books.book_uid`）。视频不存在、或拿不出库内作品键时
  /// 返回 null（见类注释）。
  Future<SubtitleWorkContext?> forBook(String bookUid) async {
    final VideoBookRow? book = await database.getVideoBookByBookUid(bookUid);
    if (book == null) return null;
    MediaCollectionRow? unscrapedCollection;
    for (final MediaCollectionRow collection in await _collectionsOf(bookUid)) {
      if (collection.collectionType == _kPlaylistCollectionType) continue;
      final VideoMetadataWorkRow? shared = await database
          .resolveVideoMetadataWorkForCollection(collection.id);
      if (shared != null) return forCollection(collection.id);
      unscrapedCollection ??= collection;
    }
    final VideoMetadataWorkRow? own = await database.getVideoMetadataWorkByBook(
      bookUid,
    );
    if (own != null) {
      return _build(
        workKey: 'work:${own.id}',
        fallbackTitle: book.title,
        work: own,
        videoPaths: <String>[book.videoPath],
      );
    }
    if (unscrapedCollection != null) {
      return forCollection(unscrapedCollection.id);
    }
    return null;
  }

  /// 按视频文件路径（与 `video_books.video_path` 逐字相等）找库内视频再走
  /// [forBook]；库里没有这个文件返回 null。同一路径多行（理论上不该有）取
  /// `book_uid` 最小的一行，结果确定。
  Future<SubtitleWorkContext?> forVideoPath(String videoPath) async {
    final VideoBookRow? book =
        await (database.select(database.videoBooks)
              ..where(($VideoBooksTable t) => t.videoPath.equals(videoPath))
              ..orderBy(<OrderClauseGenerator<$VideoBooksTable>>[
                ($VideoBooksTable t) => OrderingTerm.asc(t.bookUid),
              ])
              ..limit(1))
            .getSingleOrNull();
    if (book == null) return null;
    return forBook(book.bookUid);
  }

  Future<SubtitleWorkContext> _build({
    required String workKey,
    required String fallbackTitle,
    required VideoMetadataWorkRow? work,
    required List<String> videoPaths,
  }) async {
    final String? originalTitle = _nonEmpty(work?.originalTitle);
    return SubtitleWorkContext(
      workKey: workKey,
      title: _nonEmpty(work?.title) ?? fallbackTitle,
      originalTitle: originalTitle,
      kanjiTitle: await _anidbKanjiTitle(videoPaths),
      characters: work == null
          ? const <SubtitleWorkCharacter>[]
          : await _characters(work.id),
    );
  }

  /// 视频所在的合集（按成员行插入顺序；合集行已不存在的成员跳过）。
  Future<List<MediaCollectionRow>> _collectionsOf(String bookUid) async {
    final List<MediaCollectionItemRow> items =
        await (database.select(database.mediaCollectionItems)..where(
              ($MediaCollectionItemsTable t) =>
                  t.mediaType.equals(_kVideoMediaType) &
                  t.entryKey.equals(bookUid),
            ))
            .get();
    final List<MediaCollectionRow> out = <MediaCollectionRow>[];
    final Set<int> seen = <int>{};
    for (final MediaCollectionItemRow item in items) {
      if (!seen.add(item.collectionId)) continue;
      final MediaCollectionRow? row = await database.getMediaCollectionById(
        item.collectionId,
      );
      if (row != null) out.add(row);
    }
    return out;
  }

  Future<List<String>> _memberBookUids(int collectionId) async => <String>[
    for (final MediaCollectionItemRow item in await database.getCollectionItems(
      collectionId,
    ))
      if (item.mediaType == _kVideoMediaType) item.entryKey,
  ];

  Future<List<String>> _videoPathsOf(List<String> bookUids) async {
    final List<String> paths = <String>[];
    for (int i = 0; i < bookUids.length; i += _kInChunk) {
      final List<String> chunk = bookUids.sublist(
        i,
        i + _kInChunk > bookUids.length ? bookUids.length : i + _kInChunk,
      );
      final List<VideoBookRow> rows = await (database.select(
        database.videoBooks,
      )..where(($VideoBooksTable t) => t.bookUid.isIn(chunk))).get();
      for (final VideoBookRow row in rows) {
        if (row.videoPath.trim().isNotEmpty) paths.add(row.videoPath);
      }
    }
    return paths;
  }

  /// 这些文件里最近一次 AniDB 识别给出的作品汉字标题；都没有返回 null。
  Future<String?> _anidbKanjiTitle(List<String> videoPaths) async {
    ({String title, int updatedAt})? best;
    for (int i = 0; i < videoPaths.length; i += _kInChunk) {
      final List<String> chunk = videoPaths.sublist(
        i,
        i + _kInChunk > videoPaths.length ? videoPaths.length : i + _kInChunk,
      );
      final AnidbFileIdentityRow? row =
          await (database.select(database.anidbFileIdentities)
                ..where(
                  ($AnidbFileIdentitiesTable t) =>
                      t.filePath.isIn(chunk) & t.kanjiTitle.equals('').not(),
                )
                ..orderBy(<OrderClauseGenerator<$AnidbFileIdentitiesTable>>[
                  ($AnidbFileIdentitiesTable t) =>
                      OrderingTerm.desc(t.updatedAt),
                ])
                ..limit(1))
              .getSingleOrNull();
      if (row == null) continue;
      final String? title = _nonEmpty(row.kanjiTitle);
      if (title == null) continue;
      if (best == null || row.updatedAt > best.updatedAt) {
        best = (title: title, updatedAt: row.updatedAt);
      }
    }
    return best?.title;
  }

  /// 作品级演职员表里的角色（按 `sort_order`）：名字、日文原名、日语声优
  /// （人物日文名优先，否则显示名）。同一角色多条 credit（多位声优 / 多个 provider
  /// 的同名角色）只留一个，后面的条目只补前面缺的字段。
  Future<List<SubtitleWorkCharacter>> _characters(int workId) async {
    final List<VideoMetadataCreditRow> rows =
        List<VideoMetadataCreditRow>.of(
          await database.getVideoMetadataCredits(workId: workId),
        )..sort(
          (VideoMetadataCreditRow a, VideoMetadataCreditRow b) =>
              a.sortOrder.compareTo(b.sortOrder),
        );
    final Map<String, VideoMetadataCharacterRow?> characterRows =
        <String, VideoMetadataCharacterRow?>{};
    final Map<String, VideoMetadataPersonRow?> personRows =
        <String, VideoMetadataPersonRow?>{};
    final List<String> order = <String>[];
    final Map<String, _CharacterDraft> drafts = <String, _CharacterDraft>{};
    for (final VideoMetadataCreditRow row in rows) {
      final String? characterKey = row.characterKey;
      if (characterKey == null) continue;
      final VideoMetadataCharacterRow? character =
          characterRows.containsKey(characterKey)
          ? characterRows[characterKey]
          : characterRows[characterKey] = await database
                .getVideoMetadataCharacter(characterKey);
      if (character == null) continue;
      final String? name = _nonEmpty(character.name);
      if (name == null) continue;
      String? voiceActor;
      if (row.creditKind == _kVoiceActorCreditKind &&
          (row.language == null || row.language == 'ja')) {
        final VideoMetadataPersonRow? person =
            personRows.containsKey(row.personKey)
            ? personRows[row.personKey]
            : personRows[row.personKey] = await database.getVideoMetadataPerson(
                row.personKey,
              );
        voiceActor = _nonEmpty(person?.originalName) ?? _nonEmpty(person?.name);
      }
      final String identity = _nameIdentity(name);
      final _CharacterDraft? existing = drafts[identity];
      if (existing == null) {
        order.add(identity);
        drafts[identity] = _CharacterDraft(
          name: name,
          originalName: _nonEmpty(character.originalName),
          voiceActor: voiceActor,
        );
      } else {
        existing.originalName ??= _nonEmpty(character.originalName);
        existing.voiceActor ??= voiceActor;
      }
    }
    return <SubtitleWorkCharacter>[
      for (final String identity in order)
        SubtitleWorkCharacter(
          name: drafts[identity]!.name,
          originalName: drafts[identity]!.originalName,
          voiceActor: drafts[identity]!.voiceActor,
        ),
    ];
  }
}

class _CharacterDraft {
  _CharacterDraft({required this.name, this.originalName, this.voiceActor});

  final String name;
  String? originalName;
  String? voiceActor;
}

/// 同一角色在不同 provider 的写法（`Hirasawa, Yui` / `Hirasawa Yui`）归成同一个：
/// 去掉空白与标点、转小写。语序不同（`Yui Hirasawa`）不归并——宁可多一条也不误并。
/// 全是标点的名字归一后为空，退回原文，免得互不相干的角色并成一个。
String _nameIdentity(String name) {
  final String identity = name.toLowerCase().replaceAll(
    RegExp(r'[\s\p{P}]', unicode: true),
    '',
  );
  return identity.isEmpty ? name : identity;
}

String? _nonEmpty(String? value) {
  final String? trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}
