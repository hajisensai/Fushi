import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show JapaneseLanguage;

import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/metadata/book_art_store.dart';
import 'package:fushi/src/media/metadata/book_metadata_scrape_facade.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart'
    show fushiBooksProvider, srtBooksProvider;
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/ctl_book_metadata_routes.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';
import 'package:fushi/src/ops/op_descriptions_library.dart' show opUndoDisplay;

/// 书的元数据与封面刮削（写回从对话框抽出的门面）的操作描述（spec §4）。
///
/// 两条只读（搜候选、按 id 取详情）+ 一条写回。写回的撤销 = 执行前快照：显示名 /
/// 作者写回旧值，封面从门面留下的备份拷回（执行前没有 override 封面则清除）。撤销前
/// 再读一次，这次动过的字段之后被手动改过就报 superseded、不覆盖。
/// `source` 参数的值域（与 [BookScrapeSource] 的 wire 名一致，守卫测试咬住）。
const List<String> kBookScrapeSourceNames = <String>[
  'bangumi',
  'dlsite',
  'mangabaka',
  'anilist',
  'openbd',
  'ndl',
  'rakuten',
  'itunes',
];

List<OpDescription> describeBookMetadataOps(
  OpDescribeKit kit,
) => <OpDescription>[
  OpDescription(
    id: 'book.scrape.search',
    method: 'GET',
    pattern: kBookMetadataCtlSearch,
    summary:
        'Search online book metadata candidates. Sources: bangumi (books), '
        'dlsite (voice / manga / novel works), mangabaka (manga / light novel '
        'series), anilist (light novels, manga, manhwa and manhua; each candidate '
        'carries format; also returns a banner image), openbd '
        '(ISBN lookup only), ndl (National Diet Library, title or ISBN), '
        'rakuten (Rakuten Books, title or ISBN; only when the user entered '
        'Rakuten credentials in settings), itunes (songs on the Japanese '
        'iTunes store, album cover art; use it for audiobooks that are really '
        'songs with LRC lyrics). Returns id, title, author, year, '
        'publisher, series, ISBN and cover URL per candidate. A book title '
        'that finds nothing is retried as the series name (volume number '
        'removed, e.g. "第01巻" / "第1卷" / "第1集" / "1권"), then as the CJK or '
        'Latin half of a mixed title; the query that matched is returned as '
        'matchedQuery. MangaBaka data '
        'is CC BY-NC-SA 4.0: show "Data from MangaBaka" wherever it is '
        'displayed.',
    params: const <OpParam>[
      OpParam.string(
        'query',
        description:
            'Title, Bangumi subject URL, DLsite work id / URL, MangaBaka '
            'series URL / id, AniList URL, Apple Music URL, or ISBN (required '
            'for openbd).',
        required: true,
      ),
      OpParam.string(
        'source',
        description: 'Metadata source; default bangumi.',
        enumValues: kBookScrapeSourceNames,
      ),
      OpParam.boolean(
        'nsfw',
        description:
            'Include candidates the source marks as NSFW (adult). Default '
            'false: they are left out and only counted in hiddenNsfw. Pass '
            'true only when the book itself is marked NSFW.',
      ),
    ],
    availability: kit.whenModule(ModuleId.services),
  ),
  OpDescription(
    id: 'book.scrape.get',
    method: 'GET',
    pattern: '$kBookMetadataCtlSearch/:source/:id',
    summary: 'Fetch one book metadata candidate by its source id.',
    params: const <OpParam>[
      OpParam.string(
        'source',
        description: 'Metadata source.',
        required: true,
        inPath: true,
        enumValues: kBookScrapeSourceNames,
      ),
      OpParam.string(
        'id',
        description:
            'Bangumi subject id, DLsite work id (RJ…), MangaBaka series id, '
            'AniList media id, iTunes track / album id, or ISBN for openbd / '
            'ndl / rakuten.',
        required: true,
        inPath: true,
      ),
    ],
    availability: kit.whenModule(ModuleId.services),
  ),
  OpDescription(
    id: 'book.scrape.volumes',
    method: 'GET',
    pattern: '$kBookMetadataCtlSearch/:source/:id/volumes',
    summary:
        'List the per-volume covers of a MangaBaka series (one per '
        'volume: regular edition, safest rating, largest image) in the '
        'edition language given by `language` (default Japanese); when that '
        'language has none, Japanese covers are returned and `language` in '
        'the result says which edition was used. Show "Data from '
        'MangaBaka" with them.',
    risk: OpRisk.read,
    params: const <OpParam>[
      OpParam.string(
        'source',
        description: 'Only mangabaka.',
        required: true,
        inPath: true,
        enumValues: <String>['mangabaka'],
      ),
      OpParam.string(
        'language',
        description:
            'Edition language of the book (BCP 47, e.g. zh, zh-TW, ko); '
            'empty = Japanese.',
      ),
      OpParam.string(
        'id',
        description: 'MangaBaka series id.',
        required: true,
        inPath: true,
      ),
    ],
    availability: kit.whenModule(ModuleId.services),
  ),
  OpDescription(
    id: 'book.scrape.apply',
    method: 'POST',
    pattern: '$kBookMetadataCtlItems/:key/scrape',
    summary:
        'Write a chosen candidate back to a book on the shelf: its cover '
        'and scrape details (summary, date, rating, genres, landscape '
        'backdrop when the source has one) by default, and optionally its '
        'title (as a display-name override) and author. Same as "match '
        'cover online" on the book card.',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.string(
        'key',
        description: 'Shelf key from library.list, e.g. book:<bookKey>.',
        required: true,
        inPath: true,
      ),
      OpParam.string(
        'id',
        description: 'Candidate id from book.scrape.search.',
        required: true,
      ),
      OpParam.string(
        'source',
        description: 'Candidate source; default bangumi.',
        enumValues: kBookScrapeSourceNames,
      ),
      OpParam.stringList(
        'fields',
        description:
            'What to write back: cover, title, author, details. '
            'Default [cover, details].',
      ),
      OpParam.number(
        'volume',
        description:
            'MangaBaka only: use the Japanese cover of this volume '
            '(book.scrape.volumes) instead of the series cover.',
      ),
      OpParam.boolean(
        'onlyEmpty',
        description:
            'Only fill fields that are empty now: skip the title when a '
            'display-name override exists, the author when one is set, the '
            'cover when an override cover exists, and details when the book '
            'already has scrape details. Rejected when nothing is left to '
            'write.',
      ),
    ],
    availability: kit.whenModule(ModuleId.services),
    undo: _applyUndo(kit),
  ),
  OpDescription(
    id: 'book.art.scrape',
    method: 'POST',
    pattern: '$kBookArtCtlCollections/:id/scrape-art',
    summary:
        'Fetch per-volume covers and a banner for the local books of a '
        'collection: MangaBaka first (sharpest image wins), Bangumi '
        'tankobon covers as fallback; banner from MangaBaka, else from '
        'AniList (by the AniList id MangaBaka links, or the one AniList entry '
        'with the exact same title and kind); only replaces a volume when '
        'the new image is sharper than the embedded cover. Stored apart from the '
        'user\'s own cover override. Series with no confident match come '
        'back as needsConfirm with options; call again with seriesKey + '
        'source + seriesId to use one (remembered for later runs). Never '
        'replaces an already fetched cover of the same series with a smaller '
        'one. dryRun returns the same plan without '
        'downloading or writing. Show "Data from MangaBaka" when any '
        'image comes from MangaBaka.',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.string(
        'id',
        description: 'Collection id (collection.list).',
        required: true,
        inPath: true,
      ),
      OpParam.boolean(
        'dryRun',
        description: 'Plan only: no download, no write. Default false.',
      ),
      OpParam.string(
        'seriesKey',
        description:
            'With source + seriesId: pin this series group (from a '
            'previous result).',
      ),
      OpParam.string(
        'source',
        description: 'Pinned series source.',
        enumValues: <String>['mangabaka', 'bangumi'],
      ),
      OpParam.string('seriesId', description: 'Pinned series id.'),
    ],
    availability: kit.whenModule(ModuleId.services),
    undo: _artUndo(kit),
  ),
  OpDescription(
    id: 'book.art.clear',
    method: 'DELETE',
    pattern: '$kBookArtCtlCollections/:id/scrape-art',
    summary:
        'Remove the fetched per-volume covers (and banners no book uses '
        'any more) from every local book of a collection, including series '
        'the user pinned earlier. The user\'s own cover overrides are '
        'untouched. Works offline (no online-services gate).',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.string(
        'id',
        description: 'Collection id.',
        required: true,
        inPath: true,
      ),
    ],
    undo: _artUndo(kit),
  ),
  OpDescription(
    id: 'book.art.remove',
    method: 'DELETE',
    pattern: '$kBookMetadataCtlItems/:key/scraped-art',
    summary:
        'Remove the fetched cover of one book (book:<bookKey>), e.g. when '
        'it is the wrong volume. The removed image is remembered as rejected '
        'so a later book.art.scrape will not write it back. Its own cover '
        'override is untouched. Works offline (no online-services gate).',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.string(
        'key',
        description: 'Shelf key, book:<bookKey>.',
        required: true,
        inPath: true,
      ),
    ],
    undo: _artUndo(kit),
  ),
];

/// 刮削层写入 / 清除的撤销：载荷 = 结果里的 `undo`（执行前快照 + 执行后指纹）。撤销
/// 时任何一本的刮削层已不等于执行后状态 → superseded，不覆盖之后的改动。
OpUndo _artUndo(OpDescribeKit kit) => opCustomUndo(
  payloadOf: (CtlCall call, Map<String, Object?> before, Object? result) {
    final Map<Object?, Object?> r = result is Map ? result : const {};
    final Map<Object?, Object?> undo = r['undo'] is Map
        ? r['undo'] as Map<Object?, Object?>
        : const {};
    return <String, Object?>{
      'target': call.params['id'] ?? call.params['key'],
      'snapshots': undo['snapshots'] ?? const <Object?>[],
      'after': undo['after'] ?? const <String, Object?>{},
    };
  },
  describe: (Map<String, Object?> payload) => opUndoDisplay(<String, Object?>{
    'target': payload['target'],
    'books': (payload['snapshots'] as List?)?.length ?? 0,
  }),
  revert: (Map<String, Object?> payload) async {
    final BookArtStore store = BookArtStore.of(
      kit.context.appModel.thumbnailsDirectory,
    );
    final List<BookArtSnapshot> snapshots = <BookArtSnapshot>[
      for (final Object? s
          in payload['snapshots'] as List? ?? const <Object?>[])
        if (s is Map) BookArtSnapshot.fromJson(Map<String, Object?>.from(s)),
    ];
    final Map<Object?, Object?> after = payload['after'] is Map
        ? payload['after'] as Map<Object?, Object?>
        : const {};
    for (final BookArtSnapshot s in snapshots) {
      if (!OpDescribeKit.sameJson(
        await store.fingerprint(s.bookKey),
        after[s.bookKey],
      )) {
        return const OpUndoOutcome.superseded();
      }
    }
    // 先逐本确认备份都在，再动手：不留「恢复了一半」的状态。
    if (snapshots.any((BookArtSnapshot s) => !store.canRestore(s))) {
      return OpUndoOutcome.failed(
        '封面备份已不在（超过 ${BookArtStore.backupRetention.inDays} 天会被清理）',
      );
    }
    try {
      for (final BookArtSnapshot s in snapshots.reversed) {
        await store.restore(s);
      }
    } on StateError catch (e) {
      return OpUndoOutcome.failed(e.message);
    }
    // 撤销一次刮削后，那次新写的横幅已无人引用：当场回收，不留到下一次删除。
    await store.collectOrphanBanners();
    kit.context.ref
      ..invalidate(fushiBooksProvider(JapaneseLanguage.instance))
      ..invalidate(srtBooksProvider);
    return const OpUndoOutcome.done();
  },
);

/// 写回的撤销：载荷 = 条目键 + 真落盘的字段 + 执行前快照（含封面备份路径）+ 执行后
/// 状态。撤销时当前状态（只看动过的字段）已不等于执行后状态 → superseded。
OpUndo _applyUndo(OpDescribeKit kit) => opCustomUndo(
  payloadOf: (CtlCall call, Map<String, Object?> before, Object? result) {
    final Map<Object?, Object?> r = result is Map ? result : const {};
    return <String, Object?>{
      'key': call.params['key'],
      'fields': opUndoStrings(r['applied']),
      'before': r['before'],
      'after': r['after'],
    };
  },
  describe: (Map<String, Object?> payload) => opUndoDisplay(<String, Object?>{
    'key': payload['key'],
    'fields': payload['fields'],
  }),
  revert: (Map<String, Object?> payload) async {
    final Set<BookMetadataField> fields = <BookMetadataField>{
      for (final String f in opUndoStrings(payload['fields']))
        ?BookMetadataField.tryParse(f),
    };
    if (fields.isEmpty) return const OpUndoOutcome.done();
    final BookMetadataSnapshot snapshot = BookMetadataSnapshot.fromJson(
      Map<String, Object?>.from(payload['before'] as Map? ?? const {}),
    );
    final BookMetadataState after = BookMetadataState.fromJson(
      Map<String, Object?>.from(payload['after'] as Map? ?? const {}),
    );
    final MediaItem item = await resolveBookMetadataItem(
      kit.context.appModel,
      '${payload['key']}',
    );
    final BookMetadataScrapeFacade facade = BookMetadataScrapeFacade();
    final BookMetadataState now = await facade.currentState(
      appModel: kit.context.appModel,
      item: item,
    );
    if (!OpDescribeKit.sameJson(now.project(fields), after.project(fields))) {
      return const OpUndoOutcome.superseded();
    }
    try {
      await facade.restore(
        appModel: kit.context.appModel,
        item: item,
        snapshot: snapshot,
        fields: fields,
      );
    } on StateError catch (e) {
      return OpUndoOutcome.failed(e.message);
    }
    kit.context.ref
      ..invalidate(fushiBooksProvider(JapaneseLanguage.instance))
      ..invalidate(srtBooksProvider);
    return const OpUndoOutcome.done();
  },
);
