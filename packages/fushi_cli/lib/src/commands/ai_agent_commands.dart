import 'dart:convert';

import 'package:args/args.dart';

import '../ctl_commands.dart';

/// 终端版 AI 助手（spec `docs/specs/2026-10-26-ai-operations-agent-design.md` §8 P2），
/// 挂在 `ai` 组下：
/// - `fushi_cli ai ask <一句话…>`：AI 在 app 里执行；可逆操作直接执行并打印撤销
///   命令，不可逆操作与装扩展在终端里 y/N 确认（模型代答不了）；候选让你按序号选。
/// - `fushi_cli ai undo <id>`：按操作记录撤销一条（过了会话也行）。
/// - `fushi_cli ai log`：最近的 AI 操作记录。
const List<CtlCommandSpec> aiAgentCommands = <CtlCommandSpec>[
  CtlCommandSpec(
    name: 'ask',
    summary: '让 AI 助手在 app 里代办一件事（可逆操作直接执行，不可逆 / 装扩展先 y/N）',
    usage: '<一句话…>',
    configure: _configureAsk,
    build: _buildAsk,
    follow: _followAsk,
  ),
  CtlCommandSpec(
    name: 'undo',
    summary: '撤销一条 AI 操作记录',
    usage: '<id>',
    build: _buildUndo,
    render: _renderUndo,
  ),
  CtlCommandSpec(
    name: 'log',
    summary: '最近的 AI 操作记录（--session 只看一场对话）',
    configure: _configureLog,
    build: _buildLog,
    render: _renderLog,
  ),
];

const String _agentRoot = '/api/admin/ai/agent';

void _configureAsk(ArgParser parser) {
  parser
    ..addOption('session', help: '接着某场对话说（ask 打印的会话 id）')
    ..addFlag('yes', negatable: false, help: '确认卡片一律回答「执行」（只在你确定时用）');
}

CtlRequestSpec _buildAsk(CtlCommandContext c) => CtlRequestSpec.post(
  '$_agentRoot/ask',
  body: <String, Object?>{
    'text': c.joinedRest(0, '一句话'),
    if (c.option('session') != null) 'sessionId': c.option('session'),
    // `--yes` 不进请求：确认仍由终端这一侧逐张作答（见 [_followAsk]）。
  },
);

/// 轮询会话，逐条打印进度；遇到确认 / 候选卡片向终端提问。
Future<int> _followAsk(CtlFollowContext c, Object? first) async {
  final String? sessionId = first is Map ? first['sessionId'] as String? : null;
  if (sessionId == null) {
    c.err.writeln('app 没返回会话 id');
    return 70;
  }
  final String path = '$_agentRoot/sessions/${Uri.encodeComponent(sessionId)}';
  final Set<String> printed = <String>{};
  final bool autoYes = c.command.flag('yes');
  bool failed = false;
  while (true) {
    final Object? state = await c.call('GET', path);
    if (state is! Map) return 70;
    final List<Object?> entries =
        state['entries'] as List<Object?>? ?? const [];
    for (final Object? raw in entries) {
      if (raw is! Map) continue;
      final String id = '${raw['id']}';
      final String status = '${raw['status']}';
      if (printed.contains(id)) continue;
      // 还在跑 / 等回答的条目等落定后再打印（确认卡片下面单独处理）。
      if (status == 'running' || status == 'pending') continue;
      printed.add(id);
      final String? line = _entryLine(raw, c.json);
      if (line != null) c.out.writeln(line);
      if (raw['kind'] == 'notice' || status == 'failed') failed = true;
    }
    final Object? pending = state['pending'];
    if (pending is Map) {
      final Map<Object?, Object?>? card = _entryById(
        entries,
        pending['entryId'],
      );
      if (pending['kind'] == 'confirm') {
        c.out.writeln(_confirmText(card));
        bool approve = autoYes;
        if (!autoYes) {
          c.out.write('执行？[y/N] ');
          final String answer =
              (await c.readLine())?.trim().toLowerCase() ?? '';
          approve = answer == 'y' || answer == 'yes';
        }
        await c.call(
          'POST',
          '$path/answer',
          body: <String, Object?>{'approve': approve},
        );
      } else {
        final List<Object?> options =
            card?['options'] as List<Object?>? ?? const [];
        c.out.writeln('${card?['text'] ?? ''}');
        for (int i = 0; i < options.length; i++) {
          final Object? o = options[i];
          if (o is Map) {
            c.out.writeln(
              '  ${i + 1}. ${o['label']}${o['detail'] == null ? '' : ' · ${o['detail']}'}',
            );
          }
        }
        c.out.write('选哪个？（序号，回车 = 都不是）');
        final int? index = int.tryParse((await c.readLine())?.trim() ?? '');
        final Object? picked =
            index != null && index >= 1 && index <= options.length
            ? options[index - 1]
            : null;
        await c.call(
          'POST',
          '$path/answer',
          body: <String, Object?>{
            if (picked is Map) 'choice': '${picked['id']}',
          },
        );
      }
      continue;
    }
    if (state['running'] != true) {
      c.out.writeln(
        '（会话 $sessionId · ${state['tokens'] ?? 0} tokens；接着说：fushi_cli ai ask --session $sessionId …）',
      );
      return failed ? 1 : 0;
    }
    await c.delay();
  }
}

Map<Object?, Object?>? _entryById(List<Object?> entries, Object? id) {
  for (final Object? e in entries) {
    if (e is Map && e['id'] == id) return e;
  }
  return null;
}

String _confirmText(Map<Object?, Object?>? card) {
  if (card == null) return '需要确认：';
  final String tool = '${card['toolName'] ?? ''}';
  final bool irreversible = card['risk'] == 'irreversible';
  final Object? args = card['arguments'];
  return <String>[
    RegExp(
          r'^online\.(extension\.(install|update)\w*|repo\.add)$',
        ).hasMatch(tool)
        ? '要安装这个扩展吗？ $tool'
        : '执行前请确认：$tool',
    if (args is Map && args.isNotEmpty) '  ${jsonEncode(args)}',
    irreversible ? '  这一步无法撤销。' : '  执行后可以撤销。',
  ].join('\n');
}

String? _entryLine(Map<Object?, Object?> e, bool json) {
  if (json) return jsonEncode(e);
  final String status = '${e['status']}';
  switch (e['kind']) {
    case 'user':
      return null;
    case 'assistant':
      return '${e['text']}';
    case 'toolCall':
      final String tool = '${e['toolName']}';
      if (status == 'failed')
        return '  ✗ $tool：${e['errorCode'] ?? ''} ${e['resultPreview'] ?? ''}'
            .trimRight();
      if (status == 'declined') return '  – $tool：未执行';
      final String change = e['before'] != null || e['after'] != null
          ? '：${e['before'] ?? '∅'} → ${e['after'] ?? '∅'}'
          : '';
      final String undo = e['actionId'] != null && e['undoable'] == true
          ? '（撤销：fushi_cli ai undo ${e['actionId']}）'
          : '';
      return '  ✓ $tool$change$undo';
    case 'confirm':
      return status == 'approved' ? '  已确认' : '  已拒绝';
    case 'choice':
      return e['selected'] == null ? '  （都不是）' : '  已选：${e['selected']}';
    case 'notice':
      return '  [停止] ${e['errorCode'] ?? ''} ${e['text'] ?? ''}'.trimRight();
  }
  return null;
}

CtlRequestSpec _buildUndo(CtlCommandContext c) => CtlRequestSpec.post(
  '$_agentRoot/actions/${Uri.encodeComponent(c.positional(0, 'id'))}/undo',
);

String _renderUndo(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return switch (data['status']) {
    'done' => '已撤销',
    'superseded' => '之后又被改过，保留现状（没有覆盖你的修改）',
    _ => '撤销失败：${data['message'] ?? data['status']}',
  };
}

void _configureLog(ArgParser parser) {
  parser
    ..addOption('session', help: '只看这场对话')
    ..addOption('limit', help: '最多几条（默认 50）');
}

CtlRequestSpec _buildLog(CtlCommandContext c) => CtlRequestSpec.get(
  '$_agentRoot/actions',
  query: <String, String>{
    if (c.option('session') != null) 'sessionId': c.option('session')!,
    if (c.option('limit') != null) 'limit': c.option('limit')!,
  },
);

String _renderLog(Object? data) =>
    renderCtlTable(data, const <(String, String)>[
      ('ID', 'id'),
      ('操作', 'op'),
      ('结果', 'result'),
      ('改前', 'before'),
      ('改后', 'after'),
      ('可撤销', 'undoable'),
    ], listKey: 'actions');
