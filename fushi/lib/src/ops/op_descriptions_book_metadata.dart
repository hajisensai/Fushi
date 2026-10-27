import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show JapaneseLanguage;

import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/metadata/book_metadata_scrape_facade.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart'
    show fushiBooksProvider, srtBooksProvider;
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/ctl_book_metadata_routes.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';
import 'package:fushi/src/ops/op_descriptions_library.dart'
    show opCustomUndo, opUndoDisplay, opUndoStrings;

/// 书的元数据与封面刮削（写回从对话框抽出的门面）的操作描述（spec §4）。
///
/// 两条只读（搜候选、按 id 取详情）+ 一条写回。写回的撤销 = 执行前快照：显示名 /
/// 作者写回旧值，封面从门面留下的备份拷回（执行前没有 override 封面则清除）。撤销前
/// 再读一次，这次动过的字段之后被手动改过就报 superseded、不覆盖。
List<OpDescription> describeBookMetadataOps(OpDescribeKit kit) =>
    <OpDescription>[
      OpDescription(
        id: 'book.scrape.search',
        method: 'GET',
        pattern: kBookMetadataCtlSearch,
        summary:
            'Search online book metadata candidates (Bangumi books, or DLsite '
            'voice / manga / novel works) by title, Bangumi URL or DLsite id. '
            'Returns id, title, author, year and cover URL per candidate.',
        params: const <OpParam>[
          OpParam.string(
            'query',
            description: 'Title, Bangumi subject URL, or DLsite work id / URL.',
            required: true,
          ),
          OpParam.string(
            'source',
            description: 'Metadata source; default bangumi.',
            enumValues: <String>['bangumi', 'dlsite'],
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
            description: 'bangumi or dlsite.',
            required: true,
            inPath: true,
            enumValues: <String>['bangumi', 'dlsite'],
          ),
          OpParam.string(
            'id',
            description: 'Bangumi subject id or DLsite work id (RJ…).',
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
            '(default), and optionally its title (as a display-name override) '
            'and author. Same as "match cover online" on the book card.',
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
            enumValues: <String>['bangumi', 'dlsite'],
          ),
          OpParam.stringList(
            'fields',
            description:
                'What to write back: cover, title, author. Default [cover].',
          ),
        ],
        availability: kit.whenModule(ModuleId.services),
        undo: _applyUndo(kit),
      ),
    ];

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
