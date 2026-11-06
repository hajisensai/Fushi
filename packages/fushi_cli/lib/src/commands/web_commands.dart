import 'package:args/args.dart';

import '../ctl_commands.dart';

/// `fushi_cli web …`：内置浏览器与广告拦截规则（app 侧路由见 `fushi/lib/src/ops/ctl_web_routes.dart`）。
///
/// 打开网址（只导航）、历史、书签与文件夹、网页广告拦截（总开关、内置过滤列表订阅、
/// 立即更新、白名单）。app 没有自定义拦截规则 / 自定义列表地址，这里也没有。
const List<CtlCommandGroup> webCommandGroups = <CtlCommandGroup>[
  CtlCommandGroup(
    name: 'web',
    summary: '内置浏览器：打开网址 / 历史 / 书签 / 广告拦截',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'open',
        summary: '在内置浏览器打开网址（不像网址就按当前搜索引擎搜）',
        usage: '<网址|搜索词...>',
        build: _buildOpen,
        render: _renderOpen,
      ),
      CtlCommandSpec(
        name: 'history',
        summary: '浏览历史（最近在前）',
        usage: '[关键词...]',
        configure: _configureHistory,
        build: _buildHistory,
        render: _renderHistory,
      ),
      CtlCommandSpec(
        name: 'history-clear',
        summary: '清除浏览历史：--range 按时间范围，或 --id 删指定条目（不可恢复，需 --yes）',
        configure: _configureHistoryClear,
        build: _buildHistoryClear,
        render: _renderHistoryClear,
      ),
      CtlCommandSpec(
        name: 'bookmarks',
        summary: '列出书签（--folder 看某个文件夹，--all 整棵树）',
        configure: _configureBookmarks,
        build: _buildBookmarks,
        render: _renderBookmarks,
      ),
      CtlCommandSpec(
        name: 'bookmark-add',
        summary: '加书签（--folder 放进文件夹，默认根目录末尾）',
        usage: '<网址>',
        configure: _configureBookmarkAdd,
        build: _buildBookmarkAdd,
        render: _renderBookmark,
      ),
      CtlCommandSpec(
        name: 'folder-add',
        summary: '新建书签文件夹',
        usage: '<名称...>',
        configure: _configureFolderAdd,
        build: _buildFolderAdd,
        render: _renderBookmark,
      ),
      CtlCommandSpec(
        name: 'bookmark-edit',
        summary:
            '改书签 / 文件夹：--title / --url / --folder 移动 / --root 移到根 / --index 排序',
        usage: '<id>',
        configure: _configureBookmarkEdit,
        build: _buildBookmarkEdit,
        render: _renderBookmark,
      ),
      CtlCommandSpec(
        name: 'bookmark-rm',
        summary: '删书签；删非空文件夹（连同其下内容）需 --yes',
        usage: '<id>',
        configure: _configureYes,
        build: _buildBookmarkRm,
        render: _renderBookmarkRm,
      ),
      CtlCommandSpec(
        name: 'adblock',
        summary: '网页广告拦截状态：总开关、引擎、过滤列表、白名单',
        build: _buildAdblock,
        render: renderWebAdblock,
      ),
      CtlCommandSpec(
        name: 'adblock-on',
        summary: '打开网页广告拦截（顺带同步过滤列表）',
        build: _buildAdblockOn,
        render: renderWebAdblock,
      ),
      CtlCommandSpec(
        name: 'adblock-off',
        summary: '关闭网页广告拦截',
        build: _buildAdblockOff,
        render: renderWebAdblock,
      ),
      CtlCommandSpec(
        name: 'adblock-list',
        summary: '订阅 / 取消订阅一份内置过滤列表（id 见 adblock）',
        usage: '<id> <on|off>',
        build: _buildAdblockList,
        render: _renderAdblockList,
      ),
      CtlCommandSpec(
        name: 'adblock-update',
        summary: '立即更新：联网核对全部订阅的过滤列表',
        build: _buildAdblockUpdate,
        render: _renderAdblockUpdate,
      ),
      CtlCommandSpec(
        name: 'adblock-allow',
        summary: '白名单加一个站点（该站及其子域名不拦广告）',
        usage: '<站点>',
        build: _buildAllow,
        render: renderWebAdblock,
      ),
      CtlCommandSpec(
        name: 'adblock-disallow',
        summary: '从白名单删一个站点',
        usage: '<站点>',
        build: _buildDisallow,
        render: renderWebAdblock,
      ),
      CtlCommandSpec(
        name: 'adblock-allowlist-set',
        summary: '整份替换白名单原文（逗号 / 空格分隔；不给参数 = 清空）',
        usage: '[站点...]',
        build: _buildAllowlistSet,
        render: renderWebAdblock,
      ),
    ],
  ),
];

const String _root = '/api/admin/web';
const String _bookmarks = '/api/admin/web/bookmarks';
const String _adblock = '/api/admin/web/adblock';

/// 清历史的时间范围（与 app 侧 `kWebCtlClearRanges` 同一组 wire 名）。
const List<String> _ranges = <String>['hour', 'day', 'week', 'month', 'all'];

String _enc(String raw) => Uri.encodeComponent(raw.trim());

int _id(String raw, String what) {
  final int? id = int.tryParse(raw.trim());
  if (id == null || id <= 0) throw CtlUsageError('$what 必须是正整数：$raw');
  return id;
}

void _configureYes(ArgParser parser) {
  parser.addFlag('yes', abbr: 'y', negatable: false, help: '确认');
}

// ── 打开 / 历史 ──────────────────────────────────────────────────────────

CtlRequestSpec _buildOpen(CtlCommandContext c) {
  final String input = c.rest.join(' ').trim();
  if (input.isEmpty) throw const CtlUsageError('缺少参数 <网址|搜索词>');
  return CtlRequestSpec.post(
    '$_root/open',
    body: <String, Object?>{'url': input},
  );
}

void _configureHistory(ArgParser parser) {
  parser
    ..addOption('limit', help: '最多列几条（默认 50）')
    ..addOption('offset', help: '跳过前几条');
}

CtlRequestSpec _buildHistory(CtlCommandContext c) {
  final int? limit = c.intOption('limit');
  final int? offset = c.intOption('offset');
  if (limit != null && limit <= 0) throw const CtlUsageError('--limit 必须是正整数');
  if (offset != null && offset < 0) throw const CtlUsageError('--offset 不能为负');
  final String search = c.rest.join(' ').trim();
  return CtlRequestSpec.get(
    '$_root/history',
    query: <String, String>{
      if (search.isNotEmpty) 'search': search,
      if (limit != null) 'limit': '$limit',
      if (offset != null) 'offset': '$offset',
    },
  );
}

void _configureHistoryClear(ArgParser parser) {
  parser
    ..addOption('range', allowed: _ranges, help: '时间范围')
    ..addMultiOption('id', help: '要删的历史条目 id（可重复）')
    ..addFlag('yes', abbr: 'y', negatable: false, help: '确认清除（必需）');
}

CtlRequestSpec _buildHistoryClear(CtlCommandContext c) {
  final String? range = c.option('range');
  final List<int> ids = <int>[
    for (final String raw in c.multiOption('id')) _id(raw, '--id'),
  ];
  if ((range == null) == ids.isEmpty) {
    throw const CtlUsageError('--range 与 --id 二选一');
  }
  if (!c.flag('yes')) throw const CtlUsageError('清除浏览历史不可恢复，请加 --yes');
  return CtlRequestSpec.post(
    '$_root/history/clear',
    body: <String, Object?>{
      'range': ?range,
      if (ids.isNotEmpty) 'ids': <String>[for (final int id in ids) '$id'],
      'confirm': true,
    },
  );
}

// ── 书签 ─────────────────────────────────────────────────────────────────

void _configureBookmarks(ArgParser parser) {
  parser
    ..addOption('folder', help: '只看这个文件夹（id）')
    ..addFlag('all', negatable: false, help: '整棵书签树');
}

CtlRequestSpec _buildBookmarks(CtlCommandContext c) {
  final String? folder = c.option('folder');
  if (folder != null && c.flag('all')) {
    throw const CtlUsageError('--folder 与 --all 只能给一个');
  }
  return CtlRequestSpec.get(
    _bookmarks,
    query: <String, String>{
      if (folder != null) 'folder': '${_id(folder, '--folder')}',
      if (c.flag('all')) 'recursive': 'true',
    },
  );
}

void _configureBookmarkAdd(ArgParser parser) {
  parser
    ..addOption('title', help: '标题（默认用域名）')
    ..addOption('folder', help: '放进这个文件夹（id）');
}

CtlRequestSpec _buildBookmarkAdd(CtlCommandContext c) {
  final String? folder = c.option('folder');
  return CtlRequestSpec.post(
    _bookmarks,
    body: <String, Object?>{
      'type': 'bookmark',
      'url': c.positional(0, '网址').trim(),
      'title': ?c.option('title'),
      if (folder != null) 'parent': _id(folder, '--folder'),
    },
  );
}

void _configureFolderAdd(ArgParser parser) {
  parser.addOption('folder', help: '建在这个文件夹里（id）');
}

CtlRequestSpec _buildFolderAdd(CtlCommandContext c) {
  final String name = c.rest.join(' ').trim();
  if (name.isEmpty) throw const CtlUsageError('缺少参数 <名称>');
  final String? folder = c.option('folder');
  return CtlRequestSpec.post(
    _bookmarks,
    body: <String, Object?>{
      'type': 'folder',
      'title': name,
      if (folder != null) 'parent': _id(folder, '--folder'),
    },
  );
}

void _configureBookmarkEdit(ArgParser parser) {
  parser
    ..addOption('title', help: '新标题')
    ..addOption('url', help: '新网址（只限书签）')
    ..addOption('folder', help: '移进这个文件夹（id）')
    ..addFlag('root', negatable: false, help: '移到根目录')
    ..addOption('index', help: '在同级里的新位置（从 0 数）');
}

CtlRequestSpec _buildBookmarkEdit(CtlCommandContext c) {
  final int id = _id(c.positional(0, 'id'), '<id>');
  final String? folder = c.option('folder');
  if (folder != null && c.flag('root')) {
    throw const CtlUsageError('--folder 与 --root 只能给一个');
  }
  final int? index = c.intOption('index');
  if (index != null && index < 0) throw const CtlUsageError('--index 不能为负');
  final Map<String, Object?> body = <String, Object?>{
    'title': ?c.option('title'),
    'url': ?c.option('url'),
    if (folder != null) 'parent': _id(folder, '--folder'),
    if (c.flag('root')) 'root': true,
    'index': ?index,
  };
  if (body.isEmpty) {
    throw const CtlUsageError(
      '没有要改的：--title / --url / --folder / --root / --index',
    );
  }
  return CtlRequestSpec.put('$_bookmarks/$id', body: body);
}

CtlRequestSpec _buildBookmarkRm(CtlCommandContext c) {
  final int id = _id(c.positional(0, 'id'), '<id>');
  return CtlRequestSpec(
    'DELETE',
    '$_bookmarks/$id',
    body: <String, Object?>{if (c.flag('yes')) 'confirm': true},
  );
}

// ── 广告拦截 ─────────────────────────────────────────────────────────────

CtlRequestSpec _buildAdblock(CtlCommandContext c) =>
    const CtlRequestSpec.get(_adblock);

CtlRequestSpec _buildAdblockOn(CtlCommandContext c) =>
    const CtlRequestSpec.post(
      '$_adblock/enabled',
      body: <String, Object?>{'enabled': true},
    );

CtlRequestSpec _buildAdblockOff(CtlCommandContext c) =>
    const CtlRequestSpec.post(
      '$_adblock/enabled',
      body: <String, Object?>{'enabled': false},
    );

CtlRequestSpec _buildAdblockList(CtlCommandContext c) {
  final String id = c.positional(0, 'id');
  final String state = c.positional(1, 'on|off').trim().toLowerCase();
  if (state != 'on' && state != 'off') {
    throw CtlUsageError('第二个参数只能是 on / off：$state');
  }
  return CtlRequestSpec.post(
    '$_adblock/lists/${_enc(id)}',
    body: <String, Object?>{'enabled': state == 'on'},
  );
}

CtlRequestSpec _buildAdblockUpdate(CtlCommandContext c) =>
    const CtlRequestSpec.post('$_adblock/update');

CtlRequestSpec _buildAllow(CtlCommandContext c) => CtlRequestSpec.post(
  '$_adblock/allowlist',
  body: <String, Object?>{'host': c.positional(0, '站点').trim()},
);

CtlRequestSpec _buildDisallow(CtlCommandContext c) => CtlRequestSpec(
  'DELETE',
  '$_adblock/allowlist/${_enc(c.positional(0, '站点'))}',
);

CtlRequestSpec _buildAllowlistSet(CtlCommandContext c) => CtlRequestSpec.put(
  '$_adblock/allowlist',
  body: <String, Object?>{'allowlist': c.rest.join(', ').trim()},
);

// ── render ──────────────────────────────────────────────────────────────

String _time(Object? ms) {
  if (ms is! num) return '';
  final DateTime t = DateTime.fromMillisecondsSinceEpoch(ms.toInt()).toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

String _renderOpen(Object? data) =>
    data is Map ? '已在内置浏览器打开：${data['url']}' : renderCtlJson(data);

String _renderHistory(Object? data) {
  final Object? rows = data is Map ? data['history'] : null;
  return renderCtlTable(
    <Map<String, Object?>>[
      if (rows is List)
        for (final Object? r in rows)
          if (r is Map)
            <String, Object?>{
              'id': r['id'],
              'time': _time(r['lastVisitedAt']),
              'title': r['title'],
              'url': r['url'],
            },
    ],
    const <(String, String)>[
      ('id', 'id'),
      ('时间', 'time'),
      ('标题', 'title'),
      ('网址', 'url'),
    ],
    empty: '没有浏览历史',
  );
}

String _renderHistoryClear(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final Object? ids = data['ids'];
  return ids is List ? '已删除 ${ids.length} 条历史' : '已清除浏览历史（${data['range']}）';
}

String _renderBookmarks(Object? data) {
  final Object? rows = data is Map ? data['bookmarks'] : null;
  return renderCtlTable(
    <Map<String, Object?>>[
      if (rows is List)
        for (final Object? r in rows)
          if (r is Map)
            <String, Object?>{
              'id': r['id'],
              'kind': r['folder'] == true ? '文件夹' : '书签',
              'title': r['title'],
              'url': r['url'] ?? '',
              'parent': r['parentId'] ?? '',
            },
    ],
    const <(String, String)>[
      ('id', 'id'),
      ('类型', 'kind'),
      ('标题', 'title'),
      ('网址', 'url'),
      ('父文件夹', 'parent'),
    ],
    empty: '没有书签',
  );
}

String _renderBookmark(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final String kind = data['folder'] == true ? '文件夹' : '书签';
  return '$kind ${data['id']}：${data['title']}'
      '${data['url'] != null ? ' <${data['url']}>' : ''}';
}

String _renderBookmarkRm(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final Object? n = data['descendants'];
  return '已删除 ${data['title']}'
      '${n is int && n > 0 ? '（连同其下 $n 项）' : ''}';
}

/// 广告拦截状态（`adblock` / 开关 / 白名单命令共用）。
String renderWebAdblock(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final StringBuffer out = StringBuffer(
    '网页广告拦截：${data['enabled'] == true ? '开' : '关'}'
    ' · 引擎 ${data['status']}'
    '${data['syncing'] == true ? '（同步中）' : ''}'
    ' · ${data['ruleCount'] ?? 0} 条规则',
  );
  if (data['lastUpdatedAt'] != null) {
    out.write(' · 更新于 ${_time(data['lastUpdatedAt'])}');
  }
  final Object? lists = data['lists'];
  if (lists is List && lists.isNotEmpty) {
    out
      ..write('\n')
      ..write(
        renderCtlTable(
          <Map<String, Object?>>[
            for (final Object? l in lists)
              if (l is Map)
                <String, Object?>{
                  'id': l['id'],
                  'title': l['title'],
                  'on': l['enabled'] == true ? '订阅' : '',
                  'rules': l['ruleCount'],
                },
          ],
          const <(String, String)>[
            ('id', 'id'),
            ('列表', 'title'),
            ('状态', 'on'),
            ('规则', 'rules'),
          ],
        ),
      );
  }
  final Object? hosts = data['allowlistHosts'];
  out.write(
    '\n白名单：${hosts is List && hosts.isNotEmpty ? hosts.join(', ') : '（空）'}',
  );
  return out.toString();
}

String _renderAdblockList(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return '${data['id']}：${data['enabled'] == true ? '已订阅' : '已取消订阅'}（引擎在后台更新）';
}

String _renderAdblockUpdate(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return '${data['ok'] == true ? '过滤列表已更新' : '更新失败（一份列表都没取到）'}\n'
      '${renderWebAdblock(data)}';
}
