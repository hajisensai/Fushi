import 'package:args/args.dart';

import '../ctl_commands.dart';

/// 视频库整理命令（app 侧路由见 `fushi/lib/src/ops/ctl_video_organize_routes.dart`）：
/// 作品明细、手动指定季集、按刮削资料整理文件名、把文件搬到点名的位置。
const List<CtlCommandSpec> videoOrganizeCommands = <CtlCommandSpec>[
  CtlCommandSpec(
    name: 'detail',
    summary: '一部作品的季 / 集与本机文件对应（文件 uid 用于 pin / move / organize）',
    usage: '<workId>',
    configure: _configureDetail,
    build: _buildDetail,
    render: _renderDetail,
  ),
  CtlCommandSpec(
    name: 'pin',
    summary: '手动指定一个文件的季集（--season N --episode M），或 --clear 清除',
    usage: '<bookUid>',
    configure: _configurePin,
    build: _buildPin,
    render: _renderPin,
  ),
  CtlCommandSpec(
    name: 'organize',
    summary: '按刮削资料整理文件名（--dirs 同时归到规范目录；--plan 只预览）',
    usage: '<workId | bookUid...>',
    configure: _configureOrganize,
    build: _buildOrganize,
    render: _renderOrganize,
  ),
  CtlCommandSpec(
    name: 'move',
    summary: '把一个文件搬到来源库根下点名的目录 / 改成点名的文件名',
    usage: '<bookUid>',
    configure: _configureMove,
    build: _buildMove,
    render: _renderOrganize,
  ),
];

String _seg(String raw) => Uri.encodeComponent(raw);

bool _isWorkId(String id) =>
    (id.startsWith('book:') && id.length > 'book:'.length) ||
    RegExp(r'^collection:[1-9]\d*$').hasMatch(id);

// ── detail ───────────────────────────────────────────────────────────────

void _configureDetail(ArgParser parser) {
  parser.addFlag('all', negatable: false, help: '也列没有本机文件的集');
}

CtlRequestSpec _buildDetail(CtlCommandContext context) {
  final String id = context.positional(0, 'workId').trim();
  if (!_isWorkId(id)) {
    throw CtlUsageError(
      '作品 id 格式不对：$id（book:<uid> 或 collection:<id>，见 video works）',
    );
  }
  return CtlRequestSpec.get(
    '/api/admin/video/works/${_seg(id)}/detail',
    query: <String, String>{if (context.flag('all')) 'all': 'true'},
  );
}

String _renderDetail(Object? data) {
  if (data is! Map) return '完成';
  final Object? work = data['work'];
  final List<String> lines = <String>[
    work is Map
        ? '${data['id']}  ${work['title']}'
              '${work['year'] == null ? '' : ' (${work['year']})'}'
              '  [${work['mediaType']}]  ${work['identity'] ?? '未识别'}'
        : '${data['id']}  （还没有刮削资料）',
  ];
  final Object? seasons = data['seasons'];
  if (seasons is List) {
    for (final Object? season in seasons) {
      if (season is! Map) continue;
      lines.add(
        '  第 ${season['season']} 季 ${season['title'] ?? ''}'
        '：${season['localEpisodes']}/${season['episodes']} 集有本机文件',
      );
    }
  }
  lines.add(
    renderCtlTable(
      data,
      const <(String, String)>[
        ('uid', 'uid'),
        ('绑定', 'boundTo'),
        ('分钟', 'durationMinutes'),
        ('路径', 'path'),
      ],
      listKey: 'files',
      empty: '没有本机文件',
    ),
  );
  return lines.join('\n');
}

// ── pin ──────────────────────────────────────────────────────────────────

void _configurePin(ArgParser parser) {
  parser
    ..addOption('season', help: '季号（0 = 特别篇）')
    ..addOption('episode', help: '集号')
    ..addFlag('clear', negatable: false, help: '清除手动指定（下次刮削重新自动链接）');
}

CtlRequestSpec _buildPin(CtlCommandContext context) {
  final String uid = context.positional(0, 'bookUid').trim();
  final String path = '/api/admin/video/files/${_seg(uid)}/episode';
  if (context.flag('clear')) {
    return CtlRequestSpec.post(path, body: <String, Object?>{'clear': true});
  }
  int number(String name) {
    final int? value = int.tryParse(context.option(name) ?? '');
    if (value == null || value < 0) {
      throw CtlUsageError('需要 --$name <非负整数>（或 --clear）');
    }
    return value;
  }

  return CtlRequestSpec.post(
    path,
    body: <String, Object?>{
      'season': number('season'),
      'episode': number('episode'),
    },
  );
}

String _renderPin(Object? data) {
  if (data is! Map) return '完成';
  if (data['cleared'] == true) return '已清除 ${data['uid']} 的手动季集指定';
  final Object? applied = data['applied'];
  return applied is Map
      ? '${data['uid']} → 《${data['work']}》'
            '第 ${applied['season']} 季第 ${applied['episode']} 集'
            ' ${data['episodeTitle'] ?? ''}'
      : '完成';
}

// ── organize / move ──────────────────────────────────────────────────────

void _configureOrganize(ArgParser parser) {
  parser
    ..addFlag('dirs', negatable: false, help: '同时归到来源库根下的规范目录')
    ..addFlag('plan', negatable: false, help: '只预览，不动磁盘')
    ..addFlag(
      'allow-unverified-torrents',
      negatable: false,
      help: '无法确认是否在做种时仍然改名',
    );
}

CtlRequestSpec _buildOrganize(CtlCommandContext context) {
  final List<String> targets = <String>[
    for (final String raw in context.rest)
      if (raw.trim().isNotEmpty) raw.trim(),
  ];
  if (targets.isEmpty) {
    throw const CtlUsageError('缺少 <workId> 或 <bookUid...>');
  }
  final bool byWork = targets.length == 1 && _isWorkId(targets.single);
  final String layout = context.flag('dirs') ? 'directories' : 'filename';
  const String path = '/api/admin/video/organize';
  if (context.flag('plan')) {
    return CtlRequestSpec.get(
      path,
      query: <String, String>{
        if (byWork) 'work': targets.single else 'items': targets.join(','),
        'layout': layout,
      },
    );
  }
  return CtlRequestSpec.post(
    path,
    body: <String, Object?>{
      if (byWork) 'work': targets.single else 'items': targets,
      'layout': layout,
      if (context.flag('allow-unverified-torrents'))
        'allowUnverifiedTorrents': true,
    },
  );
}

void _configureMove(ArgParser parser) {
  parser
    ..addOption('dir', help: '目标目录（相对来源库根，/ 分隔）；缺省目录不动')
    ..addOption('name', help: '新文件名（不含扩展名）；缺省文件名不动')
    ..addFlag(
      'allow-unverified-torrents',
      negatable: false,
      help: '无法确认是否在做种时仍然搬动',
    );
}

CtlRequestSpec _buildMove(CtlCommandContext context) {
  final String uid = context.positional(0, 'bookUid').trim();
  final String? dir = context.option('dir');
  final String? name = context.option('name');
  if (dir == null && name == null) {
    throw const CtlUsageError('--dir 与 --name 至少给一个');
  }
  return CtlRequestSpec.post(
    '/api/admin/video/files/${_seg(uid)}/move',
    body: <String, Object?>{
      if (dir != null) 'directory': dir,
      if (name != null) 'name': name,
      if (context.flag('allow-unverified-torrents'))
        'allowUnverifiedTorrents': true,
    },
  );
}

String _renderOrganize(Object? data) {
  if (data is! Map) return '完成';
  final List<String> lines = <String>[];
  final Object? items = data['items'];
  if (items is List) {
    for (final Object? item in items) {
      if (item is! Map) continue;
      final Object? status =
          item['status'] ?? (item['ok'] == true ? 'ok' : 'failed');
      lines.add('[$status] ${item['title']}');
      if (item['error'] != null) lines.add('    ${item['error']}');
      final Object? moves = item['moves'];
      if (moves is! List) continue;
      for (final Object? move in moves) {
        if (move is Map) lines.add('    ${move['from']}  →  ${move['to']}');
      }
    }
  }
  final Object? skipped = data['skipped'];
  if (skipped is List) {
    for (final Object? item in skipped) {
      if (item is Map) lines.add('[${item['status']}] ${item['title']}');
    }
  }
  lines.add(
    data.containsKey('renamed')
        ? '已整理 ${data['renamed']} 条'
              '${(data['failed'] as num? ?? 0) > 0 ? '，失败 ${data['failed']} 条' : ''}'
        : '可整理 ${data['ready']} 条（做种核对：${data['torrentCheck']}）',
  );
  return lines.join('\n');
}
