import 'package:args/args.dart';

import '../ctl_commands.dart';

/// `fushi_cli links …`：作品图谱（跨媒体关联建议）与人物（app 侧路由见 `fushi/lib/src/ops/ctl_media_links_routes.dart`）。
///
/// 端点写成 `<种类>:<本地键>`（`book:<bookKey>`、`video_collection:<合集 id>`、
/// `video_episode:<bookUid>`、`game:<游戏 id>`、`music_track:<trackUid>`…）。人物另成
/// `people` 组（人物节点 `ref:<域>:<键>`，见 `people ls`），一并从这里导出。
const List<CtlCommandGroup> mediaLinksCommandGroups = <CtlCommandGroup>[
  CtlCommandGroup(
    name: 'links',
    summary: '作品图谱：关联作品与建议（接受 / 不相关 / 查找相关作品）',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'ls',
        summary: '列出一个条目的关联与建议（--state confirmed | suggested）',
        usage: '<endpoint>',
        configure: _configureState,
        build: _buildList,
        render: _renderList,
      ),
      CtlCommandSpec(
        name: 'accept',
        summary: '接受一条建议（之后显示为「同一作品」）',
        usage: '<endpoint> <other>',
        configure: _configureRelation,
        build: _buildAccept,
        render: _renderDecision,
      ),
      CtlCommandSpec(
        name: 'reject',
        summary: '把一条建议标成不相关（之后不再提议这一对）',
        usage: '<endpoint> <other>',
        configure: _configureRelation,
        build: _buildReject,
        render: _renderDecision,
      ),
      CtlCommandSpec(
        name: 'infer',
        summary: '查找相关作品：联网查 MAL / Wikidata；「作品图谱」指派了 AI 时会把候选发给该 AI 裁决',
        usage: '<endpoint>',
        build: _buildInfer,
        render: _renderInfer,
      ),
    ],
  ),
  CtlCommandGroup(
    name: 'people',
    summary: '人物（声优 / 制作人员 / 艺人）：跨视频、游戏、音乐聚合与「同一人」裁决',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'ls',
        summary: '列出人物（可按名字搜）',
        usage: '[search...]',
        configure: _configureLimit,
        build: _buildPeople,
        render: _renderPeople,
      ),
      CtlCommandSpec(
        name: 'get',
        summary: '人物详情：配音角色、职位、曲目、「可能是同一人」建议',
        usage: '<node>',
        build: _buildPerson,
        render: _renderPerson,
      ),
      CtlCommandSpec(
        name: 'same',
        summary: '确认两条人物是同一人',
        usage: '<node> <other>',
        build: _buildSame,
        render: _renderSame,
      ),
      CtlCommandSpec(
        name: 'not-same',
        summary: '否决「同一人」（对手动合并过的记录 = 取消合并）',
        usage: '<node> <other>',
        build: _buildNotSame,
        render: _renderSame,
      ),
    ],
  ),
];

const String _links = '/api/admin/links';
const String _people = '/api/admin/people';

/// 端点种类（`MediaLinkKind.dbValue`）。
const List<String> kMediaLinkEndpointKinds = <String>[
  'book',
  'audiobook',
  'video_collection',
  'video_episode',
  'game',
  'music_album',
  'music_track',
];

/// 关系值域（`MediaLinkRelation.dbValue`）。
const List<String> kMediaLinkRelations = <String>[
  'adaptation',
  'theme_song',
  'soundtrack',
  'same_work',
  'cast',
];

String _endpoint(CtlCommandContext context, int index, String name) {
  final String raw = context.positional(index, name).trim();
  final int colon = raw.indexOf(':');
  if (colon <= 0 ||
      colon == raw.length - 1 ||
      !kMediaLinkEndpointKinds.contains(raw.substring(0, colon))) {
    throw CtlUsageError(
      '<$name> 要写成 <种类>:<键>，种类是 ${kMediaLinkEndpointKinds.join(' / ')}：$raw',
    );
  }
  return raw;
}

String _node(CtlCommandContext context, int index, String name) {
  final String raw = context.positional(index, name).trim();
  if (!RegExp(r'^(ref|id):[^:]+:.+').hasMatch(raw)) {
    throw CtlUsageError('<$name> 要写成人物节点（ref:<域>:<键>，见 people ls）：$raw');
  }
  return raw;
}

void _configureState(ArgParser parser) {
  parser.addOption(
    'state',
    allowed: const <String>['all', 'confirmed', 'suggested'],
    help: '只看已确认 / 建议（默认全部）',
  );
}

void _configureRelation(ArgParser parser) {
  parser.addOption(
    'relation',
    allowed: kMediaLinkRelations,
    help: '两者之间有多条关联时指定是哪一条',
  );
}

void _configureLimit(ArgParser parser) {
  parser.addOption('limit', help: '最多列几个（默认 50）');
}

CtlRequestSpec _buildList(CtlCommandContext context) {
  final String endpoint = _endpoint(context, 0, 'endpoint');
  final String? state = context.option('state');
  return CtlRequestSpec.get(
    '$_links/${Uri.encodeComponent(endpoint)}',
    query: <String, String>{'state': ?state},
  );
}

CtlRequestSpec _decision(CtlCommandContext context, String verb) {
  final String endpoint = _endpoint(context, 0, 'endpoint');
  final String other = _endpoint(context, 1, 'other');
  final String? relation = context.option('relation');
  return CtlRequestSpec.post(
    '$_links/${Uri.encodeComponent(endpoint)}/$verb',
    body: <String, Object?>{'other': other, 'relation': ?relation},
  );
}

CtlRequestSpec _buildAccept(CtlCommandContext context) =>
    _decision(context, 'accept');

CtlRequestSpec _buildReject(CtlCommandContext context) =>
    _decision(context, 'reject');

CtlRequestSpec _buildInfer(CtlCommandContext context) => CtlRequestSpec.post(
  '$_links/${Uri.encodeComponent(_endpoint(context, 0, 'endpoint'))}/infer',
);

CtlRequestSpec _buildPeople(CtlCommandContext context) {
  final String search = context.rest.join(' ').trim();
  final String? limit = context.option('limit');
  if (limit != null && !RegExp(r'^[1-9]\d*$').hasMatch(limit)) {
    throw CtlUsageError('--limit 必须是正整数：$limit');
  }
  return CtlRequestSpec.get(
    _people,
    query: <String, String>{
      if (search.isNotEmpty) 'search': search,
      'limit': ?limit,
    },
  );
}

CtlRequestSpec _buildPerson(CtlCommandContext context) => CtlRequestSpec.get(
  '$_people/${Uri.encodeComponent(_node(context, 0, 'node'))}',
);

CtlRequestSpec _personDecision(
  CtlCommandContext context, {
  required bool same,
}) {
  final String node = _node(context, 0, 'node');
  final String other = _node(context, 1, 'other');
  return CtlRequestSpec.post(
    '$_people/${Uri.encodeComponent(node)}/same',
    body: <String, Object?>{'other': other, 'same': same},
  );
}

CtlRequestSpec _buildSame(CtlCommandContext context) =>
    _personDecision(context, same: true);

CtlRequestSpec _buildNotSame(CtlCommandContext context) =>
    _personDecision(context, same: false);

/// 连接状态 → 中文。
String describeMediaLinkState(String? state) => switch (state) {
  'confirmed' => '已确认',
  'suggested' => '建议',
  'removed' => '已否决',
  _ => state ?? '',
};

List<Map<String, Object?>> _linkRows(Object? links) => <Map<String, Object?>>[
  if (links is List)
    for (final Object? l in links)
      if (l is Map)
        <String, Object?>{
          'state': describeMediaLinkState('${l['state']}'),
          'relation': l['relation'],
          'other': l['other'] is Map ? (l['other'] as Map)['endpoint'] : null,
          'title': l['other'] is Map
              ? '${(l['other'] as Map)['title']}'
                    '${(l['other'] as Map)['inLibrary'] == false ? '（未入库）' : ''}'
              : null,
          'source': l['confidence'] == null
              ? l['source']
              : '${l['source']} ${l['confidence']}',
        },
];

const List<(String, String)> _linkColumns = <(String, String)>[
  ('状态', 'state'),
  ('关系', 'relation'),
  ('另一端', 'other'),
  ('标题', 'title'),
  ('来源', 'source'),
];

String _renderList(Object? data) {
  if (data is! Map) return '完成';
  return '${data['endpoint']} · ${data['title']}\n'
      '${renderCtlTable(_linkRows(data['links']), _linkColumns, empty: '没有关联')}';
}

String _renderDecision(Object? data) {
  final Object? link = data is Map ? data['link'] : null;
  if (link is! Map) return '完成';
  final Object? other = link['other'];
  return '${describeMediaLinkState('${link['state']}')}：${link['relation']} · '
      '${other is Map ? '${other['endpoint']} ${other['title']}' : ''}';
}

String _renderInfer(Object? data) {
  if (data is! Map) return '完成';
  final StringBuffer out = StringBuffer()
    ..write('${data['endpoint']} · 新增建议 ${data['added']} 条');
  if (data['ai'] == true) out.write('（候选已交「作品图谱」AI 裁决）');
  final List<Map<String, Object?>> rows = _linkRows(data['suggestions']);
  if (rows.isNotEmpty) {
    out
      ..writeln()
      ..write(renderCtlTable(rows, _linkColumns));
  }
  return out.toString();
}

String _renderPeople(Object? data) {
  if (data is! Map) return '完成';
  final List<Map<String, Object?>> rows = <Map<String, Object?>>[
    if (data['people'] is List)
      for (final Object? p in data['people'] as List)
        if (p is Map)
          <String, Object?>{
            'node': p['node'],
            'name': p['name'],
            'domains': p['domains'] is List
                ? (p['domains'] as List).join(',')
                : null,
          },
  ];
  final String table = renderCtlTable(rows, const <(String, String)>[
    ('节点', 'node'),
    ('名字', 'name'),
    ('出现在', 'domains'),
  ], empty: '没有人物');
  final Object? total = data['total'];
  return total is int && total > rows.length
      ? '$table\n（共 $total 人，只列前 ${rows.length} 个；--limit 调大）'
      : table;
}

String _workLine(Object? row, String extraKey) {
  if (row is! Map) return '';
  final Object? work = row['work'];
  final String title = work is Map ? '${work['title']}' : '';
  final Object? extra = row[extraKey];
  return extra == null ? title : '$title · $extra';
}

String _renderPerson(Object? data) {
  if (data is! Map) return '完成';
  final StringBuffer out = StringBuffer()
    ..writeln('${data['name']}  [${data['node']}]');
  if (data['otherNames'] case final List<Object?> names when names.isNotEmpty) {
    out.writeln('别名：${names.join(' / ')}');
  }
  for (final (String label, String key, String extra)
      in const <(String, String, String)>[
        ('配音（动画）', 'voiceRoles', 'character'),
        ('制作', 'staff', 'role'),
        ('配音（游戏）', 'gameRoles', 'character'),
        ('曲目', 'songs', 'characters'),
      ]) {
    final Object? rows = data[key];
    if (rows is! List || rows.isEmpty) continue;
    out.writeln('$label：');
    for (final Object? r in rows) {
      out.writeln('  ${_workLine(r, extra)}');
    }
  }
  if (data['suggestions'] case final List<Object?> s when s.isNotEmpty) {
    out.writeln('可能是同一人（people same / not-same）：');
    for (final Object? row in s) {
      if (row is Map) out.writeln('  ${row['node']}  ${row['name']}');
    }
  }
  return out.toString().trimRight();
}

String _renderSame(Object? data) {
  if (data is! Map) return '完成';
  return data['same'] == true
      ? '已确认 ${data['node']} 与 ${data['other']} 是同一人'
      : '已记为不是同一人：${data['node']} / ${data['other']}';
}
