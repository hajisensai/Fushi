import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ops/op_catalog_assembly.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_routes.dart';
import 'package:fushi_cli/fushi_cli.dart';

class _UnusedRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('构造操作目录时不应访问 ref');
}

/// 还没迁到 [OpSpec] 的旧写法的全部存量——只许减不许增（架构重构 C1）。基线按**身份**
/// 记，不只记个数：迁走一条、再新写一条旧写法的等量互换也会红。
///
/// - `legacyRoutes`：app 的手写路由（[CtlRoute.op] 为 null：手写 [CtlRoute] + 另写
///   一份 [OpDescription]、靠 `METHOD pattern` 字符串配对），逐条列出；
/// - `legacyCliCommands`：`fushi_cli` 里自己拼请求路径的命令（`CtlCommandSpec(build:)`，
///   没有 `op`），逐条列出；
/// - `legacyOpConstructions`：全仓 `lib/` 里 `OpDescription(` / `FushiOp(` 的构造处数，
///   按文件记（app、`fushi_server` 的 `server.*` 目录、`fushi_engine` 的复习操作都在内）；
/// - `stringRouteRefs`：按 `METHOD pattern` 字符串引用别的路由的调用处数
///   （`callRoute` / `readBackUndo` / `readListField` / `kit.route`），按文件记。按文件
///   记数挡不住同一个文件里迁一处、加一处的互换——那种改动在这个文件的 diff 里一眼可见。
///
/// 结构约束（id 形状、read 不带撤销、写操作可撤销或 irreversible、inPath 与模式一致、
/// 地址类参数必须选语义角色、remoteUrl 参数 / 装扩展必须先确认）在 [FushiOp] 构造时
/// 检查，组目录即炸，不在这里。
///
/// 迁走一批后缩小基线：
/// `FUSHI_OP_LEGACY_SURFACE_WRITE=1 dart tool/heavy.dart --here -- flutter test test/ops/op_catalog_ratchet_guard_test.dart --no-pub`
/// 重写只会缩小：实际存量有任何一项超出现有基线时拒绝写。
const String _baselinePath = 'test/ops/goldens/op_legacy_surface.json';

/// 有意不进操作目录的路由前缀，值写明理由。
const Map<String, String> kRoutePrefixesNotForAi = <String, String>{
  '/api/admin/ai/agent/': 'AI 助手自己的会话 / 操作记录接口：AI 不能调 AI，终端版 AI 用',
};

/// 没有任何现有路由能读出任务状态的 longRunning 操作，值写明理由。只许放真没有
/// 状态路由的；能读就该写 taskStatus。（这条只管 app 目录：服务端的
/// `server.download.add` 还没有 taskStatus，见 fushi_server 的 admin_ops.dart。）
const Map<String, String> kLongRunningWithoutTaskStatus = <String, String>{};

/// 源码扫描的范围：app 与各包的 `lib/`（cwd 是 `fushi/`）。
List<File> _libSources() {
  final List<Directory> roots = <Directory>[
    Directory('lib'),
    for (final FileSystemEntity pkg in Directory('../packages').listSync())
      if (pkg is Directory) Directory('${pkg.path}/lib'),
  ];
  return <File>[
    for (final Directory root in roots)
      if (root.existsSync())
        for (final FileSystemEntity f in root.listSync(recursive: true))
          if (f is File &&
              f.path.endsWith('.dart') &&
              !f.path.endsWith('.g.dart'))
            f,
  ];
}

/// 仓库根相对的 posix 路径（`fushi/lib/…`、`packages/…`）。
String _repoPath(File file) {
  final String path = file.path.replaceAll(r'\', '/');
  return path.startsWith('../') ? path.substring(3) : 'fushi/$path';
}

/// 每个文件里 [pattern] 的命中数（0 的不记）；[skip] 是定义这些 API 的文件。
Map<String, int> _countPerFile(
  List<File> sources,
  RegExp pattern,
  Set<String> skip,
) {
  final Map<String, int> out = <String, int>{};
  for (final File file in sources) {
    final String path = _repoPath(file);
    if (skip.contains(path)) continue;
    final int count = pattern.allMatches(file.readAsStringSync()).length;
    if (count > 0) out[path] = count;
  }
  return Map<String, int>.fromEntries(
    out.entries.toList()..sort(
      (MapEntry<String, int> a, MapEntry<String, int> b) =>
          a.key.compareTo(b.key),
    ),
  );
}

final RegExp _legacyOpConstruction = RegExp(
  r'\b(?:OpDescription|FushiOp)\s*\(',
);
final RegExp _stringRouteRef = RegExp(
  r'\b(?:callRoute|readBackUndo|readListField)\s*\(|\bkit\.route\s*\(',
);

/// [actual] 超出 [baseline] 的项（新增的身份，或某个文件的数涨了）。
List<String> _growth(Object? actual, Object? baseline) {
  if (actual is List) {
    final Set<Object?> known = (baseline as List? ?? const <Object?>[]).toSet();
    return <String>[
      for (final Object? item in actual)
        if (!known.contains(item)) '$item',
    ];
  }
  final Map<String, Object?> counts = actual! as Map<String, Object?>;
  final Map<Object?, Object?> known = baseline as Map? ?? const <String, int>{};
  return <String>[
    for (final MapEntry<String, Object?> e in counts.entries)
      if ((e.value! as int) > (known[e.key] as int? ?? 0))
        '${e.key}: ${known[e.key] ?? 0} → ${e.value}',
  ];
}

void main() {
  final OpContext context = OpContext(ref: _UnusedRef());
  final List<CtlRoute> domain = buildDomainOpRoutes(context);
  final OpCatalog catalog = buildAppOpCatalog(context, domain);
  final Set<CtlRoute> described = <CtlRoute>{
    for (final FushiOp op in catalog.ops) op.route,
  };
  final List<File> sources = _libSources();

  test('旧写法的存量只许减不许增（手写路由 / 自拼路径的 CLI 命令 / OpDescription 构造处 / '
      '字符串路由引用）', () {
    final Map<String, Object?> actual = <String, Object?>{
      'legacyRoutes': <String>[
        for (final CtlRoute route in domain)
          if (route.op == null) '${route.method} ${route.pattern}',
      ]..sort(),
      'legacyCliCommands': <String>[
        for (final CtlCommandGroup group in kCtlCommandGroups)
          for (final CtlCommandSpec command in group.commands)
            if (command.op == null) '${group.name} ${command.name}',
      ]..sort(),
      'legacyOpConstructions': _countPerFile(
        sources,
        _legacyOpConstruction,
        const <String>{'packages/fushi_cli/lib/src/ops/fushi_op.dart'},
      ),
      'stringRouteRefs': _countPerFile(sources, _stringRouteRef, const <String>{
        'fushi/lib/src/ops/op_describe_kit.dart',
      }),
    };
    final File file = File(_baselinePath);
    final Map<String, Object?> baseline = file.existsSync()
        ? jsonDecode(file.readAsStringSync()) as Map<String, Object?>
        : const <String, Object?>{};
    final List<String> grown = <String>[
      if (file.existsSync())
        for (final String key in actual.keys)
          for (final String item in _growth(actual[key], baseline[key]))
            '$key  $item',
    ];
    expect(
      grown,
      isEmpty,
      reason:
          '旧写法只减不增。新操作写 OpSpec（packages/fushi_cli/lib/src/ops/specs/）并 '
          'bind；CLI 命令用 CtlCommandSpec(op:, call:)；调已迁操作用 kit.invoke。'
          '基线不能靠重写放行。\n${grown.join('\n')}',
    );
    final String rendered =
        '${const JsonEncoder.withIndent('  ').convert(actual)}\n';
    if (Platform.environment['FUSHI_OP_LEGACY_SURFACE_WRITE'] == '1') {
      file
        ..createSync(recursive: true)
        ..writeAsStringSync(rendered);
      return;
    }
    expect(file.existsSync(), isTrue, reason: '缺基线 $_baselinePath（见本文件头的重写命令）');
    expect(
      rendered,
      file.readAsStringSync().replaceAll('\r\n', '\n'),
      reason: '又迁走了一批：按本文件头的命令把基线缩小到现在的实际存量',
    );
  });

  test('已迁到 OpSpec 的操作不再被字符串引用（路由模式只写在声明里）', () {
    // 字符串引用（kit.callRoute 等）指向已迁路由要到执行撤销那一刻才抛错；这里在
    // 源码层面挡住：app 源码里不出现已迁操作的路由模式字面量，也不从声明对象上取
    // pattern / method / root 去拼字符串引用。
    final Set<String> migrated = <String>{
      for (final CtlRoute route in domain)
        if (route.op != null) route.pattern,
    };
    expect(migrated, isNotEmpty);
    final RegExp viaDecl = RegExp(
      r'\b[A-Z]\w*Ops\.(?:\w+\.(?:pattern|method)|root)\b',
    );
    final List<String> offenders = <String>[];
    for (final File file in sources) {
      final String path = _repoPath(file);
      if (!path.startsWith('fushi/lib/')) continue;
      final String source = file.readAsStringSync();
      for (final String pattern in migrated) {
        if (source.contains("'$pattern'") || source.contains('"$pattern"')) {
          offenders.add('$path: $pattern');
        }
      }
      for (final RegExpMatch m in viaDecl.allMatches(source)) {
        offenders.add('$path: ${m.group(0)}');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: '已迁操作按声明对象调（kit.invoke / OpSpec.bind），不写路径字符串',
    );
  });

  test('旧路径的手写路由都有描述（豁免前缀除外）', () {
    final List<String> undescribed = <String>[
      for (final CtlRoute route in domain)
        if (route.op == null &&
            !described.contains(route) &&
            !kRoutePrefixesNotForAi.keys.any(route.pattern.startsWith))
          '${route.method} ${route.pattern}',
    ];
    expect(
      undescribed,
      isEmpty,
      reason: '给它写 OpSpec（或迁之前在 op_descriptions_<域>.dart 补描述）',
    );
  });

  test('豁免前缀下没有被描述的路由（描述了就不该豁免）', () {
    for (final FushiOp op in catalog.ops) {
      expect(
        kRoutePrefixesNotForAi.keys.any(op.route.pattern.startsWith),
        isFalse,
        reason: op.id,
      );
    }
  });

  test('longRunning 操作必须声明 taskStatus（AI 轮询任务、结束后报告，spec §6.1）', () {
    final List<String> missing = <String>[
      for (final FushiOp op in catalog.ops)
        if (op.longRunning &&
            op.taskStatus == null &&
            !kLongRunningWithoutTaskStatus.containsKey(op.id))
          op.id,
    ];
    expect(
      missing,
      isEmpty,
      reason:
          '这些 longRunning 操作没有 taskStatus：用现有状态路由映射成 OpTaskStatus，'
          '结果里任务 id 不在顶层 taskId/jobId 时再写 taskIdOf（见 '
          'lib/src/ops/op_task_status.dart）。确实没有状态路由才进 '
          'kLongRunningWithoutTaskStatus 并写明理由。\n${missing.join('\n')}',
    );
    for (final String id in kLongRunningWithoutTaskStatus.keys) {
      final FushiOp? op = catalog[id];
      expect(op?.longRunning, isTrue, reason: '$id：豁免表里的操作已不存在或不再 longRunning');
      expect(op?.taskStatus, isNull, reason: '$id：已有 taskStatus，从豁免表删掉');
    }
  });

  test('旧路径：表态参数真被路由读取', () {
    // OpSpec 来路的操作不在这里查：表态参数只能经 OpArgs.gate 读，FushiOp.run 在实现
    // 成功返回后查读没读（没读抛 StateError），见 fushi_cli 的 op_spec_test.dart。
    final String routeSources = <String>[
      for (final FileSystemEntity f in Directory('lib/src/ops').listSync())
        if (f is File &&
            f.path.endsWith('.dart') &&
            f.uri.pathSegments.last.startsWith('ctl_'))
          f.readAsStringSync(),
      // 复习的路由本体在 engine（app 的 ctl_srs_routes.dart 只是装配），表态参数的读取点在那里。
      File(
        '../packages/fushi_engine/lib/srs/srs_ctl_routes.dart',
      ).readAsStringSync(),
    ].join('\n');
    for (final FushiOp op in catalog.ops) {
      if (op.route.op != null) continue;
      for (final OpParam gate in op.params.where((OpParam p) => p.userGate)) {
        expect(
          routeSources.contains("'${gate.name}'"),
          isTrue,
          reason: '${op.id}：表态参数 ${gate.name} 在路由源码里找不到读取点',
        );
      }
    }
  });
}
