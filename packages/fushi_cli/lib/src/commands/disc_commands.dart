import '../ctl_commands.dart';

/// `fushi_cli disc …`：碟片：BD / DVD 原盘会话（app 侧路由见 `fushi/lib/src/ops/ctl_disc_routes.dart`）。
///
/// 列盘、进原盘菜单、在会话里按遥控键、退出会话。app 没有「弹出光驱」「交给系统
/// 播放器」入口，这里也没有。
const List<CtlCommandGroup> discCommandGroups = <CtlCommandGroup>[
  CtlCommandGroup(
    name: 'disc',
    summary: '原盘（BD / UHD / DVD）：列盘 / 进菜单 / 菜单遥控 / 退出',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'ls',
        summary: '列出视频库里的原盘（一张盘一行）',
        usage: '[关键词...]',
        build: _buildList,
        render: _renderList,
      ),
      CtlCommandSpec(
        name: 'open',
        summary: '进入原盘菜单（沉浸式原盘会话，与详情页「播放原盘」同一入口）',
        usage: '<uid>',
        build: _buildOpen,
        render: _renderOpen,
      ),
      CtlCommandSpec(
        name: 'now',
        summary: '当前原盘会话：盘类型、菜单 / 正片、标题号',
        build: _buildNow,
        render: renderDiscSession,
      ),
      CtlCommandSpec(
        name: 'key',
        summary:
            '按遥控键：up / down / left / right / select / back / '
            'top-menu / title-menu / popup-menu',
        usage: '<键>',
        build: _buildKey,
        render: _renderKey,
      ),
      CtlCommandSpec(
        name: 'exit',
        summary: '退出原盘会话回到上一页',
        build: _buildExit,
        render: _renderExit,
      ),
    ],
  ),
];

const String _root = '/api/admin/disc';

/// CLI 键名（kebab）→ 路由 wire 名（app 侧 `VideoDiscMenuKey` 的枚举名）。
const Map<String, String> _keys = <String, String>{
  'up': 'up',
  'down': 'down',
  'left': 'left',
  'right': 'right',
  'select': 'select',
  'ok': 'select',
  'enter': 'select',
  'back': 'back',
  'top-menu': 'topMenu',
  'title-menu': 'titleMenu',
  'popup-menu': 'popupMenu',
};

CtlRequestSpec _buildList(CtlCommandContext c) {
  final String search = c.rest.join(' ').trim();
  return CtlRequestSpec.get(
    '$_root/discs',
    query: <String, String>{if (search.isNotEmpty) 'search': search},
  );
}

CtlRequestSpec _buildOpen(CtlCommandContext c) => CtlRequestSpec.post(
  '$_root/open',
  body: <String, Object?>{'uid': c.positional(0, 'uid').trim()},
);

CtlRequestSpec _buildNow(CtlCommandContext c) =>
    const CtlRequestSpec.get('$_root/session');

CtlRequestSpec _buildKey(CtlCommandContext c) {
  final String raw = c.positional(0, '键').trim().toLowerCase();
  final String? key = _keys[raw];
  if (key == null) {
    throw CtlUsageError('不认识的键「$raw」，可用：${_keys.keys.join(' / ')}');
  }
  return CtlRequestSpec.post(
    '$_root/session/key',
    body: <String, Object?>{'key': key},
  );
}

CtlRequestSpec _buildExit(CtlCommandContext c) =>
    const CtlRequestSpec.post('$_root/session/exit');

// ── render ──────────────────────────────────────────────────────────────

const Map<String, String> _formatLabels = <String, String>{
  'uhdBluray': 'UHD BD',
  'bluray': 'BD',
  'dvd': 'DVD',
};

String _renderList(Object? data) {
  final Object? discs = data is Map ? data['discs'] : null;
  return renderCtlTable(
    <Map<String, Object?>>[
      if (discs is List)
        for (final Object? d in discs)
          if (d is Map)
            <String, Object?>{
              'uid': d['uid'],
              'label': d['label'],
              'format': _formatLabels[d['format']] ?? d['format'] ?? '?',
              'title': d['title'],
              'present': d['present'] == true ? '' : '不在线',
            },
    ],
    const <(String, String)>[
      ('uid', 'uid'),
      ('盘', 'label'),
      ('规格', 'format'),
      ('标题', 'title'),
      ('状态', 'present'),
    ],
    empty: '视频库里没有原盘',
  );
}

String _renderOpen(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return '已进入原盘菜单：${data['label']}（${data['title']}）';
}

/// 原盘会话状态（`disc now` / `disc key` 共用）。
String renderDiscSession(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  if (data['active'] == false) return '没有打开的原盘会话';
  final String type = data['type'] == 'dvd' ? 'DVD' : 'BD';
  final String where = data['menuStarting'] == true
      ? '菜单启动中'
      : data['menuActive'] == true
      ? '菜单'
      : data['titleReady'] == true
      ? '正片'
      : '过渡中';
  final StringBuffer out = StringBuffer(
    '${data['title'] ?? data['bookUid']} · $type'
    '${data['remote'] == true ? '（远端）' : ''} · $where',
  );
  if (data['discTitle'] != null) out.write(' · 标题 ${data['discTitle']}');
  if (data['navigationSupported'] == false) out.write('\n本机播放组件不能导航这张盘的菜单');
  if (data['error'] != null) out.write('\n错误：${data['error']}');
  return out.toString();
}

String _renderKey(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final Object? session = data['session'];
  return '已按 ${data['key']}'
      '${session is Map ? '\n${renderDiscSession(<String, Object?>{'active': true, ...session.cast<String, Object?>()})}' : ''}';
}

String _renderExit(Object? data) => '已退出原盘会话';
