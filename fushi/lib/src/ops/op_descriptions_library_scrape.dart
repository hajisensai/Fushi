import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/ops/ctl_library_scrape_routes.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';
import 'package:fushi/src/ops/op_descriptions_library.dart' show opUndoDisplay;

/// 单本书 / 漫画 / 字幕书 / 游戏刮削资料（v155）的操作描述。`set` 可撤销（执行前
/// 快照：资料写回旧值、执行前没有的图清掉）；`clear` 会删图片文件，标不可撤销。
List<OpDescription> describeLibraryScrapeOps(
  OpDescribeKit kit,
) => <OpDescription>[
  const OpDescription(
    id: 'library.item.scrape-meta.get',
    method: 'GET',
    pattern: '$kLibraryScrapeCtlItems/:key/scrape-meta',
    summary:
        'Read the scrape details (summary, date, rating, genres) and landscape '
        'backdrop / logo of a book, manga, audiobook or game.',
    params: <OpParam>[_keyParam],
  ),
  OpDescription(
    id: 'library.item.scrape-meta.set',
    method: 'PUT',
    pattern: '$kLibraryScrapeCtlItems/:key/scrape-meta',
    summary:
        'Set scrape details and/or a landscape backdrop / logo for a book, '
        'manga, audiobook or game (drives the series block on the shelf and '
        'game library). Fields not given are kept unless replace=true.',
    risk: OpRisk.write,
    // backdropUrl / logoUrl 会让 app 去请求模型给的地址：先让用户确认（spec §5.2）。
    confirm: true,
    params: const <OpParam>[
      _keyParam,
      OpParam.string('summary', description: 'Synopsis text.'),
      OpParam.string('title', description: 'Scraped title (fact only).'),
      OpParam.string('originalTitle', description: 'Original title.'),
      OpParam.string('date', description: 'YYYY, YYYY-MM or YYYY-MM-DD.'),
      OpParam.integer('year', description: 'Release year (if no date).'),
      OpParam.number('rating', description: 'Rating 0-10.'),
      OpParam.integer('ratingCount', description: 'Number of ratings.'),
      OpParam.stringList('genres', description: 'Genre / tag names.'),
      OpParam.string('detailUrl', description: 'Source page URL.'),
      OpParam.string('source', description: 'Source name; default manual.'),
      OpParam.string('subjectId', description: 'Id within the source.'),
      OpParam.string(
        'backdropPath',
        description: 'Absolute local image for the landscape backdrop.',
      ),
      OpParam.string(
        'backdropUrl',
        description: 'http(s) image URL for the landscape backdrop.',
      ),
      OpParam.string('logoPath', description: 'Absolute local logo image.'),
      OpParam.string('logoUrl', description: 'http(s) logo image URL.'),
      OpParam.boolean(
        'replace',
        description: 'Replace the whole details row instead of merging.',
      ),
    ],
    undo: opCustomUndo(
      capture: (CtlCall call) async => itemScrapeStateJson(
        kit.context.appModel.database,
        call.params['key']!,
        await resolveLibraryItemScrapeKey(
          kit.context.appModel,
          call.params['key']!,
        ),
      ),
      payloadOf: (CtlCall call, Map<String, Object?> before, Object? _) =>
          <String, Object?>{'key': call.params['key'], 'before': before},
      describe: (Map<String, Object?> payload) =>
          opUndoDisplay(<String, Object?>{'key': payload['key']}),
      revert: (Map<String, Object?> payload) async {
        await restoreItemScrapeState(
          kit.context.appModel,
          '${payload['key']}',
          Map<String, Object?>.from(payload['before'] as Map? ?? const {}),
        );
        return const OpUndoOutcome.done();
      },
    ),
  ),
  const OpDescription(
    id: 'library.item.scrape-meta.clear',
    method: 'DELETE',
    pattern: '$kLibraryScrapeCtlItems/:key/scrape-meta',
    summary:
        'Remove the scrape details and backdrop / logo images of a book, '
        'manga, audiobook or game (the image files are deleted).',
    risk: OpRisk.irreversible,
    params: <OpParam>[_keyParam],
  ),
];

const OpParam _keyParam = OpParam.string(
  'key',
  description: 'Library key from library.list: book:, srt: or game:.',
  required: true,
  inPath: true,
);
