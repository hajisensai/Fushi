import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/library_curate/library_curate_link_ops.dart';
import 'package:fushi/src/ops/ctl_library_curate_routes.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';
import 'package:fushi/src/ops/op_descriptions_library.dart' show opUndoDisplay;

/// AI 库管家的操作描述（spec `docs/specs/2026-11-18-ai-library-curator-design.md`
/// §3 / §9；路由见 `ctl_library_curate_routes.dart`）。
///
/// - `library.curate.run` 的撤销 = 整趟撤销（按 `curator:<runId>` 会话倒序撤这一趟
///   经目录落下的每一处写入）；
/// - 两条 ④ 步操作的撤销按结果里的写入回执：生效连接退回写入前的行，建议删掉；
///   用户之后确认 / 否决过的保留（superseded）。
List<OpDescription> describeLibraryCurateOps(OpDescribeKit kit) {
  FushiDatabase db() => kit.context.appModel.database;

  OpUndo linkWritesUndo() => opCustomUndo(
    payloadOf: (CtlCall call, Map<String, Object?> before, Object? result) =>
        <String, Object?>{
          'writes': result is Map ? result['writes'] : const <Object?>[],
        },
    describe: (Map<String, Object?> p) => opUndoDisplay(
      '${(p['writes'] as List? ?? const <Object?>[]).length} link(s)',
    ),
    revert: (Map<String, Object?> payload) async {
      final List<LibraryCurateLinkWrite> writes = <LibraryCurateLinkWrite>[
        for (final Object? raw
            in payload['writes'] as List? ?? const <Object?>[])
          ?libraryCurateLinkWriteFromJson(raw),
      ];
      if (writes.isEmpty) return const OpUndoOutcome.done();
      final int reverted = await revertLibraryCurateLinkWrites(db(), writes);
      if (reverted == 0) {
        return const OpUndoOutcome.superseded('这些连接都已被处理过');
      }
      return reverted < writes.length
          ? OpUndoOutcome.partial('已撤回 $reverted 条，其余已被处理过，保留')
          : const OpUndoOutcome.done();
    },
  );

  const OpParam trigger = OpParam.string(
    'trigger',
    description:
        'manual (default: medium-confidence verdicts apply) or auto (only '
        'high-confidence links apply; the rest become suggestions).',
    enumValues: <String>['manual', 'auto'],
  );

  return <OpDescription>[
    OpDescription(
      id: 'library.curate.run',
      method: 'POST',
      pattern: kLibraryCurateCtlRoot,
      summary:
          'Run the AI library curator once over the whole library: organize '
          'collection membership on every library page, identify unscraped '
          'video works, books / manga missing metadata (fills only empty '
          'cover / author / file-name title) and games without any metadata '
          'source (single strong match or LLM pick among candidates), '
          'infer cross-media relations (novel / manga / anime / game / music) '
          'and refresh the work layer. Only items added since the last run '
          'unless full=true. Each step uses its own LLM assignment and is '
          'skipped when none is assigned. Undo reverts every write of the run. '
          'Slow; check library.curate.estimate first for the request count.',
      risk: OpRisk.write,
      params: const <OpParam>[
        OpParam.boolean(
          'full',
          description: 'Ignore the watermark and go through the whole library.',
        ),
        OpParam.boolean(
          'wait',
          description:
              'false = start in the background and return the run id at once '
              '(poll library.curate.status).',
        ),
        OpParam.userGate(
          'yes',
          description:
              'User agreed to send library metadata to the AI providers.',
        ),
      ],
      undo: opCustomUndo(
        payloadOf:
            (
              CtlCall call,
              Map<String, Object?> before,
              Object? result,
            ) => <String, Object?>{
              'runId': result is Map ? result['id'] ?? result['runId'] : null,
            },
        describe: (Map<String, Object?> p) => 'curator run ${p['runId']}',
        revert: (Map<String, Object?> payload) async {
          final Object? runId = payload['runId'];
          if (runId == null) return const OpUndoOutcome.done();
          final Object? r = await kit.callRoute(
            'POST',
            '$kLibraryCurateCtlRoot/runs/:id/undo',
            params: <String, String>{'id': '$runId'},
          );
          final Map<Object?, Object?> m = r is Map ? r : const {};
          if ((m['failed'] as num? ?? 0) > 0) {
            return OpUndoOutcome.partial('${m['failed']} 处撤销失败');
          }
          if ((m['undone'] as num? ?? 0) == 0) {
            return const OpUndoOutcome.superseded('这一趟没有可撤销的了');
          }
          return const OpUndoOutcome.done();
        },
      ),
    ),
    const OpDescription(
      id: 'library.curate.estimate',
      method: 'GET',
      pattern: '$kLibraryCurateCtlRoot/estimate',
      summary:
          'Estimate one curator run: items per step and roughly how many LLM '
          'requests it would send (steps without an assigned LLM count 0).',
      params: <OpParam>[
        OpParam.boolean('full', description: 'Estimate a whole-library run.'),
      ],
    ),
    const OpDescription(
      id: 'library.curate.status',
      method: 'GET',
      pattern: '$kLibraryCurateCtlRoot/status',
      summary:
          'Whether the curator is running (current step) and the last run '
          'with per-step results.',
    ),
    const OpDescription(
      id: 'library.curate.runs',
      method: 'GET',
      pattern: '$kLibraryCurateCtlRoot/runs',
      summary:
          'Past curator runs on this device: per-step status, changes, items '
          'left for the user, LLM requests, undo state.',
      params: <OpParam>[
        OpParam.integer('limit', description: 'Max runs (1-200, default 20).'),
      ],
    ),
    const OpDescription(
      id: 'library.curate.undo',
      method: 'POST',
      pattern: '$kLibraryCurateCtlRoot/runs/:id/undo',
      summary:
          'Undo a whole curator run (newest write first). Parts the user '
          'changed afterwards are kept. Cannot be redone.',
      risk: OpRisk.irreversible,
      params: <OpParam>[
        OpParam.string(
          'id',
          description: 'Run id from library.curate.runs.',
          required: true,
          inPath: true,
        ),
      ],
    ),
    OpDescription(
      id: 'library.curate.scrape.retry',
      method: 'POST',
      pattern: '$kLibraryCurateCtlRoot/scrape/retry',
      summary:
          'Retry identifying ONE book / manga or game the curator left '
          'unidentified (book_scrape_pending / game_scrape_pending in '
          'library.curate.pending): search its metadata sources again and let '
          'the LLM pick among candidates; writes only when confident. Recorded '
          'as a curator run (undo reverts it); does not move the watermark.',
      risk: OpRisk.write,
      params: const <OpParam>[
        OpParam.string(
          'stage',
          description: 'books (books and manga) or games.',
          required: true,
          enumValues: <String>['books', 'games'],
        ),
        OpParam.string(
          'ref',
          description:
              'Item key: collection:<id> / book:<bookKey> for books, '
              'game:<id> for games (the ref of the pending item).',
          required: true,
        ),
        OpParam.userGate(
          'yes',
          description:
              'User agreed to send library metadata to the AI providers.',
        ),
      ],
      undo: opCustomUndo(
        payloadOf:
            (CtlCall call, Map<String, Object?> before, Object? result) =>
                <String, Object?>{'runId': result is Map ? result['id'] : null},
        describe: (Map<String, Object?> p) => 'curator retry ${p['runId']}',
        revert: (Map<String, Object?> payload) async {
          final Object? runId = payload['runId'];
          if (runId == null) return const OpUndoOutcome.done();
          final Object? r = await kit.callRoute(
            'POST',
            '$kLibraryCurateCtlRoot/runs/:id/undo',
            params: <String, String>{'id': '$runId'},
          );
          final Map<Object?, Object?> m = r is Map ? r : const {};
          if ((m['failed'] as num? ?? 0) > 0) {
            return OpUndoOutcome.partial('${m['failed']} 处撤销失败');
          }
          if ((m['undone'] as num? ?? 0) == 0) {
            return const OpUndoOutcome.superseded('这一趟没有可撤销的了');
          }
          return const OpUndoOutcome.done();
        },
      ),
    ),
    const OpDescription(
      id: 'library.curate.pending',
      method: 'GET',
      pattern: '$kLibraryCurateCtlRoot/pending',
      summary:
          'What the curator left for the user: collection merge / rename '
          'suggestions (library.organize.proposal.accept / reject), video '
          'works it could not identify, steps that need confirmation.',
    ),
    OpDescription(
      id: 'library.curate.links.infer',
      method: 'POST',
      pattern: '$kLibraryCurateCtlRoot/links/infer',
      summary:
          'Infer related works for a batch of items (shared external ids, MAL '
          'source material, title match, LLM verdict when "media links" has an '
          'LLM). A link that would fuse two existing works is only suggested '
          'on the auto path. Undo removes what this call wrote.',
      risk: OpRisk.write,
      params: const <OpParam>[
        OpParam.stringList(
          'items',
          description: 'Items as <kind>:<key> (from links.candidates), max 50.',
          required: true,
        ),
        trigger,
      ],
      undo: linkWritesUndo(),
    ),
    OpDescription(
      id: 'library.curate.links.music',
      method: 'POST',
      pattern: '$kLibraryCurateCtlRoot/links/music',
      summary:
          'Link music albums / tracks to the anime or game they belong to, '
          'across the whole music library (audio-fingerprint hits apply '
          'directly; album / track titles naming a work go to the "media '
          'links" LLM or become suggestions). Local data only. Undo removes '
          'what this call wrote.',
      risk: OpRisk.write,
      params: const <OpParam>[
        trigger,
        OpParam.boolean(
          'useAi',
          description: 'false = no LLM verdicts (fingerprint / rules only).',
        ),
      ],
      undo: linkWritesUndo(),
    ),
  ];
}
