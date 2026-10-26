import 'package:args/args.dart';

import '../ctl_commands.dart';

/// `fushi_cli book …`：书的元数据与封面刮削（app 侧路由见 `fushi/lib/src/ops/ctl_book_metadata_routes.dart`）。
///
/// 与书架卡「在线刮削封面」弹窗同一套源（Bangumi 书籍条目 / DLsite 音声·漫画·小说）：
/// `search` 搜候选、`get` 按 id 看详情、`apply` 把选中的候选写回某本书（默认只换封面，
/// `--title` / `--author` 一并写显示名与作者）。条目键与 `library ls` 一致（`book:` / `srt:`）。
const List<CtlCommandGroup> bookMetadataCommandGroups = <CtlCommandGroup>[
  CtlCommandGroup(
    name: 'book',
    summary: '书的在线元数据与封面刮削（Bangumi / DLsite）',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'search',
        summary: '搜候选：书名 / Bangumi 条目 URL / DLsite 编号（--source dlsite）',
        usage: '<query...>',
        configure: _configureSource,
        build: _buildSearch,
        render: _renderSearch,
      ),
      CtlCommandSpec(
        name: 'get',
        summary: '按源内 id 取一个候选的详情',
        usage: '<bangumi|dlsite> <id>',
        build: _buildGet,
        render: _renderCandidate,
      ),
      CtlCommandSpec(
        name: 'apply',
        summary: '把候选写回一本书：默认换封面，--title / --author 一并写显示名与作者',
        usage: '<key> <id>',
        configure: _configureApply,
        build: _buildApply,
        render: _renderApply,
      ),
    ],
  ),
];

const String _search = '/api/admin/book/scrape';
const String _items = '/api/admin/book/items';

/// `--source` 的值域。
const List<String> kBookScrapeSources = <String>['bangumi', 'dlsite'];

void _configureSource(ArgParser parser) {
  parser.addOption('source', help: '刮削源：bangumi（默认）| dlsite');
}

String? _sourceOption(CtlCommandContext context) {
  final String? source = context.option('source')?.toLowerCase();
  if (source != null && !kBookScrapeSources.contains(source)) {
    throw CtlUsageError(
      '--source 只能是 ${kBookScrapeSources.join(' | ')}：$source',
    );
  }
  return source;
}

CtlRequestSpec _buildSearch(CtlCommandContext context) {
  final String query = context.joinedRest(0, 'query');
  final String? source = _sourceOption(context);
  return CtlRequestSpec.get(
    _search,
    query: <String, String>{'query': query, 'source': ?source},
  );
}

CtlRequestSpec _buildGet(CtlCommandContext context) {
  final String source = context.positional(0, 'source').toLowerCase();
  if (!kBookScrapeSources.contains(source)) {
    throw CtlUsageError('源只能是 ${kBookScrapeSources.join(' | ')}：$source');
  }
  final String id = context.positional(1, 'id').trim();
  return CtlRequestSpec.get(
    '$_search/${Uri.encodeComponent(source)}/${Uri.encodeComponent(id)}',
  );
}

void _configureApply(ArgParser parser) {
  _configureSource(parser);
  parser
    ..addFlag('title', negatable: false, help: '同时把候选标题写成显示名（不改原始书名）')
    ..addFlag('author', negatable: false, help: '同时写作者')
    ..addFlag('cover', defaultsTo: true, help: '换封面（--no-cover 只写文字字段）');
}

CtlRequestSpec _buildApply(CtlCommandContext context) {
  final String key = context.positional(0, 'key').trim();
  if (!RegExp(r'^(book|srt):.+').hasMatch(key)) {
    throw CtlUsageError('条目键要写成 book:<bookKey> 或 srt:<uid>（见 library ls）：$key');
  }
  final String id = context.positional(1, 'id').trim();
  final List<String> fields = <String>[
    if (context.flag('cover')) 'cover',
    if (context.flag('title')) 'title',
    if (context.flag('author')) 'author',
  ];
  if (fields.isEmpty) {
    throw const CtlUsageError('--no-cover 时至少要给 --title 或 --author');
  }
  final String? source = _sourceOption(context);
  return CtlRequestSpec.post(
    '$_items/${Uri.encodeComponent(key)}/scrape',
    body: <String, Object?>{'id': id, 'source': ?source, 'fields': fields},
  );
}

String _renderSearch(Object? data) => renderCtlTable(
  data,
  const <(String, String)>[
    ('源', 'source'),
    ('id', 'id'),
    ('标题', 'title'),
    ('作者', 'author'),
    ('年份', 'year'),
  ],
  listKey: 'candidates',
  empty: '没有匹配的候选',
);

String _renderCandidate(Object? data) {
  if (data is! Map) return '完成';
  final StringBuffer out = StringBuffer()
    ..writeln('${data['title']}  [${data['source']} ${data['id']}]');
  for (final (String label, String field) in const <(String, String)>[
    ('原名', 'originalTitle'),
    ('作者', 'author'),
    ('年份', 'year'),
    ('封面', 'coverUrl'),
    ('条目', 'detailUrl'),
    ('简介', 'summary'),
  ]) {
    if (data[field] case final Object value) out.writeln('$label：$value');
  }
  if (data['adult'] == true) out.writeln('R18');
  return out.toString().trimRight();
}

/// 字段名 → 中文。
String describeBookMetadataField(String field) => switch (field) {
  'cover' => '封面',
  'title' => '显示名',
  'author' => '作者',
  _ => field,
};

String _renderApply(Object? data) {
  if (data is! Map) return '完成';
  final List<Object?> applied = data['applied'] is List
      ? data['applied']! as List<Object?>
      : const <Object?>[];
  final List<Object?> requested = data['requested'] is List
      ? data['requested']! as List<Object?>
      : const <Object?>[];
  final Object? candidate = data['candidate'];
  final String title = candidate is Map ? '${candidate['title']}' : '';
  final StringBuffer out = StringBuffer()
    ..write(
      '${data['key']} ← $title · 已写回：'
      '${applied.map((Object? f) => describeBookMetadataField('$f')).join('、')}',
    );
  final List<Object?> skipped = <Object?>[
    for (final Object? f in requested)
      if (!applied.contains(f)) f,
  ];
  if (skipped.isNotEmpty) {
    out.write(
      '\n未写回：${skipped.map((Object? f) => describeBookMetadataField('$f')).join('、')}'
      '（图片无法解码 / 候选没有该字段 / 该书不支持）',
    );
  }
  return out.toString();
}
