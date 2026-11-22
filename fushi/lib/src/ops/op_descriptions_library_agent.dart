import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/media/library_agent/library_changeset.dart';

import 'package:fushi/src/ops/ctl_library_agent_routes.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';
import 'package:fushi/src/ops/op_descriptions_library.dart' show opUndoDisplay;

/// AI 管库 v3 的操作描述（spec `docs/specs/2026-11-22-ai-library-agent-design.md`
/// §3.2 / §3.3；路由见 `ctl_library_agent_routes.dart`）。
///
/// `library.changes.apply` 的撤销 = 这份变更集整体撤销：合集部分按整理记录倒序撤回，
/// 关系部分按写入回执退回；用户之后改过的那一处保留（superseded / partial）。
List<OpDescription> describeLibraryAgentOps(
  OpDescribeKit kit,
) => <OpDescription>[
  const OpDescription(
    id: 'library.map',
    method: 'GET',
    pattern: '$kLibraryAgentCtlRoot/map',
    summary:
        'Whole-library map for reorganizing, compact and paged. '
        'view=summary: counts per library page, loose items, collections '
        'by origin, relation links by state, works. view=books|manga|'
        'video|games: collections (ref C<id>, name, origin user|rule|ai|'
        'folder, members, pinned members the AI must not move) and items '
        '(ref <mediaType>:<entryKey>, title, creator, year, video folder, '
        'collections, relation endpoint ref). view=links: works (connected '
        'components of the relation graph) and every edge (from, to, '
        'relation, state user|ai|suggested, source). Columnar rows; use q '
        'to filter by title and offset / nextOffset to page.',
    params: <OpParam>[
      OpParam.string(
        'view',
        description: 'summary (default), books, manga, video, games, links.',
        enumValues: <String>[
          'summary',
          'books',
          'manga',
          'video',
          'games',
          'links',
        ],
      ),
      OpParam.string(
        'q',
        description:
            'Title filter (folded: kana / width / case-insensitive). A '
            'matching collection brings all its members.',
      ),
      OpParam.integer(
        'addedSince',
        description:
            'Library pages only: just items added after this time (epoch ms) '
            'plus every member of the collections they are in.',
      ),
      OpParam.integer('offset', description: 'Row offset (nextOffset).'),
      OpParam.integer('limit', description: 'Rows per page (default 400).'),
    ],
  ),
  OpDescription(
    id: 'library.changes.apply',
    method: 'POST',
    pattern: '$kLibraryAgentCtlRoot/changes',
    summary:
        'Apply a batch of library reorganization changes in one call, as '
        'the AI (user-owned collections may be changed; members the user '
        'pinned, folder collections and user-confirmed links are kept). '
        'Each change is checked on its own; rejected ones come back in '
        'skipped with a reason, the rest are applied. Ops: '
        'move {items, to: C<id> | "new:<name>" | "standalone", from?}, '
        'merge {into, from: [C<id>]}, rename {collection, name}, '
        'dissolve {collection}, link {from, to, relation}, '
        'unlink {from, to, relation?}, relink {from, to, relation} '
        '(change type / direction of an AI or suggested link). Relations: '
        'same_work, adaptation (original -> adaptation), sequel (earlier '
        '-> later), side_story (main -> side story), theme_song / '
        'soundtrack (between a work and a music album / track, either '
        'order), cast (work -> person). Give every '
        'change a short why. Undo reverts the whole batch.',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.objectList(
        'changes',
        description:
            'Changes, each {op, why, ...op fields}; refs from library.map.',
        required: true,
      ),
      OpParam.boolean(
        'dryRun',
        description: 'Only validate and report what would happen.',
      ),
    ],
    undo: opCustomUndo(
      payloadOf: (CtlCall call, Map<String, Object?> before, Object? result) =>
          <String, Object?>{
            'undo': result is Map ? result['undo'] : null,
            'applied': result is Map && result['applied'] is List
                ? (result['applied'] as List<Object?>).length
                : 0,
          },
      describe: (Map<String, Object?> p) =>
          opUndoDisplay('${p['applied'] ?? 0} library change(s)'),
      revert: (Map<String, Object?> payload) async {
        final Object? undo = payload['undo'];
        if (undo is! Map) return const OpUndoOutcome.done();
        final int undone = await undoLibraryChangeset(
          kit.context.appModel.database,
          Map<String, Object?>.from(undo),
        );
        final int applied = (payload['applied'] as num? ?? 0).toInt();
        // 回执粒度（一条整理记录可含多个成员）与 applied 条数不一一对应，只区分
        // 「一处都没撤成」与「撤了」。
        if (undone == 0 && applied > 0) {
          return const OpUndoOutcome.superseded('这些改动都已被后续修改覆盖');
        }
        return const OpUndoOutcome.done();
      },
    ),
  ),
];
