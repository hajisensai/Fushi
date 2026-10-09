/// CLI 侧的通用命令表：每个域在 `commands/<域>_commands.dart` 里声明
/// [CtlCommandGroup]，`fushi_cli <group> <command> …` 按表解析参数、拼请求、
/// 渲染结果。新增命令只动对应域文件，不碰 CLI 主循环。
library;

import 'dart:convert';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

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

  final String method;
  final String path;
  final Map<String, String>? query;
  final Map<String, Object?>? body;
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

/// 一条子命令。
class CtlCommandSpec {
  const CtlCommandSpec({
    required this.name,
    required this.summary,
    required this.build,
    this.usage = '',
    this.configure,
    this.render,
  });

  final String name;
  final String summary;

  /// 位置参数说明，如 `<bookKey>`。
  final String usage;

  /// 注册该命令自己的 option / flag。
  final void Function(ArgParser parser)? configure;

  final CtlRequestSpec Function(CtlCommandContext context) build;

  /// 人类可读输出；缺省输出缩进 JSON。`--json` 时一律输出原始 JSON。
  final String Function(Object? data)? render;
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
