import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_routes.dart';
import 'package:fushi_cli/fushi_cli.dart';

class _UnusedRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('构造路由表时不应访问 ref');
}

/// 有意不给 CLI 命令的 app 路由（键为 `pattern`），值写明理由。
/// 新增条目前先想清楚：用户目标是「CLI 能完成 app 里的所有操作」，
/// 只有确实不该由终端驱动的路由才进这里。
const Map<String, String> kRoutesWithoutCliCommand = <String, String>{};

/// CLI 请求路径与 app 路由双向对得上：
/// - 每条 app 路由至少被一条 CLI 命令引用（否则是 CLI 漏接的操作）；
/// - 每条 CLI 请求路径都能落到某条 app 路由（否则是指向死路由的命令）。
///
/// 做法是扫 `packages/fushi_cli/lib/src/commands/` 下的字符串字面量：代入
/// 同文件的 `const String _x = '/api/admin/…'` 常量，其余插值折成通配符，
/// 再和路由样例路径（`:param` 换成样例段）比对。method 不参与比对，
/// 所以它只抓「整条漏接 / 整条死路由」，不替代各域命令测试。
void main() {
  final List<CtlRoute> routes = buildOpRoutes(
    OpContext(ref: _UnusedRef(), focusMainWindow: () async {}),
  );
  final _CliPaths cli = _collectCliPaths(_commandsDir());

  test('能扫到 CLI 请求路径（扫描器本身没坏）', () {
    expect(cli.validated.length, greaterThan(100));
  });

  test('每条 app 路由都有 CLI 命令', () {
    final List<_Template> all = <_Template>[...cli.validated, ...cli.constants];
    final List<String> missing = <String>[
      for (final CtlRoute route in routes)
        if (!kRoutesWithoutCliCommand.containsKey(route.pattern) &&
            !all.any((_Template t) => _matches(t, route.pattern)))
          '${route.method} ${route.pattern}',
    ];
    expect(missing, isEmpty, reason: '这些路由没有 CLI 命令引用：\n${missing.join('\n')}');
  });

  test('豁免表里的路由都还存在', () {
    final Set<String> patterns = <String>{
      for (final CtlRoute route in routes) route.pattern,
    };
    for (final String pattern in kRoutesWithoutCliCommand.keys) {
      expect(patterns, contains(pattern), reason: '豁免条目已无对应路由：$pattern');
    }
  });

  test('每条 CLI 请求路径都落到某条 app 路由', () {
    final List<String> dead = <String>[
      for (final _Template t in cli.validated)
        if (!routes.any((CtlRoute r) => _matches(t, r.pattern)))
          '${t.file}: ${t.path}',
    ];
    expect(dead, isEmpty, reason: '这些 CLI 请求路径没有对应路由：\n${dead.join('\n')}');
  });

  test('扫描器：插值里的嵌套引号不打断字面量', () {
    final List<String> literals = _stringLiterals(
      "x('/api/admin/a/\${f(c.positional(0, 'id'))}/b'); y('/c')",
    );
    expect(literals, <String>[
      '/api/admin/a/\${f(c.positional(0, \'id\'))}/b',
      'id',
      '/c',
    ]);
  });

  test('扫描器：相邻字面量拼接、startsWith 比较不算请求', () {
    expect(
      _stringLiterals(
        "g('/api/admin/w/'\n  '\${x}/r'); p.startsWith('/api/admin/m/')",
      ),
      <String>['/api/admin/w/\${x}/r'],
    );
  });

  test('比对：具体段能落到 :param，插值能吞多段', () {
    expect(
      _matches(
        const _Template('f', '/api/admin/models/gpt-sovits/local/start'),
        '/api/admin/models/:kind/:id/start',
      ),
      isTrue,
    );
    expect(
      _matches(
        const _Template('f', '/api/admin/game/games/\${id}\$suffix'),
        '/api/admin/game/games/:id/config',
      ),
      isTrue,
    );
    expect(
      _matches(
        const _Template('f', '/api/admin/nope'),
        '/api/admin/models/:kind',
      ),
      isFalse,
    );
  });
}

Directory _commandsDir() {
  // flutter test 的 cwd 是 fushi/。
  final Directory dir = Directory('../packages/fushi_cli/lib/src/commands');
  if (!dir.existsSync()) {
    fail('找不到 CLI 命令目录：${dir.absolute.path}');
  }
  return dir;
}

class _Template {
  const _Template(this.file, this.path);
  final String file;
  final String path;
}

class _CliPaths {
  _CliPaths(this.validated, this.constants);

  /// 拼出来的请求路径：必须落到某条路由。
  final List<_Template> validated;

  /// `_root` 一类基址常量：可能被直接当请求路径用，算覆盖，但不要求本身是路由。
  final List<_Template> constants;
}

const String _apiPrefix = '/api/admin/';

_CliPaths _collectCliPaths(Directory dir) {
  final List<_Template> validated = <_Template>[];
  final List<_Template> constants = <_Template>[];
  final RegExp constDecl = RegExp(
    r"""const\s+String\s+(_\w+)\s*=\s*'([^'$]*)'\s*;""",
  );
  final List<File> files =
      dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => f.path.endsWith('.dart'))
          .toList()
        ..sort((File a, File b) => a.path.compareTo(b.path));
  for (final File file in files) {
    final String name = file.uri.pathSegments.last;
    final String source = file.readAsStringSync();
    final Map<String, String> consts = <String, String>{};
    for (final RegExpMatch m in constDecl.allMatches(source)) {
      consts[m.group(1)!] = m.group(2)!;
      if (m.group(2)!.startsWith('/api/admin')) {
        constants.add(_Template(name, m.group(2)!));
      }
    }
    final Set<String> constValues = consts.values.toSet();
    for (final String literal in _stringLiterals(source)) {
      String path = literal;
      for (final MapEntry<String, String> c in consts.entries) {
        path = path
            .replaceAll('\${${c.key}}', c.value)
            .replaceAll(RegExp('\\\$${c.key}(?![A-Za-z0-9_])'), c.value);
      }
      if (!path.startsWith(_apiPrefix)) continue;
      if (constValues.contains(literal)) continue; // 常量声明本身。
      final int query = path.indexOf('?');
      if (query >= 0) path = path.substring(0, query);
      validated.add(_Template(name, path));
    }
  }
  return _CliPaths(validated, constants);
}

/// 逐段合一：模板里含插值的段通配一段，若是最后一段则可吞下余下的多段
/// （`${id}$suffix` 拼出 `:id/config`）；路由的 `:param` 通配一段
/// （`gpt-sovits/local/start` 落到 `:kind/:id/start`）。
bool _matches(_Template t, String routePattern) {
  final List<String> tpl = _segments(t.path);
  final List<String> route = _segments(routePattern);
  bool go(int ti, int ri) {
    if (ti == tpl.length) return ri == route.length;
    final String seg = tpl[ti];
    if (seg.contains(r'$')) {
      if (ti == tpl.length - 1) return ri < route.length;
      return ri < route.length && go(ti + 1, ri + 1);
    }
    if (ri == route.length) return false;
    final String r = route[ri];
    return (r.startsWith(':') || r == seg) && go(ti + 1, ri + 1);
  }

  return go(0, 0);
}

/// 按 `/` 切段；插值内部的 `/` 不切。
List<String> _segments(String path) {
  final List<String> out = <String>[];
  final StringBuffer cur = StringBuffer();
  int i = 0;
  while (i < path.length) {
    if (path[i] == r'$' && i + 1 < path.length && path[i + 1] == '{') {
      final int end = _skipInterpolation(path, i + 2);
      cur.write(path.substring(i, end));
      i = end;
      continue;
    }
    if (path[i] == '/') {
      if (cur.isNotEmpty) out.add(cur.toString());
      cur.clear();
    } else {
      cur.write(path[i]);
    }
    i++;
  }
  if (cur.isNotEmpty) out.add(cur.toString());
  return out;
}

/// 返回源码里全部单 / 双引号字符串字面量的原文（不含引号，插值保持原样），
/// 插值内部的字面量也会单独列出。不处理三引号与 raw 字符串（命令文件里不用）。
List<String> _stringLiterals(String source) {
  final List<String> out = <String>[];
  int i = 0;
  while (i < source.length) {
    final String ch = source[i];
    if (ch == '/' && i + 1 < source.length && source[i + 1] == '/') {
      final int nl = source.indexOf('\n', i);
      i = nl < 0 ? source.length : nl + 1;
      continue;
    }
    if (ch == "'" || ch == '"') {
      // `x.startsWith('/api/…')` 是比较不是请求，丢掉。
      final bool isComparison = source
          .substring(0, i)
          .trimRight()
          .endsWith('startsWith(');
      final List<String> parts = <String>[];
      i = _readLiteral(source, i, parts);
      final StringBuffer joined = StringBuffer(parts.first);
      final List<String> nested = parts.sublist(1);
      // Dart 相邻字面量 `'a' 'b'` 就是一个字符串。
      while (true) {
        int j = i;
        while (j < source.length && ' \t\r\n'.contains(source[j])) {
          j++;
        }
        if (j >= source.length || (source[j] != "'" && source[j] != '"')) {
          break;
        }
        final List<String> next = <String>[];
        i = _readLiteral(source, j, next);
        joined.write(next.first);
        nested.addAll(next.sublist(1));
      }
      if (!isComparison) out.add(joined.toString());
      out.addAll(nested);
      continue;
    }
    i++;
  }
  return out;
}

/// 从 [start]（引号位置）读一个字面量，加入 [out]，返回字面量之后的下标。
int _readLiteral(String s, int start, List<String> out) {
  final String quote = s[start];
  final int slot = out.length;
  out.add('');
  final StringBuffer buf = StringBuffer();
  int i = start + 1;
  while (i < s.length) {
    final String ch = s[i];
    if (ch == r'\') {
      buf.write(s.substring(i, (i + 2).clamp(0, s.length)));
      i += 2;
      continue;
    }
    if (ch == quote) {
      out[slot] = buf.toString();
      return i + 1;
    }
    if (ch == r'$' && i + 1 < s.length && s[i + 1] == '{') {
      final int end = _skipInterpolation(s, i + 2, out);
      buf.write(s.substring(i, end));
      i = end;
      continue;
    }
    if (ch == '\n') break; // 未闭合，放弃。
    buf.write(ch);
    i++;
  }
  out[slot] = buf.toString();
  return i;
}

/// 从 `${` 之后的 [start] 跳到匹配的 `}` 之后；途中遇到的字面量加入 [out]。
int _skipInterpolation(String s, int start, [List<String>? out]) {
  int depth = 1;
  int i = start;
  while (i < s.length && depth > 0) {
    final String ch = s[i];
    if (ch == "'" || ch == '"') {
      i = _readLiteral(s, i, out ?? <String>[]);
      continue;
    }
    if (ch == '{') depth++;
    if (ch == '}') depth--;
    i++;
  }
  return i;
}
