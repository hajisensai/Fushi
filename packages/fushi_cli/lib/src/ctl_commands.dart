/// CLI 侧的通用命令表：每个域在 `commands/<域>_commands.dart` 里声明
/// [CtlCommandGroup]，`fushi_cli <group> <command> …` 按表解析参数、拼请求、
/// 渲染结果。新增命令只动对应域文件，不碰 CLI 主循环。
library;

import 'dart:convert';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'ops/op_spec.dart';

/// 用法错误：CLI 打印 [message] 与该命令用法，退出码 64。
class CtlUsageError implements Exception {
  const CtlUsageError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 一条要发给 app 的请求。
class CtlRequestSpec {
  const CtlRequestSpec(this.method, this.path, {this.query, this.body});

  const CtlRequestSpec.get(String path, {Map<String, String>? query})
    : this('GET', path, query: query);

  const CtlRequestSpec.post(String path, {Map<String, Object?>? body})
    : this('POST', path, body: body);

  const CtlRequestSpec.put(String path, {Map<String, Object?>? body})
    : this('PUT', path, body: body);

  const CtlRequestSpec.delete(String path, {Map<String, String>? query})
    : this('DELETE', path, query: query);

  /// 调一个 [OpSpec]：method 与路径取自声明（[pathArgs] 代入 `:段`），[args] 里
  /// 非 null 的值 GET / DELETE 进 query（字符串化），其余进 body。CLI 不写路径字面量。
  factory CtlRequestSpec.op(
    OpSpec op, {
    Map<String, String> pathArgs = const <String, String>{},
    Map<String, Object?> args = const <String, Object?>{},
  }) {
    final Map<String, Object> present = <String, Object>{
      for (final MapEntry<String, Object?> e in args.entries)
        if (e.value case final Object value) e.key: value,
    };
    final String path = op.fillPath(pathArgs);
    // 没有参数时与手写的 `CtlRequestSpec.get(path)` / `.post(path)` 一样不带 query / body。
    return switch (op.method) {
      'GET' || 'DELETE' => CtlRequestSpec(
        op.method,
        path,
        query: present.isEmpty
            ? null
            : <String, String>{
                for (final MapEntry<String, Object> e in present.entries)
                  e.key: '${e.value}',
              },
      ),
      _ => CtlRequestSpec(
        op.method,
        path,
        body: present.isEmpty ? null : present,
      ),
    };
  }

  final String method;
  final String path;
  final Map<String, String>? query;
  final Map<String, Object?>? body;
}

/// 一条 CLI 命令对它的 [OpSpec] 的调用：路径参数 + 参数值（wire 键）。
class CtlOpCall {
  const CtlOpCall({
    this.pathArgs = const <String, String>{},
    this.args = const <String, Object?>{},
  });

  final Map<String, String> pathArgs;
  final Map<String, Object?> args;
}

/// 解析后的命令参数，带取值助手。
class CtlCommandContext {
  CtlCommandContext(this.args);

  final ArgResults args;

  List<String> get rest => args.rest;

  /// 第 [index] 个位置参数；缺失抛 [CtlUsageError]。
  String positional(int index, String name) {
    if (index >= rest.length || rest[index].trim().isEmpty) {
      throw CtlUsageError('缺少参数 <$name>');
    }
    return rest[index];
  }

  String? optionalPositional(int index) =>
      index < rest.length && rest[index].trim().isNotEmpty ? rest[index] : null;

  /// 从第 [from] 个起的全部位置参数用空格拼起来（查词、搜索词这类）。
  String joinedRest(int from, String name) {
    final String text = rest.skip(from).join(' ').trim();
    if (text.isEmpty) throw CtlUsageError('缺少参数 <$name>');
    return text;
  }

  String? option(String name) {
    final Object? value = args[name];
    if (value is! String) return null;
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  List<String> multiOption(String name) =>
      (args[name] as List<String>?) ?? const <String>[];

  bool flag(String name) => args[name] as bool? ?? false;

  /// 显式给出的三态 flag：没给返回 null（交给 app 用自己的默认）。
  bool? explicitFlag(String name) =>
      args.wasParsed(name) ? args[name] as bool : null;

  int? intOption(String name) {
    final String? raw = option(name);
    if (raw == null) return null;
    final int? parsed = int.tryParse(raw);
    if (parsed == null) throw CtlUsageError('--$name 必须是整数');
    return parsed;
  }
}

/// 交互式命令的后续阶段拿到的上下文（`fushi_cli ai ask` 轮询进度、终端 y/N）。
class CtlFollowContext {
  const CtlFollowContext({
    required this.command,
    required this.call,
    required this.out,
    required this.err,
    required this.json,
    required this.readLine,
    required this.delay,
  });

  /// 本命令解析后的参数（follow 阶段也能读 flag，如 `--yes`）。
  final CtlCommandContext command;

  /// 再发一条请求（同一个已就绪的客户端）。
  final Future<Object?> Function(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, Object?>? body,
  })
  call;
  final StringSink out;
  final StringSink err;
  final bool json;

  /// 读终端一行（stdin 关了返回 null）。
  final Future<String?> Function() readLine;

  /// 轮询间隔的等待（测试注入成立即返回）。
  final Future<void> Function() delay;
}

/// 一条子命令。
class CtlCommandSpec {
  /// 发一个请求的命令有两种写法：调一个 [OpSpec]（[op] + [call]，路径与 method
  /// 取自声明）；或旧写法 [build] 自己拼请求（还没迁到 [OpSpec] 的域）。
  const CtlCommandSpec({
    required this.name,
    required this.summary,
    CtlRequestSpec Function(CtlCommandContext context)? build,
    this.op,
    this.call,
    this.usage = '',
    this.configure,
    this.render,
    this.follow,
  }) : _build = build,
       assert(
         build != null
             ? op == null && call == null
             : op != null && call != null,
         'CtlCommandSpec：要么 build，要么 op + call',
       );

  final String name;
  final String summary;

  /// 位置参数说明，如 `<bookKey>`。
  final String usage;

  /// 注册该命令自己的 option / flag。
  final void Function(ArgParser parser)? configure;

  /// 旧写法：自己拼请求。
  final CtlRequestSpec Function(CtlCommandContext context)? _build;

  /// 这条命令调的操作（与 app 路由、操作目录同一个声明对象）。
  final OpSpec? op;

  /// argv → [op] 的路径参数与参数值（只做形状转换；语义校验在服务端）。
  final CtlOpCall Function(CtlCommandContext context)? call;

  /// 按命令行拼出请求（[request] 的别名，测试沿用）。
  CtlRequestSpec Function(CtlCommandContext context) get build => request;

  /// 按命令行拼出请求。
  CtlRequestSpec request(CtlCommandContext context) {
    final OpSpec? spec = op;
    if (spec == null) return _build!(context);
    final CtlOpCall opCall = call!(context);
    return CtlRequestSpec.op(
      spec,
      pathArgs: opCall.pathArgs,
      args: opCall.args,
    );
  }

  /// 人类可读输出；缺省输出缩进 JSON。`--json` 时一律输出原始 JSON。
  final String Function(Object? data)? render;

  /// 交互式后续：[build] 的请求回来后接管终端（轮询、提问），返回退出码。
  /// 有它时不走 [render]。
  final Future<int> Function(CtlFollowContext context, Object? first)? follow;
}

/// 一个域的命令组：`fushi_cli <name> <command>`。
class CtlCommandGroup {
  const CtlCommandGroup({
    required this.name,
    required this.summary,
    required this.commands,
  });

  final String name;
  final String summary;
  final List<CtlCommandSpec> commands;

  CtlCommandSpec? find(String command) {
    for (final CtlCommandSpec spec in commands) {
      if (spec.name == command) return spec;
    }
    return null;
  }
}

/// 本机文件参数在 CLI 这一侧转成绝对路径：app 进程的工作目录与 shell 不同。
/// 带 scheme 的 URL 原样返回（Windows 盘符 `C:\` 不算 scheme）。
String ctlAbsolutePath(String raw) {
  final bool windowsDrive = RegExp(r'^[A-Za-z]:[\\/]').hasMatch(raw);
  if (!windowsDrive && Uri.tryParse(raw)?.hasScheme == true) return raw;
  return p.normalize(p.absolute(raw));
}

/// 缺省渲染：缩进 JSON。
String renderCtlJson(Object? data) =>
    const JsonEncoder.withIndent('  ').convert(data);

/// 把 `List<Map>` 渲染成对齐的文本表；[columns] 是 `(表头, 字段名)`。
String renderCtlTable(
  Object? data,
  List<(String, String)> columns, {
  String? listKey,
  String empty = '（空）',
}) {
  Object? rows = data;
  if (listKey != null && data is Map) rows = data[listKey];
  if (rows is! List || rows.isEmpty) return empty;
  final List<List<String>> cells = <List<String>>[
    <String>[for (final (String header, String _) in columns) header],
    for (final Object? row in rows)
      <String>[
        for (final (String _, String key) in columns)
          row is Map ? _cell(row[key]) : '',
      ],
  ];
  final List<int> widths = <int>[
    for (int c = 0; c < columns.length; c++)
      cells
          .map((List<String> r) => _displayWidth(r[c]))
          .reduce((int a, int b) => a > b ? a : b),
  ];
  return cells
      .map(
        (List<String> r) => <String>[
          for (int c = 0; c < r.length; c++)
            c == r.length - 1
                ? r[c]
                : r[c] + ' ' * (widths[c] - _displayWidth(r[c])),
        ].join('  '),
      )
      .join('\n');
}

String _cell(Object? value) {
  if (value == null) return '';
  if (value is List) return value.join(',');
  return '$value'.replaceAll('\n', ' ');
}

/// 终端里 CJK 占两列。
int _displayWidth(String text) {
  int width = 0;
  for (final int rune in text.runes) {
    width +=
        (rune >= 0x1100 &&
            (rune <= 0x115F ||
                (rune >= 0x2E80 && rune <= 0xA4CF) ||
                (rune >= 0xAC00 && rune <= 0xD7A3) ||
                (rune >= 0xF900 && rune <= 0xFAFF) ||
                (rune >= 0xFE30 && rune <= 0xFE4F) ||
                (rune >= 0xFF00 && rune <= 0xFF60) ||
                (rune >= 0xFFE0 && rune <= 0xFFE6) ||
                (rune >= 0x20000 && rune <= 0x3FFFD)))
        ? 2
        : 1;
  }
  return width;
}
