import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `flutter test` 把测试文件的整个 import 闭包编进内存。2026-11-05 量到
/// `fushi/lib` 2330 个文件里有 1329 个互相 import 成一个环，主要由
/// `lib/utils.dart` / `models.dart` / `pages.dart` / `media.dart` /
/// `creator.dart` 五个顶层 barrel 撑起来：只 import 了
/// `preferences_repository.dart` 的模型测试，也要编三千多个文件（frontend_server
/// 约 3 GB）。各文件已改成直接 import 用到的库；本守卫防环长回来：
///
/// 1. `lib/` / `test/` / `integration_test/` / `test_driver/` 里不许 import 顶层
///    barrel（barrel 文件暂留给并发分支过渡，合完后删）。合并别的分支后这条红了，
///    在仓库根跑 `tool/barrel_imports/bin/expand_barrel_imports.dart`（用法见文件头）
///    机械换掉；
/// 2. 最大强连通分量（互相可达的文件集合）不超过 [kMaxCycleFiles]，只许往下调；
/// 3. [kLeafEntries] 这些底层入口的闭包里不许出现 `app_model.dart`。
///
/// 红了：新加的 import 把底层模块接到了 UI / AppModel 上。把用到的东西挪到
/// 更底层的文件，或改用参数 / 回调注入，不要调大上限。
const int kMaxCycleFiles = 1355;

/// 底层入口：它们（含传递依赖）不应碰到 AppModel。
const List<String> kLeafEntries = <String>[];

const List<String> kBarrels = <String>[
  'utils.dart',
  'models.dart',
  'pages.dart',
  'media.dart',
  'creator.dart',
];

final RegExp _directive = RegExp(
  r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

/// `lib/` 下的 import 图：键与值都是 `lib/...` 相对路径（`/` 分隔）。
Map<String, List<String>> _libGraph() {
  final Map<String, List<String>> graph = <String, List<String>>{};
  final List<File> files = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((File f) => f.path.endsWith('.dart'))
      .toList();
  final Set<String> known = files
      .map((File f) => f.path.replaceAll(r'\', '/'))
      .toSet();
  for (final File f in files) {
    final String path = f.path.replaceAll(r'\', '/');
    final String dir = path.substring(0, path.lastIndexOf('/'));
    final List<String> out = <String>[];
    for (final RegExpMatch m in _directive.allMatches(f.readAsStringSync())) {
      final String uri = m.group(1)!;
      String? target;
      if (uri.startsWith('package:fushi/')) {
        target = 'lib/${uri.substring('package:fushi/'.length)}';
      } else if (!uri.contains(':')) {
        target = _normalize('$dir/$uri');
      }
      if (target != null && known.contains(target)) out.add(target);
    }
    graph[path] = out;
  }
  return graph;
}

String _normalize(String path) {
  final List<String> parts = <String>[];
  for (final String seg in path.split('/')) {
    if (seg == '..') {
      parts.removeLast();
    } else if (seg != '.' && seg.isNotEmpty) {
      parts.add(seg);
    }
  }
  return parts.join('/');
}

/// 最大强连通分量的文件数（迭代 Tarjan，避免深递归）。
int _largestScc(Map<String, List<String>> graph) {
  final Map<String, int> index = <String, int>{};
  final Map<String, int> low = <String, int>{};
  final Set<String> onStack = <String>{};
  final List<String> stack = <String>[];
  int counter = 0;
  int largest = 0;
  for (final String root in graph.keys) {
    if (index.containsKey(root)) continue;
    final List<(String, int)> work = <(String, int)>[(root, 0)];
    index[root] = low[root] = counter++;
    stack.add(root);
    onStack.add(root);
    while (work.isNotEmpty) {
      final (String v, int i) = work.last;
      final List<String> edges = graph[v]!;
      if (i < edges.length) {
        work[work.length - 1] = (v, i + 1);
        final String w = edges[i];
        if (!index.containsKey(w)) {
          index[w] = low[w] = counter++;
          stack.add(w);
          onStack.add(w);
          work.add((w, 0));
        } else if (onStack.contains(w)) {
          low[v] = low[v]! < index[w]! ? low[v]! : index[w]!;
        }
      } else {
        work.removeLast();
        if (work.isNotEmpty) {
          final String parent = work.last.$1;
          low[parent] = low[parent]! < low[v]! ? low[parent]! : low[v]!;
        }
        if (low[v] == index[v]) {
          int size = 0;
          String w;
          do {
            w = stack.removeLast();
            onStack.remove(w);
            size++;
          } while (w != v);
          if (size > largest) largest = size;
        }
      }
    }
  }
  return largest;
}

Set<String> _closure(Map<String, List<String>> graph, String entry) {
  final Set<String> seen = <String>{entry};
  final List<String> todo = <String>[entry];
  while (todo.isNotEmpty) {
    for (final String next in graph[todo.removeLast()] ?? const <String>[]) {
      if (seen.add(next)) todo.add(next);
    }
  }
  return seen;
}

void main() {
  final Map<String, List<String>> graph = _libGraph();

  test('不 import 顶层 barrel', () {
    final RegExp barrelImport = RegExp(
      r'''^\s*(?:import|export)\s+['"]package:fushi/(?:'''
      '${kBarrels.map(RegExp.escape).join('|')}'
      r''')['"]''',
      multiLine: true,
    );
    final List<String> offenders = <String>[];
    for (final String root in <String>[
      'lib',
      'test',
      'integration_test',
      'test_driver',
    ]) {
      final Directory dir = Directory(root);
      if (!dir.existsSync()) continue;
      for (final File f in dir.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        if (barrelImport.hasMatch(f.readAsStringSync())) {
          offenders.add(f.path.replaceAll(r'\', '/'));
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'barrel 会把几十个库捆成一个 import，用到它的文件拖进整个 app。'
          '在仓库根跑 tool/barrel_imports/bin/expand_barrel_imports.dart 换成直接 import',
    );
  });

  test('lib/ 最大 import 环不超过 $kMaxCycleFiles 个文件', () {
    final int largest = _largestScc(graph);
    expect(
      largest,
      lessThanOrEqualTo(kMaxCycleFiles),
      reason:
          '最大强连通分量 $largest 个文件，超过上限 $kMaxCycleFiles：'
          '新 import 把底层模块接回了 UI / AppModel',
    );
  });

  test('底层入口的闭包不碰 AppModel', () {
    for (final String entry in kLeafEntries) {
      expect(graph.containsKey(entry), isTrue, reason: '$entry 不存在');
      expect(
        _closure(graph, entry),
        isNot(contains('lib/src/models/app_model.dart')),
        reason: '$entry 经 import 链连到了 app_model.dart',
      );
    }
  });
}
