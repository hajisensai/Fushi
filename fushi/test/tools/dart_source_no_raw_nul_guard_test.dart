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
// 纯 dart:io，不依赖 Flutter 运行时；从 hibiki/ 向上找仓库根。

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

/// 扫描范围：本仓自有的 Dart 源码根。**不含** third_party / vendored 包
/// （上游产物不归我们管，且不参与本仓的并发合并热点）。
const List<String> _scanRoots = <String>[
  'hibiki/lib',
  'hibiki/test',
  'packages/fushi_core/lib',
  'packages/fushi_dictionary/lib',
  'packages/fushi_anki/lib',
  'packages/fushi_audio/lib',
  'packages/fushi_platform/lib',
];

void main() {
  final Directory root = _repoRoot();

  test('入库 .dart 源码不含裸 NUL 字节（否则 git 判二进制 → 三方合并被拒 → 静默丢改动）', () {
    final List<String> offenders = <String>[];
    int scanned = 0;

    for (final String rel in _scanRoots) {
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

    expectScanScale(scanned,
        what: '7 个扫描根下的 .dart', atLeast: 2600, measured: 3235);

    expect(
      offenders,
      isEmpty,
      reason: '以下文件含裸 NUL 字节，会被 git 判为 binary、无法三方合并（合并时会'
          '静默丢弃对方改动）。请改用 Dart 的 4 位十六进制 Unicode 转义写法——'
          '运行时逐字节等价，但文件保持纯文本：\n${offenders.join('\n')}',
    );
  });
}
