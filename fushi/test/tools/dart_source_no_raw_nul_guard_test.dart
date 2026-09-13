// 守卫：入库的 .dart 源文件里不得出现**裸 NUL 字节**。
//
// 背景（真实事故，本守卫因它而生）：`packages/fushi_core/lib/src/database/database.dart`
// 曾把 SQLite 魔数写成字面量 'SQLite format 3<裸NUL>'（16 字节），另有两处复合键
// 用裸 NUL 当分隔符。NUL 本身是**故意的**、语义正确，问题出在文件层面——
//
//   git 的二进制探测只要在文件里看到 NUL 就判定为 binary，于是：
//     * `git merge` 对该文件**拒绝三方合并**，直接保留 ours 并标 CONFLICT，
//       且**不写冲突标记**；
//     * 粗心一解（git add 了事）就把对方整片改动静默丢掉；
//     * `git diff` 只显示 "Bin xxx -> yyy bytes"，review 时看不见任何内容。
//
// 这在一个 6000 行、多 agent 高频并发改动的 schema 热点文件上是数据丢失级隐患：
// 一次真实合并里，develop 的 schema v56（galgames.launch_args）差点就此消失。
//
// 修法是纯文件层面的：把裸 NUL 写成 Dart 的 4 位十六进制 Unicode 转义。
// 运行时**逐字节等价**（转义与裸字节产生同一个 String），但文件变回纯文本，
// git 从此正常做三方合并、diff 可读。
//
// 纯 dart:io，不依赖 Flutter 运行时；从 fushi/ 向上找仓库根。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../helpers/scan_scale.dart';

/// 从当前 cwd 向上找含 docs/BUGS.md 的仓库根。
Directory _repoRoot() {
  Directory dir = Directory.current;
  for (int i = 0; i < 6; i++) {
    if (File('${dir.path}/docs/BUGS.md').existsSync()) return dir;
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('找不到含 docs/BUGS.md 的仓库根（从 ${Directory.current.path} 向上）');
}

/// `packages/` 下**不归我们管**的包：上游 fork / vendored / stub。
/// 它们的源码由上游决定，不参与本仓的并发合并热点。
///
/// 这是一份**排除**清单，不是准入清单——方向是刻意的：新加的自有包必须
/// **默认落进**扫描面。反过来写（枚举「自有包」）就是这条守卫上一版的 bug：
/// 清单是字面量，新包 `packages/fushi_server` 加进仓库时没人会想到回来改它，
/// 于是守卫对着一个不存在的世界照常绿。
const Set<String> _vendoredPackages = <String>{
  'flutter_inappwebview_windows',
  'gamepads_windows',
  'gamepads_android_stub',
};

/// 扫描范围：本仓自有的 Dart 源码根，**从磁盘枚举**而不是写死清单。
///
/// = `fushi/{lib,test}` + `packages/<非 vendored 包>/{lib,test}`。
///
/// 含 `test/` 是因为 NUL 的危害是**文件层面**的（git 判 binary → 拒绝三方合并 →
/// 静默丢改动），跟这个文件是产品代码还是测试代码毫无关系。
List<String> _scanRoots(Directory root) {
  final List<String> roots = <String>['fushi/lib', 'fushi/test'];

  final Directory packages = Directory('${root.path}/packages');
  final List<String> names = packages
      .listSync(followLinks: false)
      .whereType<Directory>()
      .map((Directory d) => d.path.split(RegExp(r'[/\\]')).last)
      .where((String n) => !_vendoredPackages.contains(n))
      .toList()
    ..sort();

  for (final String name in names) {
    for (final String sub in const <String>['lib', 'test']) {
      // 只登记真实存在的目录：这样扫描根数就是**实测的覆盖面**，不会被
      // 「有目录名但没源码」的空壳撑出一个虚高的数去骗过下面的哨兵。
      if (Directory('${root.path}/packages/$name/$sub').existsSync()) {
        roots.add('packages/$name/$sub');
      }
    }
  }
  return roots;
}

void main() {
  final Directory root = _repoRoot();

  test('入库 .dart 源码不含裸 NUL 字节（否则 git 判二进制 → 三方合并被拒 → 静默丢改动）', () {
    final List<String> offenders = <String>[];
    int scanned = 0;

    final List<String> scanRoots = _scanRoots(root);

    for (final String rel in scanRoots) {
      final Directory dir = Directory('${root.path}/$rel');
      if (!dir.existsSync()) continue;

      for (final FileSystemEntity entity
          in dir.listSync(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('.dart')) continue;
        scanned++;

        final List<int> bytes = entity.readAsBytesSync();
        final int nulCount = bytes.where((int b) => b == 0).length;
        if (nulCount > 0) {
          offenders.add('${entity.path}（$nulCount 个裸 NUL）');
        }
      }
    }

    // 两条哨兵缺一不可：文件总数挡不住「packages 整片没扫到」——`fushi/{lib,test}`
    // 一家就有 4300+ 个 .dart，足够单独顶穿任何总数下界，而那时 packages 的覆盖
    // 已经归零、守卫已经瞎了。所以包数要单独钉。
    final Set<String> scannedPackages = scanRoots
        .where((String r) => r.startsWith('packages/'))
        .map((String r) => r.split('/')[1])
        .toSet();
    expectScanScale(scannedPackages.length,
        what: 'packages/ 下枚举到的非 vendored 包', atLeast: 5, measured: 6);

    expectScanScale(scanned,
        what: '${scanRoots.length} 个扫描根下的 .dart', atLeast: 3600, measured: 4589);

    expect(
      offenders,
      isEmpty,
      reason: '以下文件含裸 NUL 字节，会被 git 判为 binary、无法三方合并（合并时会'
          '静默丢弃对方改动）。请改用 Dart 的 4 位十六进制 Unicode 转义写法——'
          '运行时逐字节等价，但文件保持纯文本：\n${offenders.join('\n')}',
    );
  });
}
