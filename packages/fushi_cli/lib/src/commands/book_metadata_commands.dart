import 'package:args/args.dart';

import '../ctl_commands.dart';

/// `fushi_cli book …`：书的元数据与封面刮削（app 侧路由见 `fushi/lib/src/ops/ctl_book_metadata_routes.dart`）。
///
/// 与书架卡「在线刮削封面」弹窗同一套源（Bangumi 书籍条目 / DLsite 音声·漫画·小说 /
/// MangaBaka 漫画·轻小说系列（数据 CC BY-NC-SA 4.0，展示处须署名）/ AniList 轻小说 /
/// openBD（只按 ISBN）/ NDL Search / 楽天ブックス（要先在 app 设置里填凭据））：
/// `search` 搜候选、`get` 按 id 看详情、`apply` 把选中的候选写回某本书（默认换封面并写条目资料，
/// `--title` / `--author` 一并写显示名与作者）；`art` / `art-clear` / `art-remove` 刮 / 清合集
/// 各卷封面与横幅（与封面 override 分开存）。条目键与 `library ls` 一致（`book:` / `srt:`）。

const List<CtlCommandGroup> bookMetadataCommandGroups = <CtlCommandGroup>[
  CtlCommandGroup(
    name: 'book',
    summary:
        '书的在线元数据与封面刮削（Bangumi / DLsite / MangaBaka / AniList / openBD / NDL / 楽天）',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'search',
        summary:
            '搜候选：书名 / Bangumi 条目 URL / DLsite 编号（--source dlsite）/ '
            'ISBN（--source openbd|ndl|rakuten）',
        usage: '<query...>',
        configure: _configureSearch,
        build: _buildSearch,
        render: _renderSearch,
      ),
      CtlCommandSpec(
        name: 'get',
        summary: '按源内 id 取一个候选的详情',
        usage: '<bangumi|dlsite|mangabaka|anilist|openbd|ndl|rakuten> <id>',
        build: _buildGet,
        render: _renderCandidate,
      ),
      CtlCommandSpec(
        name: 'volumes',
        summary: '列 MangaBaka 系列的日文每卷封面',
        usage: '<mangabakaId>',
        build: _buildVolumes,
        render: _renderVolumes,
      ),
      CtlCommandSpec(
        name: 'apply',
        summary: '把候选写回一本书：默认换封面 + 条目资料，--title / --author 一并写显示名与作者',
        usage: '<key> <id>',
        configure: _configureApply,
        build: _buildApply,
        render: _renderApply,
      ),
      CtlCommandSpec(
        name: 'art',
        summary: '给合集里的书刮各卷封面与横幅（MangaBaka 优先，Bangumi 单行本兜底）',
        usage: '<collectionId>',
        configure: _configureArt,
        build: _buildArt,
        render: _renderArt,
      ),
      CtlCommandSpec(
        name: 'art-clear',
        summary: '清除合集各书已获取的封面（不动自定义封面）',
        usage: '<collectionId>',
        build: _buildArtClear,
        render: _renderArtRemoved,
      ),
      CtlCommandSpec(
        name: 'art-remove',
        summary: '清除一本书已获取的封面',
        usage: '<book:key>',
        build: _buildArtRemove,
        render: _renderArtRemoved,
      ),
    ],
  ),
];

const String _search = '/api/admin/book/scrape';
const String _items = '/api/admin/book/items';

/// `--source` 的值域。
const List<String> kBookScrapeSources = <String>[
  'bangumi',
  'dlsite',
  'mangabaka',
  'anilist',
  'openbd',
  'ndl',
  'rakuten',
];

const String _collections = '/api/admin/book/collections';

void _configureSource(ArgParser parser) {
  parser.addOption(
    'source',
    help:
        '刮削源：bangumi（默认）| dlsite | mangabaka | anilist（轻小说）| openbd（只按 ISBN）'
        '| ndl（国立国会図書館）| rakuten（楽天ブックス，需先在 app 设置里填凭据）',
  );
}

void _configureSearch(ArgParser parser) {
  _configureSource(parser);
  parser.addFlag(
    'nsfw',
    negatable: false,
    help: '也列出源标成 NSFW（成人向）的候选；默认不列，只报藏了几条',
  );
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
  final bool nsfw = context.flag('nsfw');
  return CtlRequestSpec.get(
    _search,
    query: <String, String>{
      'query': query,
      'source': ?source,
      if (nsfw) 'nsfw': 'true',
    },
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
    ..addFlag('cover', defaultsTo: true, help: '换封面（--no-cover 只写文字字段）')
    ..addFlag(
      'details',
      defaultsTo: true,
      help: '写条目资料：简介 / 日期 / 评分 / 类型 / 源给的横版背景（--no-details 不写）',
    )
    ..addOption('volume', help: '只对 mangabaka：用这一卷的日文封面（见 book volumes）');
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
    if (context.flag('details')) 'details',
  ];
  if (fields.isEmpty) {
    throw const CtlUsageError(
      '--no-cover --no-details 时至少要给 --title 或 --author',
    );
  }
  final String? source = _sourceOption(context);
  final String? volumeRaw = context.option('volume');
  final num? volume = volumeRaw == null ? null : num.tryParse(volumeRaw);
  if (volumeRaw != null && volume == null) {
    throw CtlUsageError('--volume 要是数字：$volumeRaw');
  }
  if (volume != null && source != 'mangabaka') {
    throw const CtlUsageError('--volume 只能配 --source mangabaka');
  }
  return CtlRequestSpec.post(
    '$_items/${Uri.encodeComponent(key)}/scrape',
    body: <String, Object?>{
      'id': id,
      'source': ?source,
      'fields': fields,
      'volume': ?volume,
    },
  );
}

String _renderSearch(Object? data) {
  final String table = renderCtlTable(
    data,
    const <(String, String)>[
      ('源', 'source'),
      ('id', 'id'),
      ('标题', 'title'),
      ('作者', 'author'),
      ('出版社', 'publisher'),
      ('年份', 'year'),
    ],
    listKey: 'candidates',
    empty: '没有匹配的候选',
  );
  final Object? hidden = data is Map ? data['hiddenNsfw'] : null;
  if (hidden is! int || hidden <= 0) return table;
  return '$table\n另有 $hidden 条 NSFW 候选未列出（加 --nsfw 显示）';
}

String _renderCandidate(Object? data) {
  if (data is! Map) return '完成';
  final StringBuffer out = StringBuffer()
    ..writeln('${data['title']}  [${data['source']} ${data['id']}]');
  for (final (String label, String field) in const <(String, String)>[
    ('原名', 'originalTitle'),
    ('作者', 'author'),
    ('出版社', 'publisher'),
    ('系列', 'series'),
    ('卷', 'volume'),
    ('ISBN', 'isbn'),
    ('年份', 'year'),
    ('封面', 'coverUrl'),
    ('横幅', 'bannerUrl'),
    ('条目', 'detailUrl'),
    ('简介', 'summary'),
  ]) {
    if (data[field] case final Object value) out.writeln('$label：$value');
  }
  if (data['adult'] == true) out.writeln('NSFW');
  return out.toString().trimRight();
}

/// 字段名 → 中文。
String describeBookMetadataField(String field) => switch (field) {
  'cover' => '封面',
  'title' => '显示名',
  'author' => '作者',
  'details' => '条目资料',
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

void _configureArt(ArgParser parser) {
  parser
    ..addFlag('dry-run', negatable: false, help: '只出计划，不下载不写入')
    ..addOption('series-key', help: '钉死某组系列（取自上次结果的 seriesKey）')
    ..addOption('pin-source', help: '钉死系列的源：mangabaka | bangumi')
    ..addOption('series-id', help: '钉死系列的源内 id');
}

int _collectionIdArg(CtlCommandContext context) {
  final String raw = context.positional(0, 'collectionId').trim();
  final int? id = int.tryParse(raw);
  if (id == null) throw CtlUsageError('合集 id 要是数字：$raw');
  return id;
}

CtlRequestSpec _buildArt(CtlCommandContext context) {
  final int id = _collectionIdArg(context);
  final String? seriesKey = context.option('series-key');
  final String? source = context.option('pin-source')?.toLowerCase();
  final String? seriesId = context.option('series-id');
  final int given = <String?>[
    seriesKey,
    source,
    seriesId,
  ].where((String? v) => v != null).length;
  if (given != 0 && given != 3) {
    throw const CtlUsageError('--series-key、--pin-source、--series-id 要一起给');
  }
  if (source != null && source != 'mangabaka' && source != 'bangumi') {
    throw CtlUsageError('--pin-source 只能是 mangabaka | bangumi：$source');
  }
  return CtlRequestSpec.post(
    '$_collections/$id/scrape-art',
    body: <String, Object?>{
      if (context.flag('dry-run')) 'dryRun': true,
      'seriesKey': ?seriesKey,
      'source': ?source,
      'seriesId': ?seriesId,
    },
  );
}

CtlRequestSpec _buildArtClear(CtlCommandContext context) =>
    CtlRequestSpec.delete(
      '$_collections/${_collectionIdArg(context)}/scrape-art',
    );

CtlRequestSpec _buildArtRemove(CtlCommandContext context) {
  final String key = context.positional(0, 'key').trim();
  if (!key.startsWith('book:') || key.length <= 5) {
    throw CtlUsageError('条目键要写成 book:<bookKey>（见 library ls）：$key');
  }
  return CtlRequestSpec.delete(
    '$_items/${Uri.encodeComponent(key)}/scraped-art',
  );
}

String _renderArt(Object? data) {
  if (data is! Map) return '完成';
  final List<Object?> series = data['series'] is List
      ? data['series']! as List<Object?>
      : const <Object?>[];
  final StringBuffer out = StringBuffer();
  if (data['dryRun'] == true) out.writeln('（计划，未写入）');
  for (final Object? s in series) {
    if (s is! Map) continue;
    final String matched = s['matchedTitle'] == null
        ? ''
        : ' → ${s['matchedTitle']} [${s['source']} ${s['seriesId']}]';
    out.writeln('${s['seriesTitle']}$matched · ${s['decision']}');
    final List<Object?> books = s['books'] is List
        ? s['books']! as List<Object?>
        : const <Object?>[];
    for (final Object? b in books) {
      if (b is Map) out.writeln('  ${b['volume'] ?? '-'} ${b['outcome']}');
    }
    if (s['decision'] == 'needsConfirm') {
      final List<Object?> options = s['options'] is List
          ? s['options']! as List<Object?>
          : const <Object?>[];
      for (final Object? o in options) {
        if (o is Map) {
          out.writeln(
            '  候选 ${o['source']} ${o['id']} ${o['title']}'
            '（--series-key "${s['seriesKey']}" --pin-source ${o['source']} '
            '--series-id ${o['id']}）',
          );
        }
      }
    }
  }
  if (data['mangaBakaRateLimited'] == true) {
    out.writeln('MangaBaka 限流，已改用 Bangumi');
  }
  if (data['usesMangaBaka'] == true) {
    out.writeln('Data from MangaBaka (CC BY-NC-SA 4.0)');
  }
  final String text = out.toString().trimRight();
  return text.isEmpty ? '没有可处理的书' : text;
}

String _renderArtRemoved(Object? data) {
  if (data is! Map) return '完成';
  final List<Object?> removed = data['removed'] is List
      ? data['removed']! as List<Object?>
      : const <Object?>[];
  return '已清除 ${removed.length} 本书的已获取封面';
}

CtlRequestSpec _buildVolumes(CtlCommandContext context) {
  final String id = context.positional(0, 'mangabakaId').trim();
  return CtlRequestSpec.get(
    '$_search/mangabaka/${Uri.encodeComponent(id)}/volumes',
  );
}

String _renderVolumes(Object? data) {
  final String table = renderCtlTable(
    data,
    const <(String, String)>[
      ('卷', 'label'),
      ('宽', 'width'),
      ('高', 'height'),
      ('图', 'url'),
    ],
    listKey: 'volumes',
    empty: '没有日文卷封面',
  );
  return '$table\nData from MangaBaka (CC BY-NC-SA 4.0)';
}
