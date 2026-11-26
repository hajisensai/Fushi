/// 视频库行 → 打开时自动挑字幕的目标语言（读库的那一半）。
///
/// 纯判据在 `subtitle_language_target.dart`（[resolveSubtitleLanguageTarget]）；这里只
/// 负责从库里取出那条链要的证据，让本机播放页与互联 host（`LocalLibraryHostService`，
/// app 与 fushi_server 两种装配）用同一份：
///
/// * 系列字幕语言：视频所在合集的 `MediaCollections.subtitleLanguage`（「为整个合集配
///   字幕」面板里设的，列注释写明「非 NULL 时覆盖合集内每一集的字幕语言选择」）；
///   打开时所在的合集（`preferredCollectionId`）优先，其余按主合集（id 小）在前。
/// * 本视频语言：`VideoBooks.language`（用户手动指定）。
/// * 刮削原语言：本视频自己的作品行，没有再找所在合集的作品行。
///
/// 证据一次批量读成 [VideoSubtitleLanguageEvidence]：`media_collection_items` 没有
/// 按条目的索引，逐行查在列表端点（几百个视频）里会退化成几百次全表扫；只开一个视频
/// 时 [VideoSubtitleLanguageEvidence.load] 带 `bookUid` 收窄成只读这一条。
library;

import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi_engine/media/video/subtitle/subtitle_language_target.dart';

/// 挑字幕语言要的库内证据（系列字幕语言 + 刮削原语言），按 bookUid 索引。
final class VideoSubtitleLanguageEvidence {
  VideoSubtitleLanguageEvidence._(
    this._seriesLanguages,
    this._bookOriginalLanguages,
    this._collectionOriginalLanguages,
  );

  /// bookUid → 它所在、且设了系列字幕语言的合集（按合集 id 升序）。
  final Map<String, List<({int collectionId, String language})>>
  _seriesLanguages;

  /// bookUid → 挂在这一集上的作品行的原语言。
  final Map<String, String> _bookOriginalLanguages;

  /// bookUid → 它所在合集的作品行原语言（按合集 id 升序）。
  final Map<String, List<({int collectionId, String language})>>
  _collectionOriginalLanguages;

  /// 读证据。[bookUid] 非 null 时只读这一个视频的（播放页开一集）；null = 全库
  /// （互联列表端点一次读完再逐行 [targetFor]）。
  static Future<VideoSubtitleLanguageEvidence> load(
    FushiDatabase db, {
    String? bookUid,
  }) async {
    final List<Variable<Object>> args = <Variable<Object>>[
      if (bookUid != null) Variable<String>(bookUid),
    ];
    final List<QueryRow> series = await db
        .customSelect(
          'SELECT i.entry_key, c.id AS collection_id, c.subtitle_language '
          'FROM media_collection_items i '
          'JOIN media_collections c ON c.id = i.collection_id '
          "WHERE i.media_type = 'video' "
          "AND c.subtitle_language IS NOT NULL AND c.subtitle_language != '' "
          '${bookUid == null ? '' : 'AND i.entry_key = ? '}'
          'ORDER BY c.id',
          variables: args,
        )
        .get();
    final List<QueryRow> bookWorks = await db
        .customSelect(
          'SELECT book_uid, original_language FROM video_metadata_works '
          'WHERE book_uid IS NOT NULL '
          "AND original_language IS NOT NULL AND original_language != '' "
          '${bookUid == null ? '' : 'AND book_uid = ? '}',
          variables: args,
        )
        .get();
    final List<QueryRow> collectionWorks = await db
        .customSelect(
          'SELECT i.entry_key, w.collection_id, w.original_language '
          'FROM media_collection_items i '
          'JOIN video_metadata_works w ON w.collection_id = i.collection_id '
          "WHERE i.media_type = 'video' "
          "AND w.original_language IS NOT NULL AND w.original_language != '' "
          '${bookUid == null ? '' : 'AND i.entry_key = ? '}'
          'ORDER BY w.collection_id',
          variables: args,
        )
        .get();
    final Map<String, List<({int collectionId, String language})>> byBook =
        <String, List<({int collectionId, String language})>>{};
    for (final QueryRow r in series) {
      (byBook[r.read<String>('entry_key')] ??=
              <({int collectionId, String language})>[])
          .add((
            collectionId: r.read<int>('collection_id'),
            language: r.read<String>('subtitle_language'),
          ));
    }
    final Map<String, List<({int collectionId, String language})>>
    collectionOriginal =
        <String, List<({int collectionId, String language})>>{};
    for (final QueryRow r in collectionWorks) {
      (collectionOriginal[r.read<String>('entry_key')] ??=
              <({int collectionId, String language})>[])
          .add((
            collectionId: r.read<int>('collection_id'),
            language: r.read<String>('original_language'),
          ));
    }
    return VideoSubtitleLanguageEvidence._(byBook, <String, String>{
      for (final QueryRow r in bookWorks)
        r.read<String>('book_uid'): r.read<String>('original_language'),
    }, collectionOriginal);
  }

  /// [row] 的字幕目标语言；链上全空返回 null（不猜）。
  ///
  /// [explicitSubtitlePreference] 是全局的显式字幕语言（app：字幕工作台默认语言；
  /// fushi_server：配置里的 `subtitleLanguage`），排在系列字幕语言之后；
  /// [globalDefaultContentLanguage] 是全局默认内容语言；[preferredCollectionId] 是
  /// 这一集此刻作为哪个合集的一集打开（优先用那个合集的设置）。
  SubtitleLanguageTarget? targetFor(
    VideoBookRow row, {
    String? explicitSubtitlePreference,
    String? globalDefaultContentLanguage,
    int? preferredCollectionId,
  }) {
    String? pick(List<({int collectionId, String language})>? entries) {
      if (entries == null || entries.isEmpty) return null;
      for (final ({int collectionId, String language}) e in entries) {
        if (e.collectionId == preferredCollectionId) return e.language;
      }
      return entries.first.language;
    }

    return resolveSubtitleLanguageTarget(
      explicitSubtitlePreference:
          pick(_seriesLanguages[row.bookUid]) ?? explicitSubtitlePreference,
      videoContentLanguage: row.language,
      contentMetadataLanguage:
          _bookOriginalLanguages[row.bookUid] ??
          pick(_collectionOriginalLanguages[row.bookUid]),
      globalDefaultContentLanguage: globalDefaultContentLanguage,
    );
  }
}

/// 单个视频的目标语言：[VideoSubtitleLanguageEvidence.load] 收窄到 [row] 再
/// [VideoSubtitleLanguageEvidence.targetFor]。
Future<SubtitleLanguageTarget?> resolveVideoSubtitleLanguageTarget(
  FushiDatabase db,
  VideoBookRow row, {
  String? explicitSubtitlePreference,
  String? globalDefaultContentLanguage,
  int? preferredCollectionId,
}) async => (await VideoSubtitleLanguageEvidence.load(db, bookUid: row.bookUid))
    .targetFor(
      row,
      explicitSubtitlePreference: explicitSubtitlePreference,
      globalDefaultContentLanguage: globalDefaultContentLanguage,
      preferredCollectionId: preferredCollectionId,
    );
