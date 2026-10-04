import 'package:args/args.dart';

import '../ctl_commands.dart';

/// dictionary 域命令（app 侧路由见 `fushi/lib/src/platform/desktop/ctl/ctl_dictionary_routes.dart`）。
///
/// - `fushi_cli dict …`：词典仓库（列出 / 开关 / 排序 / 删除 / 导入 / 在线更新）与结构化查词。
/// - `fushi_cli anki …`：Anki 状态、牌组 / 笔记类型、制卡、查重、同步。
const List<CtlCommandGroup> dictionaryCommandGroups = <CtlCommandGroup>[
  CtlCommandGroup(
    name: 'dict',
    summary: '词典管理与查词',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'ls',
        summary: '列出已安装词典（按类型、顺序）',
        configure: _configureDictLs,
        build: _buildDictLs,
        render: _renderDictLs,
      ),
      CtlCommandSpec(
        name: 'enable',
        summary: '启用词典（查词结果里显示）',
        usage: '<name>',
        build: _buildDictEnable,
        render: _renderDictOne,
      ),
      CtlCommandSpec(
        name: 'disable',
        summary: '停用词典（查词结果里隐藏）',
        usage: '<name>',
        build: _buildDictDisable,
        render: _renderDictOne,
      ),
      CtlCommandSpec(
        name: 'order',
        summary: '把词典移到同类型分区里的第 N 位（1 起算）',
        usage: '<name> <position>',
        build: _buildDictOrder,
        render: _renderDictOne,
      ),
      CtlCommandSpec(
        name: 'rm',
        summary: '删除词典（需 --yes）',
        usage: '<name>',
        configure: _configureYes,
        build: _buildDictRm,
        render: _renderDictRm,
      ),
      CtlCommandSpec(
        name: 'import',
        summary: '导入词典文件或目录（zip / mdx / dsl / ifo …；.css 作为样式附件）',
        usage: '<file...>',
        build: _buildDictImport,
        render: _renderDictImport,
      ),
      CtlCommandSpec(
        name: 'update',
        summary: '在线检查并更新词典（缺省全部可更新词典；后台任务，--wait 等完）',
        usage: '[name...]',
        configure: _configureDictUpdate,
        build: _buildDictUpdate,
        render: _renderDictUpdate,
      ),
      CtlCommandSpec(
        name: 'job',
        summary: '查看词典下载 / 导入任务进度与最近一次更新结果',
        build: _buildDictJob,
        render: _renderDictJob,
      ),
      CtlCommandSpec(
        name: 'cancel',
        summary: '取消正在下载的词典任务（导入阶段不可取消）',
        build: _buildDictCancel,
        render: _renderDictCancel,
      ),
      CtlCommandSpec(
        name: 'search',
        summary: '查词，返回结构化结果（不弹窗；弹窗用 fushi_cli lookup）',
        usage: '<词...>',
        configure: _configureDictSearch,
        build: _buildDictSearch,
        render: _renderDictSearch,
      ),
    ],
  ),
  CtlCommandGroup(
    name: 'anki',
    summary: 'Anki 状态与制卡',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'status',
        summary: '当前 Anki 后端、牌组、笔记类型与是否可用',
        configure: _configureAnkiStatus,
        build: _buildAnkiStatus,
        render: _renderAnkiStatus,
      ),
      CtlCommandSpec(
        name: 'decks',
        summary: '列出 Anki 牌组（* 为当前制卡牌组）',
        build: _buildAnkiDecks,
        render: _renderAnkiDecks,
      ),
      CtlCommandSpec(
        name: 'models',
        summary: '列出 Anki 笔记类型（* 为当前制卡笔记类型）',
        build: _buildAnkiModels,
        render: _renderAnkiModels,
      ),
      CtlCommandSpec(
        name: 'set',
        summary: '设置制卡用的牌组 / 笔记类型',
        configure: _configureAnkiSet,
        build: _buildAnkiSet,
        render: _renderAnkiSet,
      ),
      CtlCommandSpec(
        name: 'mine',
        summary: '制卡（缺读音 / 释义时从词典补）',
        configure: _configureAnkiMine,
        build: _buildAnkiMine,
        render: _renderAnkiMine,
      ),
      CtlCommandSpec(
        name: 'duplicate',
        summary: '查 Anki 里是否已有这个词的卡',
        usage: '<词>',
        configure: _configureReading,
        build: _buildAnkiDuplicate,
        render: _renderAnkiDuplicate,
      ),
      CtlCommandSpec(
        name: 'sync',
        summary: '触发 Anki 同步（仅「Anki 同步客户端」后端）',
        build: _buildAnkiSync,
        render: _renderAnkiSync,
      ),
    ],
  ),
];

const String _dictionaries = '/api/admin/dictionaries';
const String _anki = '/api/admin/anki';

String _dictPath(String name) => '$_dictionaries/${Uri.encodeComponent(name)}';

// ── 选项 ──────────────────────────────────────────────────────────────────

void _configureYes(ArgParser parser) =>
    parser.addFlag('yes', abbr: 'y', negatable: false, help: '确认执行破坏性操作');

void _configureDictLs(ArgParser parser) => parser.addOption(
  'type',
  allowed: <String>['term', 'frequency', 'pitch', 'kanji'],
  help: '只列某一类型',
);

void _configureDictUpdate(ArgParser parser) =>
    parser.addFlag('wait', negatable: false, help: '等更新跑完再返回逐本结果');

void _configureDictSearch(ArgParser parser) {
  parser
    ..addOption('limit', abbr: 'n', help: '最多返回多少个词头（缺省 10）')
    ..addOption('max-meaning', help: '单条释义最多多少字（缺省不截断）')
    ..addFlag('wildcards', negatable: false, help: '启用通配符（* ?）');
}

void _configureAnkiStatus(ArgParser parser) => parser.addFlag(
  'probe',
  defaultsTo: true,
  help: '实际连一次 Anki 判断是否可用（--no-probe 只读本地设置）',
);

void _configureAnkiSet(ArgParser parser) {
  parser
    ..addOption('deck', help: '牌组名')
    ..addOption('model', help: '笔记类型名');
}

void _configureReading(ArgParser parser) =>
    parser.addOption('reading', help: '读音（区分同形异音词）');

void _configureAnkiMine(ArgParser parser) {
  parser
    ..addOption('word', abbr: 'w', help: '要制卡的词（必填）')
    ..addOption('reading', help: '读音（缺省取词典第一条）')
    ..addOption('sentence', abbr: 's', help: '例句')
    ..addOption('glossary', help: '释义（HTML；缺省从词典拼）')
    ..addOption('source', help: '来源（URL / 标题，写进卡片的文档标题）')
    ..addMultiOption('field', help: '额外制卡字段 key=value（可重复）')
    ..addFlag('allow-duplicate', negatable: false, help: '已有同词卡片时仍新增')
    ..addFlag(
      'lookup',
      defaultsTo: true,
      help: '缺读音 / 释义时查词典补（--no-lookup 关闭）',
    );
}

// ── dict ─────────────────────────────────────────────────────────────────

CtlRequestSpec _buildDictLs(CtlCommandContext c) {
  final String? type = c.option('type');
  return CtlRequestSpec.get(
    _dictionaries,
    query: type == null ? null : <String, String>{'type': type},
  );
}

CtlRequestSpec _buildDictEnable(CtlCommandContext c) => CtlRequestSpec.put(
  _dictPath(c.joinedRest(0, 'name')),
  body: const <String, Object?>{'enabled': true},
);

CtlRequestSpec _buildDictDisable(CtlCommandContext c) => CtlRequestSpec.put(
  _dictPath(c.joinedRest(0, 'name')),
  body: const <String, Object?>{'enabled': false},
);

CtlRequestSpec _buildDictOrder(CtlCommandContext c) {
  if (c.rest.length < 2) throw const CtlUsageError('需要 <name> 和 <position>');
  final String rawPosition = c.rest.last.trim();
  final int? position = int.tryParse(rawPosition);
  if (position == null || position < 1) {
    throw CtlUsageError('<position> 必须是 ≥ 1 的整数：$rawPosition');
  }
  // 名字可能带空格：除最后一个参数外都算名字。
  final String name = c.rest.sublist(0, c.rest.length - 1).join(' ').trim();
  if (name.isEmpty) throw const CtlUsageError('缺少参数 <name>');
  return CtlRequestSpec.put(
    _dictPath(name),
    body: <String, Object?>{'position': position},
  );
}

CtlRequestSpec _buildDictRm(CtlCommandContext c) {
  final String name = c.joinedRest(0, 'name');
  if (!c.flag('yes')) throw const CtlUsageError('删除词典需要 --yes 确认');
  return CtlRequestSpec.delete(
    _dictPath(name),
    query: const <String, String>{'confirm': 'true'},
  );
}

CtlRequestSpec _buildDictImport(CtlCommandContext c) {
  if (c.rest.isEmpty) throw const CtlUsageError('缺少参数 <file...>');
  return CtlRequestSpec.post(
    '$_dictionaries/import',
    body: <String, Object?>{
      'paths': <String>[for (final String raw in c.rest) ctlAbsolutePath(raw)],
    },
  );
}

CtlRequestSpec _buildDictUpdate(CtlCommandContext c) => CtlRequestSpec.post(
  '$_dictionaries/update',
  body: <String, Object?>{
    'names': <String>[
      for (final String n in c.rest)
        if (n.trim().isNotEmpty) n,
    ],
    if (c.flag('wait')) 'wait': true,
  },
);

CtlRequestSpec _buildDictJob(CtlCommandContext c) =>
    const CtlRequestSpec.get('$_dictionaries/job');

CtlRequestSpec _buildDictCancel(CtlCommandContext c) =>
    const CtlRequestSpec.post('$_dictionaries/job/cancel');

CtlRequestSpec _buildDictSearch(CtlCommandContext c) {
  final String term = c.joinedRest(0, '词');
  final int? limit = c.intOption('limit');
  if (limit != null && limit < 1) throw const CtlUsageError('--limit 必须 ≥ 1');
  final int? maxMeaning = c.intOption('max-meaning');
  return CtlRequestSpec.get(
    '$_dictionaries/search',
    query: <String, String>{
      'term': term,
      if (limit != null) 'limit': '$limit',
      if (maxMeaning != null) 'maxMeaningChars': '$maxMeaning',
      if (c.flag('wildcards')) 'wildcards': 'true',
    },
  );
}

String _renderDictLs(Object? data) => renderCtlTable(
  data,
  const <(String, String)>[
    ('类型', 'type'),
    ('序', 'order'),
    ('启用', 'enabled'),
    ('版本', 'revision'),
    ('可更新', 'updatable'),
    ('名称', 'displayName'),
  ],
  listKey: 'dictionaries',
  empty: '（没有词典，用 fushi_cli dict import <文件> 导入）',
);

String _renderDictOne(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return '${data['displayName']}：${data['enabled'] == true ? '启用' : '停用'}，'
      '${data['type']} 分区第 ${(data['order'] as num? ?? 0).toInt() + 1} 位';
}

String _renderDictRm(Object? data) =>
    data is Map ? '已删除词典：${data['deleted']}' : renderCtlJson(data);

String _renderDictImport(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final List<String> lines = <String>[];
  for (final Object? r in (data['results'] as List?) ?? const <Object?>[]) {
    if (r is! Map) continue;
    if (r['ok'] == true) {
      final List<Object?> added = (r['added'] as List?) ?? const <Object?>[];
      lines.add(
        added.isEmpty
            ? '·  ${r['path']}：未新增（${r['message'] ?? '可能已是最新'}）'
            : '✓  ${r['path']} → ${added.join('、')}',
      );
    } else {
      lines.add('✗  ${r['path']}：${r['error']}');
    }
  }
  if (data['memoryError'] == true) lines.add('注意：导入期间内存不足');
  return lines.isEmpty ? renderCtlJson(data) : lines.join('\n');
}

String _renderDictUpdate(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  if (data['started'] == false) return '${data['message']}';
  final String head = data['finished'] == true
      ? '更新任务 #${data['id']} 已完成'
      : '更新任务 #${data['id']} 已在后台开始（fushi_cli dict job 查看进度）';
  final List<Object?> results = (data['results'] as List?) ?? const <Object?>[];
  if (results.isEmpty) {
    return '$head：${((data['targets'] as List?) ?? const <Object?>[]).join('、')}';
  }
  return <String>[head, ..._updateResultLines(results)].join('\n');
}

Iterable<String> _updateResultLines(List<Object?> results) sync* {
  const Map<String, String> label = <String, String>{
    'updated': '已更新',
    'latest': '已是最新',
    'checkFailed': '检查失败（拿不到远端 index）',
    'failed': '失败',
    'cancelled': '已取消',
  };
  for (final Object? r in results) {
    if (r is! Map) continue;
    final String status = '${r['status']}';
    final String extra = r['to'] != null
        ? '（${r['from']} → ${r['to']}）'
        : r['error'] != null
        ? '：${r['error']}'
        : '';
    yield '  ${r['name']}：${label[status] ?? status}$extra';
  }
}

String _renderDictJob(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final List<String> lines = <String>[
    data['busy'] == true
        ? '进行中（${data['phase']}）：${data['message']}'
              '  ${((data['progress'] as num? ?? 0) * 100).round()}%'
        : '没有正在进行的词典任务',
  ];
  final Object? last = data['last'];
  if (last is Map) {
    lines.add(
      '最近一次更新 #${last['id']}：${last['finished'] == true ? '已完成' : '进行中'}',
    );
    lines.addAll(
      _updateResultLines((last['results'] as List?) ?? const <Object?>[]),
    );
  }
  return lines.join('\n');
}

String _renderDictCancel(Object? data) => '已请求取消词典任务';

String _renderDictSearch(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final List<Object?> entries = (data['entries'] as List?) ?? const <Object?>[];
  if (entries.isEmpty) return '没有查到「${data['term']}」';
  final StringBuffer out = StringBuffer();
  for (final Object? e in entries) {
    if (e is! Map) continue;
    final String reading = '${e['reading'] ?? ''}';
    out.writeln(
      '${e['word']}${reading.isEmpty || reading == e['word'] ? '' : '【$reading】'}'
      '  〔${e['dictionary']}〕',
    );
    final List<String> meaning = '${e['meaning'] ?? ''}'
        .split('\n')
        .map((String l) => l.trim())
        .where((String l) => l.isNotEmpty)
        .toList();
    for (final String line in meaning.take(3)) {
      out.writeln('    $line');
    }
    if (meaning.length > 3)
      out.writeln('    …（共 ${meaning.length} 行，--json 看全文）');
  }
  if (data['truncated'] == true) out.writeln('（结果已截断，可加大 --limit）');
  return out.toString().trimRight();
}

// ── anki ─────────────────────────────────────────────────────────────────

CtlRequestSpec _buildAnkiStatus(CtlCommandContext c) => CtlRequestSpec.get(
  _anki,
  query: c.flag('probe') ? null : const <String, String>{'probe': 'false'},
);

CtlRequestSpec _buildAnkiDecks(CtlCommandContext c) =>
    const CtlRequestSpec.get('$_anki/decks');

CtlRequestSpec _buildAnkiModels(CtlCommandContext c) =>
    const CtlRequestSpec.get('$_anki/models');

CtlRequestSpec _buildAnkiSet(CtlCommandContext c) {
  final String? deck = c.option('deck');
  final String? model = c.option('model');
  if (deck == null && model == null) {
    throw const CtlUsageError('至少给 --deck 或 --model 之一');
  }
  return CtlRequestSpec.put(
    '$_anki/settings',
    body: <String, Object?>{
      if (deck != null) 'deck': deck,
      if (model != null) 'model': model,
    },
  );
}

CtlRequestSpec _buildAnkiMine(CtlCommandContext c) {
  final String? word = c.option('word') ?? c.optionalPositional(0);
  if (word == null) throw const CtlUsageError('缺少 --word <词>');
  final Map<String, String> fields = <String, String>{};
  for (final String pair in c.multiOption('field')) {
    final int eq = pair.indexOf('=');
    if (eq <= 0) throw CtlUsageError('--field 必须是 key=value：$pair');
    fields[pair.substring(0, eq).trim()] = pair.substring(eq + 1);
  }
  final String? reading = c.option('reading');
  final String? sentence = c.option('sentence');
  final String? glossary = c.option('glossary');
  final String? source = c.option('source');
  return CtlRequestSpec.post(
    '$_anki/mine',
    body: <String, Object?>{
      'word': word,
      if (reading != null) 'reading': reading,
      if (sentence != null) 'sentence': sentence,
      if (glossary != null) 'glossary': glossary,
      if (source != null) 'source': source,
      if (fields.isNotEmpty) 'fields': fields,
      if (c.flag('allow-duplicate')) 'allowDuplicate': true,
      if (!c.flag('lookup')) 'lookup': false,
    },
  );
}

CtlRequestSpec _buildAnkiDuplicate(CtlCommandContext c) {
  final String expression = c.joinedRest(0, '词');
  final String? reading = c.option('reading');
  return CtlRequestSpec.get(
    '$_anki/duplicate',
    query: <String, String>{
      'expression': expression,
      if (reading != null) 'reading': reading,
    },
  );
}

CtlRequestSpec _buildAnkiSync(CtlCommandContext c) =>
    const CtlRequestSpec.post('$_anki/sync');

String _renderAnkiStatus(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final List<String> lines = <String>[
    '后端：${data['backend']}${data['mineToServer'] == true ? '（制卡转发到互联主机）' : ''}',
    '牌组：${data['deck'] ?? '（未选）'}',
    '笔记类型：${data['model'] ?? '（未选）'}',
  ];
  final Object? connect = data['ankiConnect'];
  if (connect is Map) {
    lines.add(
      'AnkiConnect：${connect['https'] == true ? 'https' : 'http'}://'
      '${connect['host']}:${connect['port']}'
      '${connect['apiKeySet'] == true ? '（已设 API key）' : ''}',
    );
  }
  final Object? sync = data['sync'];
  if (sync is Map) {
    lines.add('同步：${sync['phase']}，未同步 ${sync['unsynced']} 张');
  }
  if (data['probed'] == true) {
    lines.add(
      data['available'] == true
          ? '可用：是（${data['deckCount']} 个牌组，${data['modelCount']} 个笔记类型）'
          : '可用：否 —— ${data['error']}',
    );
  }
  if (data['configured'] != true) lines.add('尚未配置牌组 / 笔记类型：fushi_cli anki set');
  return lines.join('\n');
}

String _renderAnkiDecks(Object? data) => renderCtlTable(
  _markSelected(data, 'decks'),
  const <(String, String)>[('', 'mark'), ('ID', 'id'), ('牌组', 'name')],
  listKey: 'decks',
);

String _renderAnkiModels(Object? data) =>
    renderCtlTable(_markSelected(data, 'models'), const <(String, String)>[
      ('', 'mark'),
      ('ID', 'id'),
      ('笔记类型', 'name'),
      ('字段', 'fields'),
    ], listKey: 'models');

Object? _markSelected(Object? data, String key) {
  if (data is! Map || data[key] is! List) return data;
  return <String, Object?>{
    key: <Object?>[
      for (final Object? row in data[key] as List)
        row is Map
            ? <String, Object?>{
                ...row.cast<String, Object?>(),
                'mark': row['selected'] == true ? '*' : '',
              }
            : row,
    ],
  };
}

String _renderAnkiSet(Object? data) => data is Map
    ? '制卡牌组：${data['deck'] ?? '（未选）'}；笔记类型：${data['model'] ?? '（未选）'}'
    : renderCtlJson(data);

String _renderAnkiMine(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final String word = '${data['expression']}';
  final String head = switch ('${data['result']}') {
    'success' =>
      '已制卡：$word'
          '${data['noteId'] != null ? '（note ${data['noteId']}）' : ''}'
          '${data['deckName'] != null ? ' → ${data['deckName']}' : ''}',
    'duplicate' => '未制卡：Anki 里已有「$word」（--allow-duplicate 强制新增）',
    'notConfigured' => '未制卡：还没配置 Anki 牌组 / 笔记类型（fushi_cli anki set）',
    'queued' => '已放进待发队列：$word（Anki 暂不可达，稍后自动补发）',
    _ => '制卡失败：$word',
  };
  final List<String> lines = <String>[head];
  if (data['message'] != null) lines.add('  ${data['message']}');
  if (data['result'] == 'success' && data['glossaryFilled'] != true) {
    lines.add('  注意：释义为空（词典没查到，可用 --glossary 指定）');
  }
  return lines.join('\n');
}

String _renderAnkiDuplicate(Object? data) => data is Map
    ? (data['duplicate'] == true
          ? 'Anki 里已有「${data['expression']}」'
          : 'Anki 里还没有「${data['expression']}」')
    : renderCtlJson(data);

String _renderAnkiSync(Object? data) => data is Map
    ? '同步结果：${data['phase']}，未同步 ${data['unsynced']} 张'
          '${data['message'] != null ? '（${data['message']}）' : ''}'
    : renderCtlJson(data);
