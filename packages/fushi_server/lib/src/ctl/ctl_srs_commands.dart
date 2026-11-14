/// `ctl srs` 里看 / 改复习库**内容**的动作（配置面的 `srs status|profiles|add|…` 在 ctl_commands.dart）：
/// 牌组、笔记搜索、统计、冲突中心、重复笔记合并、批量改笔记。端点是 admin API 的
/// `/api/admin/srs/{decks,notes,stats,conflicts,duplicates}*`（admin_srs_ctl.dart），背后与 app 的
/// `fushi_cli srs …` 是同一份 engine 路由，所以动作名与参数也照它的来；多出来的只有 `--srs-profile <uid>`
/// （服务端一个进程持有多份 profile 的库；只提供一份时可省）。
///
/// 这里的写操作直接落库、不记撤销（管理员自己敲的命令；可撤销的那条路是已配对设备上的 AI 助手会话）。
/// 批量改笔记先用 `--dry-run` 预演。
library;

import 'dart:convert';

import 'package:args/args.dart';
import 'package:fushi_cli/fushi_cli.dart' show renderCtlTable;
import 'package:fushi_server/src/server_language.dart';

const String _root = '/api/admin/srs';

/// 本文件负责的 `srs` 子动作（`ctl_commands.dart` 据此转交）。
const Set<String> kCtlSrsDataActions = <String>{
  'help',
  'decks',
  'notes',
  'note',
  'stats',
  'conflicts',
  'conflict-delete',
  'conflict-keep',
  'conflict-resolve',
  'merge',
  'not-duplicate',
  'card-type',
  'set-field',
  'find-replace',
};

/// 批量设卡型的取值（engine `SrsCardType.wire`；服务端照样会校验）。
const List<String> _cardTypes = <String>[
  'word',
  'sentence',
  'word-and-sentence',
  'click',
  'audio',
];

/// 冲突里的实体类型（engine `SrsEntityKind.wire`）。
const List<String> _entityKinds = <String>[
  'profile',
  'deck',
  'notetype',
  'note',
  'card',
];

/// 一个单请求动作。
class CtlSrsRequest {
  const CtlSrsRequest(
    this.method,
    this.path, {
    this.body,
    this.query,
    required this.render,
  });

  final String method;
  final String path;
  final Map<String, Object?>? body;
  final Map<String, String>? query;
  final void Function(Object? response, StringSink out) render;
}

/// 往 `ctl` 参数表里补本文件用到的选项（选搜索词复用已有的 `--query` / `-q`）。
void addCtlSrsOptions(ArgParser parser) {
  parser
    ..addOption(
      'srs-profile',
      help: tr(
        'srs decks|notes|stats|conflicts|…：作用于哪一份 profile（uid；只提供一份时可省）',
        'srs decks|notes|stats|conflicts|...: which profile to act on (uid; optional while only one is served)',
      ),
    )
    ..addOption(
      'field',
      help: tr(
        'srs notes / 批量改笔记：只匹配这个字段包含搜索文本的笔记',
        'srs notes / batch edits: only match notes whose this field contains the search text',
      ),
    )
    ..addOption(
      'deck',
      help: tr(
        'srs notes|stats / 批量改笔记：只看这个牌组（全名，含子牌组）',
        'srs notes|stats / batch edits: only this deck (full name, includes sub-decks)',
      ),
    )
    ..addFlag(
      'cards',
      negatable: false,
      help: tr(
        'srs notes：按卡片列出（缺省按笔记）',
        'srs notes: list cards (notes by default)',
      ),
    )
    ..addOption(
      'limit',
      help: tr('srs notes：最多列出几条（缺省 50）', 'srs notes: max rows (default 50)'),
    )
    ..addOption(
      'offset',
      help: tr('srs notes：跳过前几条', 'srs notes: rows to skip'),
    )
    ..addFlag(
      'yes',
      abbr: 'y',
      negatable: false,
      help: tr(
        'srs conflict-keep：确认（这一步不能撤销）',
        'srs conflict-keep: confirm (this cannot be undone)',
      ),
    )
    ..addOption(
      'keep',
      allowed: const <String>['current', 'replaced'],
      help: tr(
        'srs conflict-resolve：current = 确认当前生效的值；replaced = 改回被覆盖的值',
        'srs conflict-resolve: current = confirm the value in effect; replaced = restore the overwritten one',
      ),
    )
    ..addMultiOption(
      'note',
      help: tr(
        '批量改笔记：要改的笔记 id（可重复；与 --query 二选一）',
        'batch edits: note id to edit (repeatable; or use --query)',
      ),
    )
    ..addFlag(
      'dry-run',
      negatable: false,
      help: tr(
        '批量改笔记：只预演（条数、跳过的笔记与改动样例），不写入',
        'batch edits: preview only (counts, skipped notes and sample changes), write nothing',
      ),
    )
    ..addOption(
      'value',
      help: tr(
        'srs set-field：新值（可含 HTML）；省略 = 清空',
        'srs set-field: new value (HTML allowed); omit to clear',
      ),
    )
    ..addOption(
      'in-field',
      help: tr(
        'srs find-replace：只在这个字段里替换（缺省所有字段）',
        'srs find-replace: only replace in this field (all fields by default)',
      ),
    )
    ..addFlag(
      'regex',
      negatable: false,
      help: tr(
        'srs find-replace：<查找> 是正则',
        'srs find-replace: <find> is a regular expression',
      ),
    )
    ..addFlag(
      'ignore-case',
      negatable: false,
      help: tr('srs find-replace：不区分大小写', 'srs find-replace: case-insensitive'),
    );
}

/// `ctl srs help`：这一组动作的完整用法。
String get kCtlSrsDataUsage => tr(
  '''
fushi_server ctl srs <动作> [参数] [--srs-profile <uid>]
  （--srs-profile：作用于哪一份 profile，uid 见 `srs status`；只提供一份时可省）
  decks                                    牌组（父在前）与今天的新卡 / 学习 / 到期数
  notes [搜索...] [--field 字段] [--deck 牌组] [--cards] [--limit n] [--offset n]
                                           搜索笔记 / 卡片（Anki 搜索语法；--field 按字段包含）
  note <笔记 id>                           一条笔记：全部字段、标签、卡片
  stats [--deck 牌组]                      统计：今日、到期、卡片状态、30 天保留率、连续天数
  conflicts                                冲突中心：被扣住的删除、被覆盖的设置 / 标志、待裁决笔记、疑似重复
  conflict-delete <冲突 id>                被扣住的删除：以删除为准（墓碑，内容仍在日志里）
  conflict-keep <冲突 id> --yes            被扣住的删除：保留条目（另一台设备的删除作废，不能撤销）
  conflict-resolve <kind> <entity> <key> --keep current|replaced
                                           被覆盖的设置 / 标志：确认当前值 / 改回被覆盖的值
  merge <保留的笔记 id> <并入的笔记 id...>   合并重复笔记（复习历史合并、空字段补齐、被并入的删除）
  not-duplicate <笔记 id> <笔记 id...>      标记这些笔记不是重复，不再提示合并
  card-type <卡型> (--note <id>... | --query <搜索>) [--dry-run]
                                           批量设卡型：word / sentence / word-and-sentence / click / audio
  set-field <字段名> [--value <值>] (--note <id>... | --query <搜索>) [--dry-run]
                                           批量给一个字段设值（省略 --value = 清空）
  find-replace <查找> <替换为> (--note <id>... | --query <搜索>) [--in-field 字段] [--regex] [--ignore-case] [--dry-run]
                                           批量查找替换字段原文
  批量改笔记的 --query 可再配 --field / --deck 收窄；这里的写入不记撤销，先 --dry-run 预演。''',
  '''
fushi_server ctl srs <action> [args] [--srs-profile <uid>]
  (--srs-profile: which profile to act on, uid from `srs status`; optional while only one is served)
  decks                                    Decks (parents first) with today's new / learning / due counts
  notes [search...] [--field name] [--deck name] [--cards] [--limit n] [--offset n]
                                           Search notes / cards (Anki search syntax; --field = field contains)
  note <note id>                           One note: all fields, tags, cards
  stats [--deck name]                      Statistics: today, due, card states, 30-day retention, streak
  conflicts                                Conflict center: held deletions, overwritten settings / flags, pending notes, likely duplicates
  conflict-delete <conflict id>            Held deletion: delete it (a tombstone; the content stays in the log)
  conflict-keep <conflict id> --yes        Held deletion: keep the item (discards the other device's deletion; cannot be undone)
  conflict-resolve <kind> <entity> <key> --keep current|replaced
                                           Overwritten setting / flag: confirm the current value / restore the overwritten one
  merge <kept note id> <absorbed note id...>  Merge duplicate notes (review history joined, empty fields filled, absorbed notes deleted)
  not-duplicate <note id> <note id...>     Mark these notes as not duplicates; stop suggesting the merge
  card-type <type> (--note <id>... | --query <search>) [--dry-run]
                                           Batch-set the card type: word / sentence / word-and-sentence / click / audio
  set-field <field name> [--value <value>] (--note <id>... | --query <search>) [--dry-run]
                                           Batch-set one field (omit --value to clear it)
  find-replace <find> <replace> (--note <id>... | --query <search>) [--in-field name] [--regex] [--ignore-case] [--dry-run]
                                           Batch find & replace on the raw field text
  For batch edits --query can be narrowed with --field / --deck; writes here keep no undo record, preview with --dry-run first.''',
);

String _seg(String raw) => Uri.encodeComponent(raw);

/// 把 `srs <sub> <args…>` 翻成一个请求；用法不对时写 [err] 并返回 null。
CtlSrsRequest? parseCtlSrsDataAction(
  String sub,
  List<String> args,
  ArgResults command,
  StringSink err,
) {
  CtlSrsRequest? usage(String zh, String en) {
    err.writeln(tr(zh, en));
    err.writeln(
      tr(
        '完整用法: fushi_server ctl srs help',
        'Full usage: fushi_server ctl srs help',
      ),
    );
    return null;
  }

  String? option(String name) {
    final String? value = (command[name] as String?)?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  final String? profile = option('srs-profile');
  Map<String, String> query(Map<String, String> q) => <String, String>{
    ...q,
    'profile': ?profile,
  };
  Map<String, Object?> body(Map<String, Object?> b) => <String, Object?>{
    ...b,
    'profile': ?profile,
  };
  String? arg(int i) =>
      i < args.length && args[i].trim().isNotEmpty ? args[i] : null;

  /// 批量改笔记的目标与预演参数。没给 --note 也没给搜索条件时报用法错（不允许改全库）。
  Map<String, Object?>? batchTargets() {
    final List<String> notes = <String>[
      for (final String id in command['note'] as List<String>)
        if (id.trim().isNotEmpty) id.trim(),
    ];
    final String? q = option('query');
    final String? field = option('field');
    final String? deck = option('deck');
    if (notes.isEmpty && q == null && deck == null) {
      usage(
        '用 --note <id> 或 --query <搜索> / --deck 指定要改的笔记',
        'Select the notes to edit with --note <id> or --query <search> / --deck',
      );
      return null;
    }
    if (field != null && q == null) {
      usage('--field 需要和 --query 一起用', '--field needs --query');
      return null;
    }
    return <String, Object?>{
      if (notes.isNotEmpty) 'notes': notes,
      'q': ?q,
      'field': ?field,
      'deck': ?deck,
      if (command['dry-run'] as bool) 'dryRun': true,
    };
  }

  CtlSrsRequest batch(String wire, Map<String, Object?> params) =>
      CtlSrsRequest(
        'POST',
        '$_root/notes/batch/$wire',
        body: body(params),
        render: _renderNoteBatch,
      );

  switch (sub) {
    case 'help':
      err.writeln(kCtlSrsDataUsage);
      return null;
    case 'decks':
      return CtlSrsRequest(
        'GET',
        '$_root/decks',
        query: query(const <String, String>{}),
        render: _renderDecks,
      );
    case 'notes':
      final String text = args.join(' ').trim();
      final String? field = option('field');
      if (field != null && text.isEmpty) {
        return usage('--field 需要搜索文本', '--field needs search text');
      }
      final String? limit = option('limit');
      final String? offset = option('offset');
      if (limit != null && (int.tryParse(limit) ?? 0) <= 0) {
        return usage(
          '--limit 必须是大于 0 的整数',
          '--limit must be an integer above 0',
        );
      }
      if (offset != null && (int.tryParse(offset) ?? -1) < 0) {
        return usage(
          '--offset 必须是不小于 0 的整数',
          '--offset must be a non-negative integer',
        );
      }
      return CtlSrsRequest(
        'GET',
        '$_root/notes',
        query: query(<String, String>{
          if (text.isNotEmpty) 'q': text,
          'field': ?field,
          'deck': ?option('deck'),
          'mode': command['cards'] as bool ? 'cards' : 'notes',
          'limit': ?limit,
          'offset': ?offset,
        }),
        render: _renderNotes,
      );
    case 'note':
      final String? id = arg(0);
      if (id == null) return usage('srs note <笔记 id>', 'srs note <note id>');
      return CtlSrsRequest(
        'GET',
        '$_root/notes/${_seg(id)}',
        query: query(const <String, String>{}),
        render: _renderNote,
      );
    case 'stats':
      return CtlSrsRequest(
        'GET',
        '$_root/stats',
        query: query(<String, String>{'deck': ?option('deck')}),
        render: _renderStats,
      );
    case 'conflicts':
      return CtlSrsRequest(
        'GET',
        '$_root/conflicts',
        query: query(const <String, String>{}),
        render: _renderConflicts,
      );
    case 'conflict-delete':
      final String? id = arg(0);
      if (id == null) {
        return usage(
          'srs conflict-delete <冲突 id>',
          'srs conflict-delete <conflict id>',
        );
      }
      return CtlSrsRequest(
        'POST',
        '$_root/conflicts/held/${_seg(id)}/delete',
        body: body(const <String, Object?>{}),
        render: _renderHeld,
      );
    case 'conflict-keep':
      final String? id = arg(0);
      if (id == null) {
        return usage(
          'srs conflict-keep <冲突 id> --yes',
          'srs conflict-keep <conflict id> --yes',
        );
      }
      if (!(command['yes'] as bool)) {
        return usage(
          '「保留」会让另一台设备的删除作废、冲突不再出现，确认请加 --yes',
          'Keeping discards the other device\'s deletion and the conflict will not come back; add --yes to confirm',
        );
      }
      return CtlSrsRequest(
        'POST',
        '$_root/conflicts/held/${_seg(id)}/keep',
        body: body(const <String, Object?>{'confirm': true}),
        render: _renderHeld,
      );
    case 'conflict-resolve':
      final String? kind = arg(0);
      final String? entity = arg(1);
      final String? key = arg(2);
      final String? keep = option('keep');
      if (kind == null || entity == null || key == null || keep == null) {
        return usage(
          'srs conflict-resolve <kind> <entity> <key> --keep current|replaced',
          'srs conflict-resolve <kind> <entity> <key> --keep current|replaced',
        );
      }
      if (!_entityKinds.contains(kind)) {
        return usage(
          'kind 只能是 ${_entityKinds.join(' / ')}：$kind',
          'kind must be one of ${_entityKinds.join(' / ')}: $kind',
        );
      }
      return CtlSrsRequest(
        'POST',
        '$_root/conflicts/fields/resolve',
        body: body(<String, Object?>{
          'kind': kind,
          'entity': entity,
          'key': key,
          'keep': keep,
        }),
        render: _renderResolve,
      );
    case 'merge':
      final String? keep = arg(0);
      final List<String> absorb = <String>[
        for (final String id in args.skip(1))
          if (id.trim().isNotEmpty && id.trim() != keep) id.trim(),
      ];
      if (keep == null || absorb.isEmpty) {
        return usage(
          'srs merge <保留的笔记 id> <并入的笔记 id...>',
          'srs merge <kept note id> <absorbed note id...>',
        );
      }
      return CtlSrsRequest(
        'POST',
        '$_root/duplicates/merge',
        body: body(<String, Object?>{'keep': keep, 'absorb': absorb}),
        render: _renderMerge,
      );
    case 'not-duplicate':
      final List<String> notes = <String>{
        for (final String id in args)
          if (id.trim().isNotEmpty) id.trim(),
      }.toList();
      if (notes.length < 2) {
        return usage(
          'srs not-duplicate <笔记 id> <笔记 id...>（至少两条）',
          'srs not-duplicate <note id> <note id...> (at least two)',
        );
      }
      return CtlSrsRequest(
        'POST',
        '$_root/duplicates/dismiss',
        body: body(<String, Object?>{'notes': notes}),
        render: _renderDismiss,
      );
    case 'card-type':
      final String? type = arg(0);
      if (type == null || !_cardTypes.contains(type)) {
        return usage(
          'srs card-type <${_cardTypes.join('|')}> (--note <id>... | --query <搜索>) [--dry-run]',
          'srs card-type <${_cardTypes.join('|')}> (--note <id>... | --query <search>) [--dry-run]',
        );
      }
      final Map<String, Object?>? targets = batchTargets();
      return targets == null
          ? null
          : batch('card-type', <String, Object?>{'type': type, ...targets});
    case 'set-field':
      final String? field = arg(0);
      if (field == null) {
        return usage(
          'srs set-field <字段名> [--value <值>] (--note <id>... | --query <搜索>) [--dry-run]',
          'srs set-field <field name> [--value <value>] (--note <id>... | --query <search>) [--dry-run]',
        );
      }
      final Map<String, Object?>? targets = batchTargets();
      return targets == null
          ? null
          : batch('set-field', <String, Object?>{
              'targetField': field,
              // 原样传（不 trim）：值里的空白有意义。
              'value': command['value'] as String? ?? '',
              ...targets,
            });
    case 'find-replace':
      // 两个位置参数都按原样取（替换成空串写 ""）。
      if (args.length < 2 || args[0].isEmpty) {
        return usage(
          'srs find-replace <查找> <替换为> (--note <id>... | --query <搜索>) [--in-field 字段] [--regex] [--ignore-case] [--dry-run]（替换成空串写 ""）',
          'srs find-replace <find> <replace> (--note <id>... | --query <search>) [--in-field name] [--regex] [--ignore-case] [--dry-run] (use "" to replace with nothing)',
        );
      }
      final Map<String, Object?>? targets = batchTargets();
      return targets == null
          ? null
          : batch('find-replace', <String, Object?>{
              'find': args[0],
              'replace': args[1],
              'targetField': ?option('in-field'),
              if (command['regex'] as bool) 'regex': true,
              if (command['ignore-case'] as bool) 'caseSensitive': false,
              ...targets,
            });
  }
  err.writeln(kCtlSrsDataUsage);
  return null;
}

// ── 输出 ───────────────────────────────────────────────────────────────

void _json(Object? response, StringSink out) =>
    out.writeln(const JsonEncoder.withIndent('  ').convert(response));

String _pct(Object? v) => v is num ? '${(v * 100).toStringAsFixed(1)}%' : '—';

void _renderDecks(Object? response, StringSink out) => out.writeln(
  renderCtlTable(
    response,
    <(String, String)>[
      (tr('牌组', 'Deck'), 'name'),
      (tr('新', 'New'), 'new'),
      (tr('学习', 'Learning'), 'learn'),
      (tr('到期', 'Due'), 'review'),
      (tr('总卡数', 'Cards'), 'total'),
      ('id', 'id'),
    ],
    listKey: 'decks',
    empty: tr('（没有牌组）', '(no decks)'),
  ),
);

void _renderNotes(Object? response, StringSink out) {
  if (response is! Map) return _json(response, out);
  final bool cards = response['mode'] == 'cards';
  final Object? items = response['items'];
  final int shown = items is List ? items.length : 0;
  final num total = response['total'] as num? ?? 0;
  out.writeln(
    shown < total
        ? tr('共 $total 条（显示 $shown 条）', '$total in total ($shown shown)')
        : tr('共 $total 条', '$total in total'),
  );
  out.writeln(
    renderCtlTable(
      response,
      cards
          ? <(String, String)>[
              (tr('排序字段', 'Sort field'), 'sortField'),
              (tr('牌组', 'Deck'), 'deck'),
              (tr('模板', 'Template'), 'template'),
              (tr('队列', 'Queue'), 'queue'),
              (tr('到期(天)', 'Due (days)'), 'dueInDays'),
              (tr('卡片 id', 'Card id'), 'cardId'),
              (tr('笔记 id', 'Note id'), 'noteId'),
            ]
          : <(String, String)>[
              (tr('排序字段', 'Sort field'), 'sortField'),
              (tr('笔记类型', 'Note type'), 'noteType'),
              (tr('牌组', 'Deck'), 'deck'),
              (tr('卡数', 'Cards'), 'cards'),
              (tr('标签', 'Tags'), 'tags'),
              (tr('笔记 id', 'Note id'), 'noteId'),
            ],
      listKey: 'items',
      empty: cards
          ? tr('（没有匹配的卡片）', '(no matching cards)')
          : tr('（没有匹配的笔记）', '(no matching notes)'),
    ),
  );
}

void _renderNote(Object? response, StringSink out) {
  if (response is! Map) return _json(response, out);
  out.writeln('${response['id']} · ${response['noteType']}');
  final Object? tags = response['tags'];
  final List<String> marks = <String>[
    if (response['deletedAt'] != null) tr('已删除', 'deleted'),
    if (response['pendingDecision'] == true)
      tr('有待裁决的冲突', 'has a conflict waiting for a decision'),
    if (tags is List && tags.isNotEmpty)
      tr('标签：${tags.join(', ')}', 'tags: ${tags.join(', ')}'),
  ];
  if (marks.isNotEmpty) out.writeln(marks.join(' · '));
  final Object? fields = response['fields'];
  if (fields is Map) {
    for (final MapEntry<Object?, Object?> f in fields.entries) {
      out.writeln('  ${f.key}: ${'${f.value}'.replaceAll('\n', ' ')}');
    }
  }
  out.writeln(
    renderCtlTable(
      response,
      <(String, String)>[
        (tr('卡片 id', 'Card id'), 'id'),
        (tr('牌组', 'Deck'), 'deck'),
        (tr('队列', 'Queue'), 'queue'),
        (tr('间隔(天)', 'Interval (days)'), 'intervalDays'),
        (tr('复习', 'Reviews'), 'reps'),
        (tr('遗忘', 'Lapses'), 'lapses'),
      ],
      listKey: 'cards',
      empty: tr('（没有可见卡片）', '(no visible cards)'),
    ),
  );
}

void _renderStats(Object? response, StringSink out) {
  if (response is! Map) return _json(response, out);
  final Map<Object?, Object?> today = response['today'] as Map? ?? const {};
  final Map<Object?, Object?> due = response['due'] as Map? ?? const {};
  final Map<Object?, Object?> cards = response['cards'] as Map? ?? const {};
  final Map<Object?, Object?> ret =
      response['retention30d'] as Map? ?? const {};
  final Map<Object?, Object?> streak = response['streak'] as Map? ?? const {};
  if (response['deck'] != null) {
    out.writeln(tr('牌组：${response['deck']}', 'Deck: ${response['deck']}'));
  }
  out
    ..writeln(
      tr(
        '今天：复习 ${today['reviews']} 次 · 答对率 ${_pct(today['correctRate'])} · '
            '重来 ${today['again']} / 困难 ${today['hard']} / 良好 ${today['good']} / 简单 ${today['easy']}',
        'Today: ${today['reviews']} reviews · ${_pct(today['correctRate'])} correct · '
            'again ${today['again']} / hard ${today['hard']} / good ${today['good']} / easy ${today['easy']}',
      ),
    )
    ..writeln(
      tr(
        '到期：今天 ${due['today']} · 明天 ${due['tomorrow']} · 逾期 ${due['overdue']} · 7 天内 ${due['next7Days']}',
        'Due: today ${due['today']} · tomorrow ${due['tomorrow']} · overdue ${due['overdue']} · next 7 days ${due['next7Days']}',
      ),
    )
    ..writeln(
      tr(
        '卡片：新 ${cards['new']} · 学习中 ${cards['learning']} · 重学 ${cards['relearning']} · '
            '年轻 ${cards['young']} · 成熟 ${cards['mature']} · 暂停 ${cards['suspended']} · 共 ${cards['total']}',
        'Cards: new ${cards['new']} · learning ${cards['learning']} · relearning ${cards['relearning']} · '
            'young ${cards['young']} · mature ${cards['mature']} · suspended ${cards['suspended']} · total ${cards['total']}',
      ),
    )
    ..writeln(
      tr(
        '30 天真实保留率：${_pct(ret['rate'])}（年轻 ${_pct(ret['young'])} · 成熟 ${_pct(ret['mature'])} · ${ret['reviews']} 次）'
            ' · 期望保留率 ${_pct(response['desiredRetention'])}',
        '30-day true retention: ${_pct(ret['rate'])} (young ${_pct(ret['young'])} · mature ${_pct(ret['mature'])} · ${ret['reviews']} reviews)'
            ' · desired retention ${_pct(response['desiredRetention'])}',
      ),
    )
    ..writeln(
      tr(
        '连续学习：${streak['current']} 天（最长 ${streak['longest']} 天）',
        'Streak: ${streak['current']} days (longest ${streak['longest']})',
      ),
    );
}

void _renderConflicts(Object? response, StringSink out) {
  if (response is! Map) return _json(response, out);
  final List<String> parts = <String>[];
  final Object? held = response['held'];
  if (held is List && held.isNotEmpty) {
    parts.add(
      '${tr('被扣住的删除（srs conflict-delete / conflict-keep <id>）：', 'Held deletions (srs conflict-delete / conflict-keep <id>):')}\n'
      '${renderCtlTable(held, <(String, String)>[(tr('条目', 'Item'), 'label'), (tr('类型', 'Kind'), 'kind'), (tr('并发修改', 'Concurrent edits'), 'others'), ('id', 'id')])}',
    );
  }
  final Object? fields = response['fields'];
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
      '${tr('被覆盖的设置 / 标志（srs conflict-resolve <kind> <entity> <key> --keep current|replaced）：', 'Overwritten settings / flags (srs conflict-resolve <kind> <entity> <key> --keep current|replaced):')}\n'
      '${renderCtlTable(rows, <(String, String)>[(tr('条目', 'Item'), 'label'), (tr('键', 'Key'), 'key'), (tr('当前', 'Current'), 'current'), (tr('被覆盖', 'Replaced'), 'replaced'), (tr('参数', 'Arguments'), 'target')])}',
    );
  }
  final Object? pending = response['pendingNotes'];
  if (pending is List && pending.isNotEmpty) {
    parts.add(
      '${tr('待裁决的笔记（在 app 的笔记编辑页里处理）：', 'Notes waiting for a decision (resolve them in the app\'s note editor):')}\n'
      '${renderCtlTable(pending, <(String, String)>[(tr('笔记', 'Note'), 'label'), (tr('原因', 'Reason'), 'reason'), ('id', 'id')])}',
    );
  }
  final Object? dups = response['duplicates'];
  if (dups is List && dups.isNotEmpty) {
    final StringBuffer text = StringBuffer(
      tr(
        '疑似重复（srs merge <保留 id> <并入 id...> / srs not-duplicate <id...>）：',
        'Likely duplicates (srs merge <kept id> <absorbed id...> / srs not-duplicate <id...>):',
      ),
    );
    for (final Object? g in dups) {
      if (g is! Map || g['notes'] is! List) continue;
      text.write('\n- ');
      text.write(
        <String>[
          for (final Object? n in g['notes']! as List<Object?>)
            if (n is Map)
              tr(
                '${n['label']}（${n['id']}，复习 ${n['reviews']} 次）',
                '${n['label']} (${n['id']}, ${n['reviews']} reviews)',
              ),
        ].join(' / '),
      );
    }
    parts.add(text.toString());
  }
  out.writeln(parts.isEmpty ? tr('没有冲突', 'No conflicts') : parts.join('\n\n'));
}

void _renderHeld(Object? response, StringSink out) {
  if (response is! Map) return _json(response, out);
  final String what = '${response['entityKind']} ${response['entity']}';
  out.writeln(
    response['deleted'] == true
        ? tr('已按删除处理：$what', 'Deleted: $what')
        : tr('已保留：$what', 'Kept: $what'),
  );
}

void _renderResolve(Object? response, StringSink out) {
  if (response is! Map) return _json(response, out);
  final String what =
      '${response['kind']} ${response['entity']} ${response['key']} = ${response['value']}';
  out.writeln(
    response['keep'] == 'replaced'
        ? tr('$what（已改回被覆盖的值）', '$what (restored the overwritten value)')
        : tr('$what（已确认当前值）', '$what (confirmed the current value)'),
  );
}

void _renderMerge(Object? response, StringSink out) {
  if (response is! Map) return _json(response, out);
  final Object? absorbed = response['absorbed'];
  final String ids = absorbed is List ? absorbed.join(', ') : '$absorbed';
  final num unmatched = response['unmatchedCards'] as num? ?? 0;
  out.writeln(
    tr(
      '已把 $ids 并进 ${response['keep']}：${response['linkedCards']} 张卡的复习历史已合并'
          '${unmatched > 0 ? '，$unmatched 张卡没有对应模板（随笔记删除，历史仍在时间线里）' : ''}',
      'Merged $ids into ${response['keep']}: review history of ${response['linkedCards']} card(s) joined'
          '${unmatched > 0 ? ', $unmatched card(s) had no matching template (deleted with the note; their history stays in the timeline)' : ''}',
    ),
  );
}

void _renderDismiss(Object? response, StringSink out) {
  if (response is! Map) return _json(response, out);
  final Object? notes = response['dismissed'];
  final String ids = notes is List ? notes.join(', ') : '$notes';
  out.writeln(tr('已标记不是重复：$ids', 'Marked as not duplicates: $ids'));
}

void _renderNoteBatch(Object? response, StringSink out) {
  if (response is! Map) return _json(response, out);
  final StringBuffer text = StringBuffer(
    response['dryRun'] == true
        ? tr(
            '预演：将修改 ${response['notes']} 条笔记（${response['fieldChanges']} 个字段）',
            'Preview: would change ${response['notes']} note(s) (${response['fieldChanges']} field(s))',
          )
        : tr(
            '已修改 ${response['notes']} 条笔记（${response['fieldChanges']} 个字段）',
            'Changed ${response['notes']} note(s) (${response['fieldChanges']} field(s))',
          ),
  );
  final num conflicts = response['conflicts'] as num? ?? 0;
  if (conflicts > 0) {
    text.write(
      tr(
        '，$conflicts 条笔记在此期间被别处改过、保留未动',
        ', $conflicts note(s) were edited elsewhere meanwhile and left alone',
      ),
    );
  }
  final num skipped = response['skipped'] as num? ?? 0;
  if (skipped > 0) {
    text.write(
      tr(
        '，$skipped 条笔记的类型没有所需字段、已跳过',
        ', $skipped note(s) skipped (their type lacks the field)',
      ),
    );
  }
  final num unchanged = response['unchanged'] as num? ?? 0;
  if (unchanged > 0) {
    text.write(
      tr('，$unchanged 条本来就是目标值', ', $unchanged already had the target value'),
    );
  }
  final Object? sample = response['sample'];
  if (sample is List && sample.isNotEmpty) {
    text.write(tr('\n样例：', '\nSample:'));
    for (final Object? row in sample) {
      if (row is! Map) continue;
      text.write(
        '\n  ${row['note']}  ${row['field']}: '
        '${jsonEncode(row['before'])} → ${jsonEncode(row['after'])}',
      );
    }
  }
  out.writeln(text.toString());
}
