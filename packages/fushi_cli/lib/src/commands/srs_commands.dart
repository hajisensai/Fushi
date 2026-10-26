import 'package:args/args.dart';

import '../ctl_commands.dart';

/// `fushi_cli srs …`：复习：牌组 / 笔记 / 统计 / 冲突 / 重复笔记合并（app 侧路由见 `fushi/lib/src/ops/ctl_srs_routes.dart`）。
///
/// 云同步（书 / 进度）中途的冲突走 `sync run --conflicts <策略>`（data_commands.dart）。
const List<CtlCommandGroup> srsCommandGroups = <CtlCommandGroup>[
  CtlCommandGroup(
    name: 'srs',
    summary: '复习：牌组、笔记搜索、统计、同步冲突中心、重复笔记合并',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'decks',
        summary: '列出牌组（父在前）与今天的新卡 / 学习 / 到期数',
        build: _buildDecks,
        render: _renderDecks,
      ),
      CtlCommandSpec(
        name: 'notes',
        summary: '搜索笔记 / 卡片（Anki 搜索语法；--field 按字段包含）',
        usage: '[查询...]',
        configure: _configureNotes,
        build: _buildNotes,
        render: _renderNotes,
      ),
      CtlCommandSpec(
        name: 'note',
        summary: '看一条笔记：全部字段、标签、卡片',
        usage: '<noteId>',
        build: _buildNote,
        render: _renderNote,
      ),
      CtlCommandSpec(
        name: 'stats',
        summary: '复习统计（与统计页同源）：今日、到期、卡片状态、30 天保留率、连续天数',
        configure: _configureStats,
        build: _buildStats,
        render: _renderStats,
      ),
      CtlCommandSpec(
        name: 'conflicts',
        summary: '冲突中心：被扣住的删除、被覆盖的设置 / 标志、待裁决笔记、疑似重复',
        build: _buildConflicts,
        render: _renderConflicts,
      ),
      CtlCommandSpec(
        name: 'conflict-delete',
        summary: '被扣住的删除：以删除为准（墓碑，可经 AI 操作记录撤销复活）',
        usage: '<冲突id>',
        build: _buildHeldDelete,
        render: _renderHeld,
      ),
      CtlCommandSpec(
        name: 'conflict-keep',
        summary: '被扣住的删除：保留条目（另一台设备的删除作废，不能撤销；需 --yes）',
        usage: '<冲突id>',
        configure: _configureYes,
        build: _buildHeldKeep,
        render: _renderHeld,
      ),
      CtlCommandSpec(
        name: 'conflict-resolve',
        summary: '被覆盖的设置 / 标志：--keep current（确认当前值）| replaced（改回被覆盖的值）',
        usage: '<kind> <entity> <key>',
        configure: _configureResolve,
        build: _buildResolve,
        render: _renderResolve,
      ),
      CtlCommandSpec(
        name: 'merge',
        summary: '合并重复笔记：其余笔记并进第一条（复习历史合并、空字段补齐）',
        usage: '<保留noteId> <并入noteId...>',
        build: _buildMerge,
        render: _renderMerge,
      ),
      CtlCommandSpec(
        name: 'not-duplicate',
        summary: '标记这些笔记「不是重复」，不再提示合并',
        usage: '<noteId> <noteId...>',
        build: _buildDismiss,
        render: _renderDismiss,
      ),
    ],
  ),
];

const String _root = '/api/admin/srs';

/// `conflict-resolve` 的实体类型（app 侧 `SrsEntityKind.wire`）。
const List<String> kSrsEntityKinds = <String>[
  'profile',
  'deck',
  'notetype',
  'note',
  'card',
];

String _seg(String raw) => Uri.encodeComponent(raw);

// ── decks ────────────────────────────────────────────────────────────

CtlRequestSpec _buildDecks(CtlCommandContext c) =>
    const CtlRequestSpec.get('$_root/decks');

String _renderDecks(Object? data) => renderCtlTable(
  data,
  const <(String, String)>[
    ('牌组', 'name'),
    ('新', 'new'),
    ('学习', 'learn'),
    ('到期', 'review'),
    ('总卡数', 'total'),
    ('id', 'id'),
  ],
  listKey: 'decks',
  empty: '（没有牌组）',
);

// ── notes / note ─────────────────────────────────────────────────────

void _configureNotes(ArgParser parser) {
  parser
    ..addOption('field', help: '只在这个字段里找包含查询文本的（不用记搜索语法）')
    ..addOption('deck', help: '只看这个牌组（全名，含子牌组）')
    ..addFlag('cards', negatable: false, help: '按卡片列出（缺省按笔记）')
    ..addOption('limit', help: '最多列出几条（缺省 50）')
    ..addOption('offset', help: '跳过前几条');
}

CtlRequestSpec _buildNotes(CtlCommandContext c) {
  final String query = c.rest.join(' ').trim();
  if (c.option('field') != null && query.isEmpty) {
    throw const CtlUsageError('--field 需要查询文本');
  }
  final int? limit = c.intOption('limit');
  final int? offset = c.intOption('offset');
  if (limit != null && limit <= 0) throw const CtlUsageError('--limit 必须大于 0');
  if (offset != null && offset < 0) throw const CtlUsageError('--offset 不能为负');
  return CtlRequestSpec.get(
    '$_root/notes',
    query: <String, String>{
      if (query.isNotEmpty) 'q': query,
      if (c.option('field') != null) 'field': c.option('field')!,
      if (c.option('deck') != null) 'deck': c.option('deck')!,
      'mode': c.flag('cards') ? 'cards' : 'notes',
      if (limit != null) 'limit': '$limit',
      if (offset != null) 'offset': '$offset',
    },
  );
}

String _renderNotes(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final bool cards = data['mode'] == 'cards';
  final String table = renderCtlTable(
    data,
    cards
        ? const <(String, String)>[
            ('排序字段', 'sortField'),
            ('牌组', 'deck'),
            ('模板', 'template'),
            ('队列', 'queue'),
            ('到期(天)', 'dueInDays'),
            ('卡片id', 'cardId'),
            ('笔记id', 'noteId'),
          ]
        : const <(String, String)>[
            ('排序字段', 'sortField'),
            ('笔记类型', 'noteType'),
            ('牌组', 'deck'),
            ('卡数', 'cards'),
            ('标签', 'tags'),
            ('笔记id', 'noteId'),
          ],
    listKey: 'items',
    empty: '（没有匹配的${cards ? '卡片' : '笔记'}）',
  );
  final List<Object?> items = data['items'] is List
      ? data['items']! as List<Object?>
      : const <Object?>[];
  return '共 ${data['total']} 条${items.length < (data['total'] as num? ?? 0) ? '（显示 ${items.length} 条）' : ''}\n$table';
}

CtlRequestSpec _buildNote(CtlCommandContext c) =>
    CtlRequestSpec.get('$_root/notes/${_seg(c.positional(0, 'noteId'))}');

String _renderNote(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final StringBuffer out = StringBuffer()
    ..writeln('${data['id']} · ${data['noteType']}')
    ..writeln(
      [
        if (data['deletedAt'] != null) '已删除',
        if (data['pendingDecision'] == true) '有待裁决的冲突',
        if (data['tags'] is List && (data['tags']! as List<Object?>).isNotEmpty)
          '标签：${(data['tags']! as List<Object?>).join(', ')}',
      ].join(' · '),
    );
  final Object? fields = data['fields'];
  if (fields is Map) {
    for (final MapEntry<Object?, Object?> f in fields.entries) {
      out.writeln('  ${f.key}: ${'${f.value}'.replaceAll('\n', ' ')}');
    }
  }
  out.write(
    renderCtlTable(
      data,
      const <(String, String)>[
        ('卡片id', 'id'),
        ('牌组', 'deck'),
        ('队列', 'queue'),
        ('间隔(天)', 'intervalDays'),
        ('复习', 'reps'),
        ('遗忘', 'lapses'),
      ],
      listKey: 'cards',
      empty: '（没有可见卡片）',
    ),
  );
  return out.toString();
}

// ── stats ────────────────────────────────────────────────────────────

void _configureStats(ArgParser parser) {
  parser.addOption('deck', help: '只看这个牌组子树（id 或全名）');
}

CtlRequestSpec _buildStats(CtlCommandContext c) => CtlRequestSpec.get(
  '$_root/stats',
  query: <String, String>{
    if (c.option('deck') != null) 'deck': c.option('deck')!,
  },
);

String _pct(Object? v) => v is num ? '${(v * 100).toStringAsFixed(1)}%' : '—';

String _renderStats(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final Map<Object?, Object?> today = data['today'] as Map? ?? const {};
  final Map<Object?, Object?> due = data['due'] as Map? ?? const {};
  final Map<Object?, Object?> cards = data['cards'] as Map? ?? const {};
  final Map<Object?, Object?> ret = data['retention30d'] as Map? ?? const {};
  final Map<Object?, Object?> streak = data['streak'] as Map? ?? const {};
  return <String>[
    if (data['deck'] != null) '牌组：${data['deck']}',
    '今天：复习 ${today['reviews']} 次 · 答对率 ${_pct(today['correctRate'])} · '
        '重来 ${today['again']} / 困难 ${today['hard']} / 良好 ${today['good']} / 简单 ${today['easy']}',
    '到期：今天 ${due['today']} · 明天 ${due['tomorrow']} · 逾期 ${due['overdue']} · 7 天内 ${due['next7Days']}',
    '卡片：新 ${cards['new']} · 学习中 ${cards['learning']} · 重学 ${cards['relearning']} · '
        '年轻 ${cards['young']} · 成熟 ${cards['mature']} · 暂停 ${cards['suspended']} · 共 ${cards['total']}',
    '30 天真实保留率：${_pct(ret['rate'])}（年轻 ${_pct(ret['young'])} · 成熟 ${_pct(ret['mature'])} · ${ret['reviews']} 次）'
        ' · 期望保留率 ${_pct(data['desiredRetention'])}',
    '连续学习：${streak['current']} 天（最长 ${streak['longest']} 天）',
  ].join('\n');
}

// ── conflicts ────────────────────────────────────────────────────────

CtlRequestSpec _buildConflicts(CtlCommandContext c) =>
    const CtlRequestSpec.get('$_root/conflicts');

String _renderConflicts(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final List<String> parts = <String>[];
  final Object? held = data['held'];
  if (held is List && held.isNotEmpty) {
    parts.add(
      '被扣住的删除（srs conflict-delete / conflict-keep <id>）：\n'
      '${renderCtlTable(held, const <(String, String)>[('条目', 'label'), ('类型', 'kind'), ('并发修改', 'others'), ('id', 'id')])}',
    );
  }
  final Object? fields = data['fields'];
  if (fields is List && fields.isNotEmpty) {
    final List<Map<String, Object?>> rows = <Map<String, Object?>>[
      for (final Object? f in fields)
        if (f is Map)
          <String, Object?>{
            'label': f['label'],
            'key': f['key'],
            'current': (f['current'] as Map?)?['value'],
            'replaced': (f['replaced'] as Map?)?['value'],
            'target': '${f['kind']} ${f['entity']} ${f['key']}',
          },
    ];
    parts.add(
      '被覆盖的设置 / 标志（srs conflict-resolve <kind> <entity> <key> --keep current|replaced）：\n'
      '${renderCtlTable(rows, const <(String, String)>[('条目', 'label'), ('键', 'key'), ('当前', 'current'), ('被覆盖', 'replaced'), ('参数', 'target')])}',
    );
  }
  final Object? pending = data['pendingNotes'];
  if (pending is List && pending.isNotEmpty) {
    parts.add(
      '待裁决的笔记（在 app 的笔记编辑页里处理）：\n'
      '${renderCtlTable(pending, const <(String, String)>[('笔记', 'label'), ('原因', 'reason'), ('id', 'id')])}',
    );
  }
  final Object? dups = data['duplicates'];
  if (dups is List && dups.isNotEmpty) {
    final StringBuffer out = StringBuffer(
      '疑似重复（srs merge <保留id> <并入id...> / srs not-duplicate <id...>）：',
    );
    for (final Object? g in dups) {
      if (g is! Map || g['notes'] is! List) continue;
      out.write('\n- ');
      out.write(
        <String>[
          for (final Object? n in g['notes']! as List<Object?>)
            if (n is Map) '${n['label']}（${n['id']}，复习 ${n['reviews']} 次）',
        ].join(' / '),
      );
    }
    parts.add(out.toString());
  }
  return parts.isEmpty ? '没有冲突' : parts.join('\n\n');
}

void _configureYes(ArgParser parser) {
  parser.addFlag('yes', abbr: 'y', negatable: false, help: '确认（这一步不能撤销）');
}

CtlRequestSpec _buildHeldDelete(CtlCommandContext c) => CtlRequestSpec.post(
  '$_root/conflicts/held/${_seg(c.positional(0, '冲突id'))}/delete',
);

CtlRequestSpec _buildHeldKeep(CtlCommandContext c) {
  final String id = c.positional(0, '冲突id');
  if (!c.flag('yes')) {
    throw const CtlUsageError('「保留」会让另一台设备的删除作废、冲突不再出现，确认请加 --yes');
  }
  return CtlRequestSpec.post(
    '$_root/conflicts/held/${_seg(id)}/keep',
    body: const <String, Object?>{'confirm': true},
  );
}

String _renderHeld(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return data['deleted'] == true
      ? '已按删除处理：${data['entityKind']} ${data['entity']}'
      : '已保留：${data['entityKind']} ${data['entity']}';
}

void _configureResolve(ArgParser parser) {
  parser.addOption(
    'keep',
    allowed: const <String>['current', 'replaced'],
    help: 'current = 确认当前生效的值；replaced = 改回被覆盖的值',
  );
}

CtlRequestSpec _buildResolve(CtlCommandContext c) {
  final String kind = c.positional(0, 'kind');
  if (!kSrsEntityKinds.contains(kind)) {
    throw CtlUsageError('kind 只能是 ${kSrsEntityKinds.join(' / ')}：$kind');
  }
  final String entity = c.positional(1, 'entity');
  final String key = c.positional(2, 'key');
  final String? keep = c.option('keep');
  if (keep == null) throw const CtlUsageError('缺少 --keep current|replaced');
  return CtlRequestSpec.post(
    '$_root/conflicts/fields/resolve',
    body: <String, Object?>{
      'kind': kind,
      'entity': entity,
      'key': key,
      'keep': keep,
    },
  );
}

String _renderResolve(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return '${data['kind']} ${data['entity']} ${data['key']} = ${data['value']}'
      '${data['keep'] == 'replaced' ? '（已改回被覆盖的值）' : '（已确认当前值）'}';
}

// ── merge / not-duplicate ────────────────────────────────────────────

CtlRequestSpec _buildMerge(CtlCommandContext c) {
  final String keep = c.positional(0, '保留noteId');
  final List<String> absorb = <String>[
    for (final String id in c.rest.skip(1))
      if (id.trim().isNotEmpty && id.trim() != keep) id.trim(),
  ];
  if (absorb.isEmpty) throw const CtlUsageError('缺少要并入的笔记 <并入noteId...>');
  return CtlRequestSpec.post(
    '$_root/duplicates/merge',
    body: <String, Object?>{'keep': keep, 'absorb': absorb},
  );
}

String _renderMerge(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final Object? absorbed = data['absorbed'];
  return '已把 ${absorbed is List ? absorbed.join(', ') : absorbed} 并进 ${data['keep']}：'
      '${data['linkedCards']} 张卡的复习历史已合并'
      '${(data['unmatchedCards'] as num? ?? 0) > 0 ? '，${data['unmatchedCards']} 张卡没有对应模板（随笔记删除，历史仍在时间线里）' : ''}';
}

CtlRequestSpec _buildDismiss(CtlCommandContext c) {
  final List<String> notes = <String>{
    for (final String id in c.rest)
      if (id.trim().isNotEmpty) id.trim(),
  }.toList();
  if (notes.length < 2)
    throw const CtlUsageError('至少给两条笔记 <noteId> <noteId...>');
  return CtlRequestSpec.post(
    '$_root/duplicates/dismiss',
    body: <String, Object?>{'notes': notes},
  );
}

String _renderDismiss(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final Object? notes = data['dismissed'];
  return '已标记不是重复：${notes is List ? notes.join(', ') : notes}';
}
