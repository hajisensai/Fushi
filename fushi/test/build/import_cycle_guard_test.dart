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
/// 3. [kAppModelFreeDirs] 目录下**每个**文件（含传递依赖）的闭包里不许出现
///    `app_model.dart`。
///
/// 换掉 barrel 之后大环几乎没缩（2426 个文件里仍有 1355 个），根子是 AppModel 上帝
/// 对象：底层的 models / utils / storage 里有文件直接或间接 import 了它
/// （`preferences_repository → error_log_service → fushi_toast → … →
/// fushi_header_search → app_model` 之类），于是整个底层都被拖进环。2026-11-05
/// 把底层用到的符号挪到更底层的文件、读 AppModel 的件挪到上层或改成参数注入后，
/// 这三个目录（278 个文件）的闭包全部碰不到 app_model，最大环降到 2435 个文件里
/// 的 710 个。剩下的环由 AppModel 直接 import 页面 / 媒体源 / 制卡字段撑着，要再缩
/// 得拆 AppModel 本身。
///
/// 红了：新加的 import 把底层模块接到了 UI / AppModel 上。把用到的东西挪到
/// 更底层的文件，或改用参数 / 回调注入，不要调大上限、不要把文件从目录里豁免。
const int kMaxCycleFiles = 710;

const String kAppModel = 'lib/src/models/app_model.dart';

/// 这些目录下的所有文件（除 [kAppModel] 本身）都不许经 import 链连到 AppModel。
const List<String> kAppModelFreeDirs = <String>[
  'lib/src/models/',
  'lib/src/utils/',
  'lib/src/storage/',
];

/// 代表性的底层入口（目录级断言之外再钉一遍存在性，路径改了要跟着改）。
const List<String> kLeafEntries = <String>[
  'lib/src/models/preferences_repository.dart',
  'lib/src/models/theme_notifier.dart',
  'lib/src/storage/app_paths.dart',
  'lib/src/utils/misc/error_log_service.dart',
  'lib/src/utils/misc/platform_utils.dart',
  'lib/src/utils/components/fushi_material_components.dart',
  'lib/src/utils/adaptive/adaptive_widgets.dart',
];

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

/// [from] 到 [to] 的一条最短 import 链（BFS）；不可达返回 null。
List<String>? _shortestChain(
  Map<String, List<String>> graph,
  String from,
  String to,
) {
  final Map<String, String?> prev = <String, String?>{from: null};
  final List<String> queue = <String>[from];
  for (int i = 0; i < queue.length; i++) {
    final String v = queue[i];
    if (v == to) break;
    for (final String w in graph[v] ?? const <String>[]) {
      if (!prev.containsKey(w)) {
        prev[w] = v;
        queue.add(w);
      }
    }
  }
  if (!prev.containsKey(to)) return null;
  final List<String> chain = <String>[];
  for (String? v = to; v != null; v = prev[v]) {
    chain.add(v);
  }
  return chain.reversed.toList();
}

/// 能经 import 链到达 [target] 的全部文件（反向图上的闭包，含 [target]）。
Set<String> _reaching(Map<String, List<String>> graph, String target) {
  final Map<String, List<String>> reverse = <String, List<String>>{};
  for (final MapEntry<String, List<String>> e in graph.entries) {
    for (final String to in e.value) {
      (reverse[to] ??= <String>[]).add(e.key);
    }
  }
  return _closure(reverse, target);
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
        isNot(contains(kAppModel)),
        reason: '$entry 经 import 链连到了 app_model.dart',
      );
    }
  });

  test('models / utils / storage 目录下所有文件的闭包都不碰 AppModel', () {
    expect(graph.containsKey(kAppModel), isTrue, reason: '$kAppModel 不存在');
    final Set<String> reaching = _reaching(graph, kAppModel);
    final List<String> offenders = <String>[
      for (final String file in graph.keys.toList()..sort())
        if (file != kAppModel &&
            kAppModelFreeDirs.any(file.startsWith) &&
            reaching.contains(file))
          '$file：${_shortestChain(graph, file, kAppModel)!.join(' -> ')}',
    ];
    expect(
      offenders,
      isEmpty,
      reason:
          '底层文件经 import 链连到了 app_model.dart（每行给一条最短链）。'
          '把链上真正用到的符号挪到更底层，或改成参数 / 回调注入',
    );
  });
}
