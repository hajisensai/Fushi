// 换代整批的源码守卫（docs/specs/2026-11-15-srs-gen4-g7-g11-plan.md §6「源码守卫」）里 Dart 侧的三条；内核侧三条在
// native/fushi_fsrs/src/store/gen4/guards_tests.rs，备份两条在 backup_srs_gen4_guard_test.dart。都按目录枚举生产源码
// （fushi/lib 与各包 lib/），新加的文件自动进来；注释里提到不算。
//
// 1. 活代码里没有旧表名：协议 3 的 `sync2_*` 表名（从内核协议 3 存储层的 `CREATE TABLE` 里取，不手抄）不出现在 Dart
//    生产代码里。`srs_*` 那九张归 srs_store_ownership_guard_test.dart（只放行主库老形态兼容代码）。
// 2. 每条命令都登记：Dart 发给内核的每个 `'op': <值>`（字面量，条件表达式两侧都算）都在内核的命令登记表里——`store/gen4/dispatch.rs`
//    `wiring` 里标成 `Wired` 的，或全局入口 `lib.rs` `dispatch` 的臂；登记成 `Removed` 的新代不再接，Dart 发了就是
//    回退。规划写的是 `store/ops.rs`，它只在没合入的 `pr/srs-ffi-op-meta` 分支上，集成分支上的登记表就是 `wiring`。
//    只看复习内核的调用面（[_srsSurface]），别的子进程 / 插件协议也用 `'op'` 键。
// 3. 生产代码里没有把目录名当 uid 的读法（设计 §5.1 2026-11-17 修订：位置目录名一律等于**某个** profile uid，但不一定
//    是本机 profile 的）：凡是从同步位置拿到目录名的文件（列 `fushi-srs` 命名空间、解析互联 host 路径、读
//    `SrsRemoteProfile`），都不许把目录名当本机 profile uid 用——传给 `profileUid:`、与 `*profileUid` 比相等、拿去查
//    「哪个本机 uid」。眼下仍在的几处逐条登记归属（[_kKnownDirAsUid]），修掉一处就删一条（死条目同样报错）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/source_guard.dart';

/// 仓库根（测试在 fushi/ 下跑）。
final Directory _repo = Directory.current.parent;

String _rel(File f) =>
    p.relative(f.path, from: _repo.path).replaceAll(r'\', '/');

/// 生产 Dart 源码：fushi/lib 与 packages/*/lib，不含生成文件。
List<File> _productionDart() {
  final List<Directory> roots = <Directory>[
    Directory(p.join(_repo.path, 'fushi', 'lib')),
    for (final FileSystemEntity e in Directory(
      p.join(_repo.path, 'packages'),
    ).listSync())
      if (e is Directory && Directory(p.join(e.path, 'lib')).existsSync())
        Directory(p.join(e.path, 'lib')),
  ];
  return <File>[
    for (final Directory root in roots)
      for (final FileSystemEntity e in root.listSync(recursive: true))
        if (e is File &&
            e.path.endsWith('.dart') &&
            !e.path.endsWith('.g.dart'))
          e,
  ]..sort((File a, File b) => a.path.compareTo(b.path));
}

String _read(String relToRepo) => File(
  p.join(_repo.path, relToRepo),
).readAsStringSync().replaceAll('\r\n', '\n');

/// [src] 里 `head` 起、到行首 `}` 为止的函数体。
String _fnBody(String src, String head) {
  final int from = src.indexOf(head);
  expect(from, isNonNegative, reason: 'missing $head');
  final int end = src.indexOf('\n}\n', from);
  expect(end, isNonNegative);
  return src.substring(from, end);
}

/// Rust 匹配臂头里的命令名：缩进正好 [indent] 格、以字符串字面量开头（rustfmt 折行的续行以 `| "` 开头），到 `=>` 为止；
/// 值是 `=>` 之后的文字（臂体另起一行的 `=> {` 取下一行）。
Map<String, String> _rustArms(String body, int indent) {
  final String pad = ' ' * indent;
  final Map<String, String> out = <String, String>{};
  final List<String> lines = body.split('\n');
  List<String>? cur;
  for (int i = 0; i < lines.length; i++) {
    final String line = lines[i];
    final bool atIndent =
        line.startsWith(pad) && !line.substring(indent).startsWith(' ');
    final String text = line.trimLeft();
    if (atIndent && text.startsWith('"')) {
      cur = <String>[];
    } else if (!(atIndent && text.startsWith('| "') && cur != null)) {
      cur = null;
      continue;
    }
    final int arrow = line.indexOf('=>');
    final String head = arrow < 0 ? line : line.substring(0, arrow);
    for (final RegExpMatch m in RegExp(r'"([a-z0-9_]+)"').allMatches(head)) {
      cur.add(m.group(1)!);
    }
    if (arrow >= 0) {
      String tail = line.substring(arrow + 2).trim();
      if (tail == '{' && i + 1 < lines.length) tail = lines[i + 1].trim();
      for (final String op in cur) {
        out[op] = tail;
      }
      cur = null;
    }
  }
  return out;
}

/// 协议 3 的 `sync2_*` 表名：内核 `store/` 下除新代以外的存储层源码里建的，减去新代自己也建的同名表。
Set<String> _protocol3Sync2Tables() {
  final RegExp create = RegExp(r'CREATE TABLE (?:IF NOT EXISTS )?([a-z0-9_]+)');
  final Directory store = Directory(
    p.join(_repo.path, 'native', 'fushi_fsrs', 'src', 'store'),
  );
  final String gen4 = p.join(store.path, 'gen4');
  final Set<String> old = <String>{};
  final Set<String> fresh = <String>{};
  for (final FileSystemEntity e in store.listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.rs')) continue;
    final Set<String> into = e.path.startsWith(gen4) ? fresh : old;
    for (final RegExpMatch m in create.allMatches(e.readAsStringSync())) {
      into.add(m.group(1)!);
    }
  }
  return <String>{
    for (final String t in old)
      if (t.startsWith('sync2_') && !fresh.contains(t)) t,
  };
}

/// 复习内核的调用面：fushi_srs 包、路径里带 `srs` 段的文件（`.../srs/...`、`srs_*.dart`），以及 import 了
/// `package:fushi_srs/` 或 `package:fushi_engine/srs/` 的文件。别的 `'op'` 键是追踪插件、TTS 子进程、音乐插件等
/// 各自的协议，不归这里管。
bool _srsSurface(String rel, String src) =>
    rel.startsWith('packages/fushi_srs/lib/') ||
    RegExp(r'/srs/|/srs_[^/]*\.dart$').hasMatch(rel) ||
    src.contains('package:fushi_srs/') ||
    src.contains('package:fushi_engine/srs/');

/// 值不是字符串字面量的 `'op'`（`<文件>: <值表达式>` → 为什么不归内核登记表管）。修掉 / 不在了就删条目（死条目同样报错）。
const Map<String, String> _kOpForwarders = <String, String>{
  // 互联远端复习的 V2 协议（POST /api/srs/remote2/call）：动词由主机 srs_remote_store_routes.dart → service.call
  // 按自己的路由处理，不直接进内核 dispatch；动词本身是同文件 _read / _write 调用处的字面量。
  'fushi/lib/src/srs/srs_remote_store_client.dart: op':
      'remote store V2 verb, routed by the host service, not a kernel command',
  // 搜索树 JSON 里属性比较节点（`{'t': 'prop', 'p': …, 'op': <SrsSearchCompare>}`）的比较符，不是命令键。
  'packages/fushi_srs/lib/src/search/search_kernel.dart: compare.name':
      'comparison operator of a search tree node, not a command',
};

/// [src]（已去注释）里每个 `'op': <值>` 的值：取到深度 0 的 `,` 或收尾括号为止（字符串里的不算）；条件表达式
/// `c ? x : y` 拆成两侧（可嵌套），其余原样（去首尾空白）。
List<String> _opValueBranches(String src) {
  final List<String> out = <String>[];
  for (final RegExpMatch m in RegExp(r'''['"]op['"]\s*:''').allMatches(src)) {
    int i = m.end;
    int depth = 0;
    String? quote;
    final StringBuffer b = StringBuffer();
    while (i < src.length) {
      final String c = src[i];
      if (quote != null) {
        b.write(c);
        if (c == r'\' && i + 1 < src.length) {
          b.write(src[i + 1]);
          i += 2;
          continue;
        }
        if (c == quote) quote = null;
        i++;
        continue;
      }
      if (c == "'" || c == '"') {
        quote = c;
      } else if ('([{'.contains(c)) {
        depth++;
      } else if (')]}'.contains(c)) {
        if (depth == 0) break;
        depth--;
      } else if (c == ',' && depth == 0) {
        break;
      }
      b.write(c);
      i++;
    }
    out.addAll(_ternaryBranches(b.toString().trim()));
  }
  return out;
}

/// `c ? x : y` → [x, y] 各自再拆；不是条件表达式就是它自己。`??` 与 `?.` 不算。
List<String> _ternaryBranches(String e) {
  bool isTernaryMark(int i) =>
      e[i] == '?' &&
      (i + 1 >= e.length || (e[i + 1] != '?' && e[i + 1] != '.')) &&
      (i == 0 || e[i - 1] != '?');
  int depth = 0;
  String? quote;
  int q = -1;
  int colon = -1;
  int nest = 0;
  for (int i = 0; i < e.length; i++) {
    final String c = e[i];
    if (quote != null) {
      if (c == r'\') {
        i++;
      } else if (c == quote) {
        quote = null;
      }
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
    } else if ('([{'.contains(c)) {
      depth++;
    } else if (')]}'.contains(c)) {
      depth--;
    } else if (depth == 0 && isTernaryMark(i)) {
      if (q < 0) {
        q = i;
      } else {
        nest++;
      }
    } else if (depth == 0 && c == ':' && q >= 0) {
      if (nest == 0) {
        colon = i;
        break;
      }
      nest--;
    }
  }
  if (q < 0 || colon < 0) return <String>[e];
  return <String>[
    ..._ternaryBranches(e.substring(q + 1, colon).trim()),
    ..._ternaryBranches(e.substring(colon + 1).trim()),
  ];
}

/// 眼下仍把位置目录名当本机 profile uid 用的地方（文件 → 去掉首尾空白后的整行代码），各自归属待修。修掉就删条目。
const Map<String, List<String>> _kKnownDirAsUid = <String, List<String>>{
  // 归 G9-5（profile 关联）：清理「本设备换 uid 时离开的旧 uid」孤儿目录。SrsRemoteProfile.uid 是位置目录名；
  // 拿它与本机 profile uid、退役 uid 名单、本机 profile 表比，并当 profileUid 传给 srsRemoveOwnProfileFolder。
  // 协议 3 的目录名就是 uid 所以当年成立；新代绑到别的目录（collection_adopt 结论 bound）之后不成立。
  'packages/fushi_engine/lib/srs/srs_profile_link.dart': <String>[
    'if (r.uid == store.profileUid || r.writers.isEmpty) continue;',
    'if (!retiredUids.contains(r.uid)) continue;',
    'if (!ownOnly || await _uidTakenLocally(r.uid)) continue;',
    'profileUid: r.uid,',
  ],
};

void main() {
  final List<File> files = _productionDart();

  test('扫描面', () {
    expect(files.length, greaterThan(1000), reason: 'cwd 应是 fushi/');
  });

  test('活代码里没有协议 3 的 sync2_* 表名', () {
    final Set<String> tables = _protocol3Sync2Tables();
    expect(
      tables,
      containsAll(<String>['sync2_ops', 'sync2_self', 'sync2_devices']),
      reason: '表名解析不对',
    );
    final RegExp name = RegExp('\\b(${tables.join('|')})\\b');
    final List<String> offenders = <String>[
      for (final File f in files)
        if (name.hasMatch(maskComments(f.readAsStringSync())))
          '${_rel(f)}: ${name.firstMatch(maskComments(f.readAsStringSync()))!.group(0)}',
    ];
    expect(offenders, isEmpty, reason: '协议 3 的表只在内核冻结侧出现');
  });

  test('Dart 发给内核的每条命令都在登记表里', () {
    final Map<String, String> wiring = _rustArms(
      _fnBody(
        _read('native/fushi_fsrs/src/store/gen4/dispatch.rs'),
        'pub fn wiring(',
      ),
      8,
    );
    expect(wiring.length, greaterThan(120), reason: 'wiring 解析不对');
    // 全局入口（不针对已打开的库）：`ffsrs_call` 的 `dispatch` 与训练入口 `ffsrs_fit`。
    final String lib = _read('native/fushi_fsrs/src/lib.rs');
    final Set<String> global = <String>{
      ..._rustArms(_fnBody(lib, 'fn dispatch(req: &Value)'), 8).keys,
      ..._rustArms(_fnBody(lib, 'pub extern "C" fn ffsrs_fit('), 12).keys,
    };
    expect(
      global,
      containsAll(<String>['version', 'gen4_migrate_run', 'evaluate_tss']),
      reason: 'lib.rs 全局入口解析不对',
    );
    final List<String> offenders = <String>[];
    final Set<String> forwardersSeen = <String>{};
    int sent = 0;
    for (final File f in files) {
      final String rel = _rel(f);
      final String src = maskComments(f.readAsStringSync());
      if (!_srsSurface(rel, src)) continue;
      for (final String branch in _opValueBranches(src)) {
        final String? name = RegExp(
          r'''^['"]([a-z0-9_]+)['"]$''',
        ).firstMatch(branch)?.group(1);
        if (name == null) {
          final String key = '$rel: $branch';
          if (_kOpForwarders.containsKey(key)) {
            forwardersSeen.add(key);
          } else {
            offenders.add(
              '$key (not a literal; use a literal or register in _kOpForwarders)',
            );
          }
          continue;
        }
        final String? w = wiring[name];
        if (w == 'Wired,' || global.contains(name)) {
          sent++;
          continue;
        }
        offenders.add(
          '$rel: $name (${w == null ? 'not registered' : 'registered as $w'})',
        );
      }
    }
    expect(sent, greaterThan(100), reason: '命令字面量解析不对');
    expect(offenders, isEmpty);
    expect(
      _kOpForwarders.keys.where((String k) => !forwardersSeen.contains(k)),
      isEmpty,
      reason: '登记了却已不存在的转发条目',
    );
  });

  test('命令值解析：字面量、条件表达式两侧、变量', () {
    expect(
      _opValueBranches(
        "a({'op': 'apply', 'x': 1}); b({\n  'op': existed == null ? 'apply' : 'import_drafts',\n}); "
        "c({'op': op, 'args': a}); d({\"op\": \"study\"}); e({'op': f(x, y)});",
      ),
      <String>[
        "'apply'",
        "'apply'",
        "'import_drafts'",
        'op',
        '"study"',
        'f(x, y)',
      ],
    );
  });

  test('生产代码里没有把位置目录名当本机 profile uid 的读法', () {
    // 拿到目录名的源头：列 fushi-srs 命名空间、解析互联 host 路径、读列出来的 SrsRemoteProfile。
    final RegExp source = RegExp(
      r'\bSrsRemoteProfile\b|\bsrsHostPathDir\(|kSrsSync2Namespace',
    );
    // 目录名（列出项的 `.uid` / `.name`）当 profile uid 用。
    final List<RegExp> misuse = <RegExp>[
      RegExp(r'\bprofileUid:\s*\w+\.(uid|name)\b'),
      RegExp(r'\b\w+\.(uid|name)\s*==\s*[\w.]*[pP]rofileUid\b'),
      RegExp(r'[\w.]*[pP]rofileUid\s*==\s*\w+\.(uid|name)\b'),
      RegExp(r'(?<![\w.])\w*[uU]id\w*(\.contains)?\(\s*\w+\.uid\s*\)'),
    ];
    // 改名前的旧名字（它取的一直是目录名，名字却说是 profile）。
    final RegExp renamed = RegExp(r'\bsrsHostPathProfile\b');
    final List<String> offenders = <String>[];
    final Map<String, Set<String>> seenKnown = <String, Set<String>>{};
    int sources = 0;
    for (final File f in files) {
      final String rel = _rel(f);
      final String src = maskComments(f.readAsStringSync());
      if (renamed.hasMatch(src)) offenders.add('$rel: srsHostPathProfile');
      if (!source.hasMatch(src)) continue;
      sources++;
      final List<String> lines = src.split('\n');
      for (int i = 0; i < lines.length; i++) {
        final String line = lines[i].trim();
        if (!misuse.any((RegExp r) => r.hasMatch(line))) continue;
        if (_kKnownDirAsUid[rel]?.contains(line) ?? false) {
          seenKnown.putIfAbsent(rel, () => <String>{}).add(line);
          continue;
        }
        offenders.add('$rel:${i + 1}: $line');
      }
    }
    // 规模哨兵：同步收尾删了协议 1 位置迁移（srs_location_migration.dart），合流后剩 8 个来源文件。
    expect(sources, greaterThan(7), reason: '目录名来源文件解析不对');
    expect(offenders, isEmpty);
    final List<String> stale = <String>[
      for (final MapEntry<String, List<String>> e in _kKnownDirAsUid.entries)
        for (final String line in e.value)
          if (!(seenKnown[e.key]?.contains(line) ?? false)) '${e.key}: $line',
    ];
    expect(stale, isEmpty, reason: '已修掉的条目从 _kKnownDirAsUid 删掉');
  });
}
