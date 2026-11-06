import 'package:args/args.dart';

import '../ctl_commands.dart';

/// `aidl`：AI 下载会话（app 侧路由见 `fushi/lib/src/ops/ctl_ai_download_routes.dart`）。
///
/// 一场会话 = app 里的一次「AI 下视频」对话（`--domain video`）或一次「AI 下载」
/// （`--domain novel|manga|game`）。流程：`start` 说一句话 → `status` 看进度 / 问题 /
/// 候选 → `choose` 消歧（视频：回答当前问题；其余：选定候选）→ `confirm` 执行 →
/// 需要时 `cancel`。会话在 app 进程内，闲置 30 分钟回收。
const CtlCommandGroup aiDownloadCommandGroup = CtlCommandGroup(
  name: 'aidl',
  summary: 'AI 下载会话：说一句话 → 消歧 → 确认下载（视频 / 小说 / 漫画 / 游戏）',
  commands: <CtlCommandSpec>[
    CtlCommandSpec(
      name: 'start',
      summary: '开一场会话并说第一句话（--wait N 等到它处理完再返回）',
      usage: '<一句话...>',
      configure: _configureStart,
      build: _buildStart,
      render: renderCtlAiDownloadSession,
    ),
    CtlCommandSpec(
      name: 'status',
      summary: '会话状态：进度、助手发言、待答问题、候选',
      usage: '<sessionId>',
      configure: _configureWait,
      build: _buildStatus,
      render: renderCtlAiDownloadSession,
    ),
    CtlCommandSpec(
      name: 'ls',
      summary: '列出进行中的会话',
      build: _buildList,
      render: _renderList,
    ),
    CtlCommandSpec(
      name: 'say',
      summary: '在会话里再说一句（视频：补充 / 换说法；其余：重新搜索）',
      usage: '<sessionId> <文字...>',
      configure: _configureWait,
      build: _buildSay,
      render: renderCtlAiDownloadSession,
    ),
    CtlCommandSpec(
      name: 'choose',
      summary: '消歧：视频回答当前问题（选项 id / 序号 / 文字）；其余选定候选（序号，可多个）',
      usage: '<sessionId> <选项...>',
      configure: _configureChoose,
      build: _buildChoose,
      render: renderCtlAiDownloadSession,
    ),
    CtlCommandSpec(
      name: 'confirm',
      summary: '确认：视频提交下载 / 订阅；其余按候选来源下载已选候选',
      usage: '<sessionId>',
      configure: _configureWait,
      build: _buildConfirm,
      render: renderCtlAiDownloadSession,
    ),
    CtlCommandSpec(
      name: 'cancel',
      summary: '取消会话（停止搜索；小说整本下载一并取消）',
      usage: '<sessionId>',
      build: _buildCancel,
      render: renderCtlAiDownloadSession,
    ),
    CtlCommandSpec(
      name: 'restart',
      summary: '会话回到起点（重新说一句话）',
      usage: '<sessionId>',
      build: _buildRestart,
      render: renderCtlAiDownloadSession,
    ),
    CtlCommandSpec(
      name: 'toggle',
      summary: '视频「整个系列」清单里勾选 / 取消一部（1 起序号）',
      usage: '<sessionId> <序号>',
      build: _buildToggle,
      render: renderCtlAiDownloadSession,
    ),
    CtlCommandSpec(
      name: 'close',
      summary: '关闭会话（释放 app 内资源）',
      usage: '<sessionId>',
      build: _buildClose,
      render: _renderClosed,
    ),
  ],
);

const String _base = '/api/admin/ai-download/sessions';

String _session(CtlCommandContext context, [String tail = '']) =>
    '$_base/${Uri.encodeComponent(context.positional(0, 'sessionId'))}$tail';

void _addWait(ArgParser parser) =>
    parser.addOption('wait', help: '最多等 N 秒，直到会话处理完当前步骤（≤80）');

void _configureWait(ArgParser parser) => _addWait(parser);

int? _wait(CtlCommandContext context) {
  final int? wait = context.intOption('wait');
  if (wait != null && (wait < 0 || wait > 80)) {
    throw const CtlUsageError('--wait 取 0–80 秒');
  }
  return wait;
}

Map<String, Object?> _withWait(
  CtlCommandContext context,
  Map<String, Object?> body,
) {
  final int? wait = _wait(context);
  return <String, Object?>{...body, if (wait != null) 'wait': wait};
}

void _configureStart(ArgParser parser) {
  parser.addOption(
    'domain',
    allowed: const <String>['video', 'novel', 'manga', 'game'],
    help: '内容域：video（AI 下视频）/ novel / manga / game（AI 下载）',
  );
  _addWait(parser);
}

CtlRequestSpec _buildStart(CtlCommandContext context) {
  final String? domain = context.option('domain');
  if (domain == null) {
    throw const CtlUsageError('缺少 --domain（video | novel | manga | game）');
  }
  return CtlRequestSpec.post(
    _base,
    body: _withWait(context, <String, Object?>{
      'domain': domain,
      'text': context.joinedRest(0, '一句话'),
    }),
  );
}

CtlRequestSpec _buildStatus(CtlCommandContext context) {
  final int? wait = _wait(context);
  return CtlRequestSpec.get(
    _session(context),
    query: <String, String>{if (wait != null) 'wait': '$wait'},
  );
}

CtlRequestSpec _buildList(CtlCommandContext context) =>
    const CtlRequestSpec.get(_base);

CtlRequestSpec _buildSay(CtlCommandContext context) => CtlRequestSpec.post(
  _session(context, '/say'),
  body: _withWait(context, <String, Object?>{
    'text': context.joinedRest(1, '文字'),
  }),
);

void _configureChoose(ArgParser parser) {
  _addWait(parser);
  parser.addFlag(
    'remember',
    defaultsTo: null,
    help: '视频：把这次选择记成默认（画质 / 字幕语言等问题才有）',
  );
}

CtlRequestSpec _buildChoose(CtlCommandContext context) {
  final String path = _session(context, '/choose');
  final List<String> answers = context.rest.length > 1
      ? context.rest.sublist(1)
      : throw const CtlUsageError('缺少参数 <选项>');
  final bool? remember = context.explicitFlag('remember');
  return CtlRequestSpec.post(
    path,
    body: _withWait(context, <String, Object?>{
      'answers': answers,
      if (remember != null) 'remember': remember,
    }),
  );
}

CtlRequestSpec _buildConfirm(CtlCommandContext context) => CtlRequestSpec.post(
  _session(context, '/confirm'),
  body: _withWait(context, const <String, Object?>{}),
);

CtlRequestSpec _buildCancel(CtlCommandContext context) =>
    CtlRequestSpec.post(_session(context, '/cancel'));

CtlRequestSpec _buildRestart(CtlCommandContext context) =>
    CtlRequestSpec.post(_session(context, '/restart'));

CtlRequestSpec _buildToggle(CtlCommandContext context) {
  final String path = _session(context, '/franchise');
  final int? index = int.tryParse(context.positional(1, '序号'));
  if (index == null || index < 1) throw const CtlUsageError('序号从 1 开始');
  return CtlRequestSpec.post(path, body: <String, Object?>{'index': index});
}

CtlRequestSpec _buildClose(CtlCommandContext context) =>
    CtlRequestSpec.delete(_session(context));

String _renderClosed(Object? data) => '已关闭';

String _renderList(Object? data) => renderCtlTable(
  data,
  const <(String, String)>[
    ('id', 'id'),
    ('域', 'domain'),
    ('阶段', 'stage'),
    ('处理中', 'busy'),
  ],
  listKey: 'sessions',
  empty: '没有进行中的会话',
);

/// 助手一条发言：种类 + 参数（文案键由 app 按界面语言翻译，CLI 给原始事实）。
String _say(Map<Object?, Object?> message) {
  final Object? args = message['args'];
  final String argText = args is Map && args.isNotEmpty
      ? ' ${<String>[for (final MapEntry<Object?, Object?> e in args.entries) '${e.key}=${e.value is List ? (e.value as List).join(',') : e.value}'].join(' ')}'
      : '';
  return '  助手：${message['kind']}$argText';
}

String _renderVideoView(Map<Object?, Object?> view) {
  final List<String> lines = <String>[];
  final List<Object?> transcript =
      view['transcript'] as List<Object?>? ?? const <Object?>[];
  // 只看最近几条：完整记录用 --json。
  for (final Object? m in transcript.skip(
    transcript.length > 8 ? transcript.length - 8 : 0,
  )) {
    if (m is! Map) continue;
    lines.add(m['role'] == 'user' ? '  我：${m['text']}' : _say(m));
  }
  final Object? question = view['question'];
  if (question is Map) {
    lines.add('待回答（${question['slot']}）：fushi_cli aidl choose <id> <选项>');
    final List<Object?> options =
        question['options'] as List<Object?>? ?? const <Object?>[];
    final List<Object?> alternatives =
        view['alternativeLabels'] as List<Object?>? ?? const <Object?>[];
    for (int i = 0; i < options.length; i++) {
      final Object? o = options[i];
      if (o is! Map) continue;
      final String id = '${o['id']}';
      final int? alt = id.startsWith('alt:')
          ? int.tryParse(id.substring(4))
          : null;
      final String label = <String>[
        if (o['label'] != null) '${o['label']}',
        if (o['hint'] != null) '（${o['hint']}）',
        if (alt != null && alt >= 0 && alt < alternatives.length)
          '${alternatives[alt]}',
      ].join(' ');
      final String preselected = question['preselectedIndex'] == i ? ' *' : '';
      lines.add(
        '  ${i + 1}) $id${label.isEmpty ? '' : '  $label'}$preselected',
      );
    }
  }
  final List<Object?> franchise =
      view['franchise'] as List<Object?>? ?? const <Object?>[];
  if (franchise.isNotEmpty) {
    lines.add('系列清单（aidl toggle <id> <序号> 勾选 / 取消）：');
    for (int i = 0; i < franchise.length; i++) {
      final Object? row = franchise[i];
      if (row is! Map) continue;
      lines.add(
        '  ${i + 1}) [${row['selected'] == true ? 'x' : ' '}] ${row['title']}'
        '${row['year'] == null ? '' : ' (${row['year']})'}'
        '  ${row['status']} ${row['mode']}'
        '${row['versionLabel'] == null ? '' : '  ${row['versionLabel']}'}'
        '${row['owned'] == true ? '  已在库' : ''}',
      );
    }
  }
  return lines.join('\n');
}

String _renderMediaView(Map<Object?, Object?> view) {
  final List<String> lines = <String>[
    if (view['utterance'] != null) '  我：${view['utterance']}',
    if ((view['queries'] as List<Object?>? ?? const <Object?>[]).isNotEmpty)
      '  搜索词：${(view['queries'] as List<Object?>).join(' / ')}',
    if (view['aiDegraded'] == true) '  （AI 未能参与，按原文搜索 / 本地排序）',
    if (view['error'] != null) '  错误：${view['error']}',
  ];
  final List<Map<String, Object?>> rows = <Map<String, Object?>>[
    for (final Object? c
        in view['candidates'] as List<Object?>? ?? const <Object?>[])
      if (c is Map)
        <String, Object?>{
          ...c.cast<String, Object?>(),
          'mark':
              '${c['recommended'] == true ? '★' : ''}${c['selected'] == true ? '✓' : ''}',
          'state': <String>[
            '${c['status']}',
            if (c['taskId'] != null) '任务 ${c['taskId']}',
            if (c['message'] != null) '${c['message']}',
          ].join(' '),
        },
  ];
  if (rows.isNotEmpty) {
    lines
      ..add('候选（★ AI 推荐，✓ 已选；aidl choose <id> <序号...> → aidl confirm <id>）：')
      ..add(
        renderCtlTable(
          <String, Object?>{'rows': rows},
          const <(String, String)>[
            ('#', 'no'),
            ('', 'mark'),
            ('标题', 'title'),
            ('来源', 'source'),
            ('方式', 'method'),
            ('状态', 'state'),
          ],
          listKey: 'rows',
        ),
      );
  } else if (view['stage'] == 'ready') {
    lines.add('  没有找到候选（aidl say <id> <换个说法>）');
  }
  return lines.join('\n');
}

/// 渲染一场会话的信封 `{id, domain, revision, view}`。
String renderCtlAiDownloadSession(Object? data) {
  if (data is! Map || data['view'] is! Map) return renderCtlJson(data);
  final Map<Object?, Object?> view = data['view'] as Map<Object?, Object?>;
  final String header =
      '会话 ${data['id']} [${data['domain'] ?? '?'}] ${view['stage']}'
      '${view['busy'] == true ? ' …处理中（aidl status <id> --wait 30）' : ''}';
  final String body = data['domain'] == 'video'
      ? _renderVideoView(view)
      : _renderMediaView(view);
  return body.isEmpty ? header : '$header\n$body';
}
