import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/ops/ctl_media_links_routes.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';
import 'package:fushi/src/ops/op_descriptions_library.dart'
    show opCustomUndo, opUndoDisplay, opUndoStrings;

/// 作品图谱（跨媒体关联建议的接受 / 拒绝）与人物的操作描述（spec §4）。
///
/// 撤销一律走数据层的**对称方法**，不删用户数据：
/// - 接受建议 → `unconfirmMediaLink` 退回建议；
/// - 「不相关」→ `restoreMediaLinkSuggestion` 清墓碑恢复成建议；
/// - 查找相关作品 → `discardMediaLinkSuggestion` 删掉这轮刚写入、用户还没处理过的
///   建议（不写墓碑：撤销推断不是否决，下次推断仍可再提）；
/// - 确认 / 否决同一人 → `restoreManualPersonBridge` 把这一对的手动桥恢复成执行前
///   （执行前没有就删掉）。
/// 执行后用户又处理过（确认 / 否决 / 改判）的，撤销报 superseded、不覆盖。
List<OpDescription> describeMediaLinksOps(OpDescribeKit kit) {
  FushiDatabase db() => kit.context.appModel.database;
  return <OpDescription>[
    const OpDescription(
      id: 'links.list',
      method: 'GET',
      pattern: '$kMediaLinksCtlRoot/:endpoint',
      summary:
          'List cross-media links of one library item (original work, '
          'adaptations, game, theme songs…): confirmed links and pending '
          'suggestions with their source, confidence and reason.',
      params: <OpParam>[
        _endpointParam,
        OpParam.string(
          'state',
          description: 'Filter; default all.',
          enumValues: <String>['all', 'confirmed', 'suggested'],
        ),
      ],
    ),
    OpDescription(
      id: 'links.accept',
      method: 'POST',
      pattern: '$kMediaLinksCtlRoot/:endpoint/accept',
      summary:
          'Accept a suggested link of an item (it then shows as a fact in '
          '"same work").',
      risk: OpRisk.write,
      params: _pickParams,
      undo: _linkUndo(
        (MediaLinkId id) => db().unconfirmMediaLink(id),
        verb: 'unconfirm',
      ),
    ),
    OpDescription(
      id: 'links.reject',
      method: 'POST',
      pattern: '$kMediaLinksCtlRoot/:endpoint/reject',
      summary:
          'Mark a suggested link as unrelated (it will not be suggested '
          'again).',
      risk: OpRisk.write,
      params: _pickParams,
      undo: _linkUndo(
        (MediaLinkId id) => db().restoreMediaLinkSuggestion(id),
        verb: 'restore',
      ),
    ),
    OpDescription(
      id: 'links.infer',
      method: 'POST',
      pattern: '$kMediaLinksCtlRoot/:endpoint/infer',
      summary:
          'Find related works for an item and store them as suggestions '
          '(shared external ids, MAL source material, title match). Queries '
          'MAL / Wikidata; when an LLM is assigned to "media links" the '
          'candidates are also sent to that LLM for a verdict. Slow.',
      risk: OpRisk.write,
      params: const <OpParam>[_endpointParam],
      undo: opCustomUndo(
        payloadOf: (CtlCall call, Map<String, Object?> before, Object? r) =>
            <String, Object?>{
              'ids': <Object?>[
                if (r is Map && r['suggestions'] is List)
                  for (final Object? s in r['suggestions'] as List)
                    if (s is Map) s['id'],
              ],
            },
        describe: (Map<String, Object?> p) =>
            '${(p['ids'] as List? ?? const <Object?>[]).length} suggestion(s)',
        revert: (Map<String, Object?> payload) async {
          final List<Object?> ids =
              payload['ids'] as List? ?? const <Object?>[];
          int discarded = 0;
          for (final Object? raw in ids) {
            final MediaLinkId? id = mediaLinkIdFromJson(raw);
            if (id != null && await db().discardMediaLinkSuggestion(id)) {
              discarded++;
            }
          }
          if (ids.isNotEmpty && discarded == 0) {
            return const OpUndoOutcome.superseded('这些建议都已被处理过');
          }
          return OpUndoOutcome.done(
            discarded < ids.length ? '已撤回 $discarded 条，其余已被处理过，保留' : null,
          );
        },
      ),
    ),
    const OpDescription(
      id: 'people.list',
      method: 'GET',
      pattern: kPeopleCtlRoot,
      summary:
          'List people (voice actors, staff, artists) merged across video, '
          'games and music, with their person node, names and external ids.',
      params: <OpParam>[
        OpParam.string('search', description: 'Name keyword.'),
        OpParam.integer('limit', description: 'Max rows; default 50.'),
      ],
    ),
    const OpDescription(
      id: 'people.get',
      method: 'GET',
      pattern: '$kPeopleCtlRoot/:node',
      summary:
          'One person: voiced anime / game characters, staff credits, songs, '
          '"maybe the same person" suggestions and manual merges.',
      params: <OpParam>[_nodeParam],
    ),
    OpDescription(
      id: 'people.same',
      method: 'POST',
      pattern: '$kPeopleCtlRoot/:node/same',
      summary:
          'Confirm (same=true) or reject (same=false) that another person is '
          'the same person. same=false on a manually merged record undoes '
          'that merge.',
      risk: OpRisk.write,
      params: const <OpParam>[
        _nodeParam,
        OpParam.string(
          'other',
          description:
              'Node of the other person (from suggestions / people.list).',
          required: true,
        ),
        OpParam.boolean(
          'same',
          description: 'true = same person, false = not the same.',
          required: true,
        ),
      ],
      undo: opCustomUndo(
        payloadOf: (CtlCall call, Map<String, Object?> before, Object? r) {
          final Map<Object?, Object?> m = r is Map ? r : const {};
          return <String, Object?>{
            'pair': m['pair'],
            'same': m['same'],
            'at': m['at'],
            'previous': m['previous'],
          };
        },
        describe: (Map<String, Object?> p) => opUndoDisplay(p['pair']),
        revert: (Map<String, Object?> payload) async {
          final List<String> pair = opUndoStrings(payload['pair']);
          if (pair.length != 2) return const OpUndoOutcome.failed('撤销载荷缺 pair');
          final PersonIdentityBridgeRow? now = await db().manualPersonBridge(
            pair[0],
            pair[1],
          );
          final bool same = payload['same'] == true;
          final bool unchanged =
              now != null &&
              now.createdAt == (payload['at'] as num?)?.toInt() &&
              (now.deletedAt == null) == same;
          if (!unchanged) return const OpUndoOutcome.superseded();
          final Object? prev = payload['previous'];
          final bool ordered = pair[0].compareTo(pair[1]) <= 0;
          await db().restoreManualPersonBridge(
            pair[0],
            pair[1],
            previous: prev is Map
                ? PersonIdentityBridgeRow(
                    subject: ordered ? pair[0] : pair[1],
                    object: ordered ? pair[1] : pair[0],
                    source: PersonIdentityBridgeSource.manual,
                    createdAt: (prev['createdAt']! as num).toInt(),
                    deletedAt: (prev['deletedAt'] as num?)?.toInt(),
                  )
                : null,
          );
          return const OpUndoOutcome.done();
        },
      ),
    ),
  ];
}

const OpParam _endpointParam = OpParam.string(
  'endpoint',
  description:
      'Item as <kind>:<local key>; kind is book / audiobook / video_collection '
      '/ video_episode / game / music_album / music_track (e.g. book:<bookKey>, '
      'video_collection:<collection id>, game:<game id>).',
  required: true,
  inPath: true,
);

const OpParam _nodeParam = OpParam.string(
  'node',
  description: 'Person node from people.list, e.g. ref:video:<personKey>.',
  required: true,
  inPath: true,
);

const List<OpParam> _pickParams = <OpParam>[
  _endpointParam,
  OpParam.string(
    'other',
    description: 'The other end of the link as <kind>:<key> (from links.list).',
    required: true,
  ),
  OpParam.string(
    'relation',
    description:
        'Only needed when the two items have several links: adaptation / '
        'theme_song / soundtrack / same_work / cast.',
  ),
];

/// 接受 / 否决的撤销：载荷是结果里那条连接的五元组身份，[inverse] 是数据层的对称
/// 方法；它回 false（用户之后又处理过这条）就报 superseded。
OpUndo _linkUndo(
  Future<bool> Function(MediaLinkId id) inverse, {
  required String verb,
}) => opCustomUndo(
  payloadOf: (CtlCall call, Map<String, Object?> before, Object? r) {
    final Object? link = r is Map ? r['link'] : null;
    return <String, Object?>{
      'id': link is Map ? link['id'] : null,
      'other': link is Map && link['other'] is Map
          ? (link['other'] as Map)['title']
          : null,
    };
  },
  describe: (Map<String, Object?> p) => '$verb ${p['other'] ?? ''}'.trim(),
  revert: (Map<String, Object?> payload) async {
    final MediaLinkId? id = mediaLinkIdFromJson(payload['id']);
    if (id == null) return const OpUndoOutcome.failed('撤销载荷缺连接身份');
    return await inverse(id)
        ? const OpUndoOutcome.done()
        : const OpUndoOutcome.superseded();
  },
);
