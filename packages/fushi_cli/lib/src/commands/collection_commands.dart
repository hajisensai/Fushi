import 'package:args/args.dart';

import '../ctl_commands.dart';

/// `collection` 组的定序子命令：手动定序 `order`、一键排序 `sort`（含 AI）。
///
/// 只是 `shelf_commands.dart` 里**唯一**那个 `collection` 组的一部分（由它展开进
/// 组的 `commands`），不单独注册命令组——同名组注册两次会让 CLI 解析器在启动时
/// 撞名。app 侧路由见 `fushi/lib/src/ops/ctl_collection_routes.dart`，
/// 与合集的 ls / get / add / remove 同在 `/api/admin/library/collections` 下。
///
/// 成员键与 `collection get` 列出的一致（`book:` / `srt:` / `video:` / `game:` 前缀
/// 加 id）；在本合集内唯一时也可只写 id。
const List<CtlCommandSpec> collectionOrderCommandSpecs = <CtlCommandSpec>[
  CtlCommandSpec(
    name: 'order',
    summary: '手动定序：按给出的成员键顺序重排（没列出的成员留在原位）',
    usage: '<id> <key...>',
    build: _buildOrder,
    render: _renderOrdered,
  ),
  CtlCommandSpec(
    name: 'sort',
    summary: '一键排序：--by title | imported | ai（--dry-run 只打印建议序）',
    usage: '<id>',
    configure: _configureSort,
    build: _buildSort,
    render: _renderSort,
  ),
];

const String _root = '/api/admin/library/collections';

/// `--by` 的值域。
const List<String> kCollectionSortModes = <String>['title', 'imported', 'ai'];

String _id(CtlCommandContext context) {
  final String raw = context.positional(0, 'id');
  if (!RegExp(r'^[1-9]\d*$').hasMatch(raw)) {
    throw CtlUsageError('合集 id 必须是正整数：$raw');
  }
  return raw;
}

CtlRequestSpec _buildOrder(CtlCommandContext context) {
  final String id = _id(context);
  final List<String> keys = <String>[
    for (final String key in context.rest.skip(1))
      if (key.trim().isNotEmpty) key.trim(),
  ];
  if (keys.isEmpty) throw const CtlUsageError('缺少参数 <key...>');
  return CtlRequestSpec.put(
    '$_root/$id/order',
    body: <String, Object?>{'keys': keys},
  );
}

/// `order` 回的是合集详情（与 `collection get` 同形）：打印新顺序。
String _renderOrdered(Object? data) {
  final String table = renderCtlTable(
    data,
    const <(String, String)>[('键', 'key'), ('标题', 'title')],
    listKey: 'items',
    empty: '合集没有成员',
  );
  if (data is! Map) return table;
  return '#${data['id']} ${data['name']} · 已按给出的顺序重排\n$table';
}

void _configureSort(ArgParser parser) {
  parser
    ..addOption(
      'by',
      help: '排序依据：title（名称 natural）| imported（导入时间）| ai（规则判不出的成员交 AI 定位）',
    )
    ..addFlag('dry-run', negatable: false, help: '只打印建议序，不落盘');
}

CtlRequestSpec _buildSort(CtlCommandContext context) {
  final String id = _id(context);
  final String? by = context.option('by')?.toLowerCase();
  if (by == null) throw const CtlUsageError('缺少 --by');
  if (!kCollectionSortModes.contains(by)) {
    throw CtlUsageError('--by 只能是 ${kCollectionSortModes.join(' | ')}：$by');
  }
  return CtlRequestSpec.post(
    '$_root/$id/sort',
    body: <String, Object?>{
      'by': by,
      if (context.flag('dry-run')) 'dryRun': true,
    },
  );
}

/// 结论状态（app 侧 `CollectionAiOrderStatus` 名 + 规则排序的 `sorted`）→ 一句话。
String describeCollectionSortStatus(String? status) => switch (status) {
  'sorted' => '已按规则排序',
  'aiOrdered' => '已按 AI 建议排序',
  'ruleOrdered' => '集号 / 卷号已能确定顺序，按规则排序（未问 AI）',
  'noProvider' => '「合集排序」没有指派 AI 提供商（设置 › 模型 › LLM）',
  'failed' => 'AI 请求失败，顺序未改',
  'invalidReply' => 'AI 回复没通过校验，顺序未改',
  'unknown' => 'AI 不认识这部作品，联网资料也没查到，顺序未改',
  'tooLarge' => '合集太大，不做 AI 排序',
  'tooFew' => '成员不足两个，无需排序',
  _ => status ?? '完成',
};

String _renderSort(Object? data) {
  if (data is! Map) return '完成';
  final StringBuffer out = StringBuffer()
    ..write(
      '${data['id']} · ${describeCollectionSortStatus('${data['status']}')}',
    );
  if (data['failure'] case final String failure) out.write('（$failure）');
  final bool dryRun = data['dryRun'] == true;
  final bool changed = data['changed'] == true;
  out.write(
    dryRun
        ? (changed ? ' · 建议序如下（未落盘）' : ' · 与当前顺序相同（未落盘）')
        : (data['persisted'] == true ? (changed ? ' · 已落盘' : ' · 顺序未变') : ''),
  );
  final Object? order = data['order'];
  if (order is List && order.isNotEmpty) {
    final List<Map<String, Object?>> rows = <Map<String, Object?>>[
      for (int i = 0; i < order.length; i++)
        if (order[i] case final Map<Object?, Object?> row)
          <String, Object?>{
            'index': i,
            'key': row['key'],
            'title': row['title'],
            'ai': row['ambiguous'] == true ? '*' : '',
          },
    ];
    out
      ..writeln()
      ..write(
        renderCtlTable(rows, const <(String, String)>[
          ('序', 'index'),
          ('AI', 'ai'),
          ('键', 'key'),
          ('标题', 'title'),
        ]),
      );
  }
  return out.toString();
}
