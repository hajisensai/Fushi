import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/source_guard.dart';

/// 守卫：每个 native Rust crate 的新鲜度指纹都带上「这是哪个 worktree」。
///
/// 洞的形状（2026-11-11 实测）：cargo 给工作区内 crate 算单元哈希用的是相对工作区的路径，
/// 不同 worktree 的 `fushi_fsrs` 是同一个 `.fingerprint/fushi_fsrs-<哈希>`，新鲜度只比源文件
/// mtime。多个 worktree 共用一个 `CARGO_TARGET_DIR` 时，A 刚编出的产物会被 B 当成自己的
/// 新鲜产物直接拿来跑——B 侧加了一个必挂的测试，`cargo test` 0.3 秒报 6 passed、exit 0，
/// 一行没编。测的不是自己的代码，假绿 / 假红都不会有任何提示。
///
/// 修法分两半，缺一半就退回原状，而且是静默的（照常编、照常绿），所以两半都钉在这里：
///
/// - 仓库根 `.cargo/config.toml` 的 `[env]` 用 `relative = true` 把本 worktree 的根目录
///   解析成绝对路径，放进 `FUSHI_WORKTREE_ROOT`；
/// - 每个 crate 的入口文件用 `option_env!("FUSHI_WORKTREE_ROOT")` 读它一次：rustc 把读到
///   的值记进 dep-info 的 `env-dep`，cargo 换了 worktree 就判 dirty、重编本仓 crate。
///
/// 新加 crate 时照抄别的 crate 的 Cargo.toml / 构建脚本不会带上入口文件里那一行，本守卫按
/// 目录枚举 `native/*/Cargo.toml`，漏了就红。
void main() {
  // 测试 cwd 是 `fushi/`。
  final String repoRoot = p.normalize(p.absolute('..'));
  const String variable = 'FUSHI_WORKTREE_ROOT';

  String read(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');

  /// `native/` 下直接带 Cargo.toml 的目录（C++ 模块没有 Cargo.toml，不在此列）。
  List<Directory> crates() {
    final List<Directory> out =
        Directory(p.join(repoRoot, 'native'))
            .listSync()
            .whereType<Directory>()
            .where(
              (Directory d) => File(p.join(d.path, 'Cargo.toml')).existsSync(),
            )
            .toList()
          ..sort((Directory a, Directory b) => a.path.compareTo(b.path));
    return out;
  }

  test('仓库根 .cargo/config.toml 把 worktree 根目录放进 $variable', () {
    final String config = maskHashComments(
      read(p.join(repoRoot, '.cargo', 'config.toml')),
    );
    expect(config, contains('\n[env]\n'), reason: '缺 [env] 表');
    expect(
      RegExp(
        '^$variable'
        r'\s*=\s*\{\s*value\s*=\s*""\s*,\s*relative\s*=\s*true\s*\}\s*$',
        multiLine: true,
      ).hasMatch(config),
      isTrue,
      reason:
          '$variable 必须是 { value = "", relative = true }：relative 才会按本文件位置解析成'
          '本 worktree 的绝对路径，写死的值各 worktree 相同、起不到区分作用',
    );
  });

  test('每个 native crate 的入口文件都读一次 $variable', () {
    final List<Directory> found = crates();
    // 目录枚举型守卫：枚举不到东西就是守卫自己坏了（路径变了），不能当成全绿。
    expect(
      found.length,
      greaterThanOrEqualTo(8),
      reason: 'native/ 下只枚举到 ${found.length} 个 Rust crate，守卫的枚举方式失效了',
    );

    final List<String> missing = <String>[];
    for (final Directory crate in found) {
      final List<File> entries = <File>[
        File(p.join(crate.path, 'src', 'lib.rs')),
        File(p.join(crate.path, 'src', 'main.rs')),
      ].where((File f) => f.existsSync()).toList();
      expect(
        entries,
        isNotEmpty,
        reason: '${p.basename(crate.path)}：没有 src/lib.rs 也没有 src/main.rs',
      );
      for (final File entry in entries) {
        // 掩掉注释：只留一行同文字的注释、删掉真正的读取时不能仍然算有。
        final String code = maskComments(read(entry.path));
        if (!code.contains('option_env!("$variable")')) {
          missing.add(
            p.relative(entry.path, from: repoRoot).replaceAll(r'\', '/'),
          );
        }
      }
    }
    expect(
      missing,
      isEmpty,
      reason:
          '这些入口文件没有 `const _: Option<&str> = option_env!("$variable");`：'
          '共用 CARGO_TARGET_DIR 时会静默拿到别的 worktree 的产物',
    );
  });

  test('crate 自己的 .cargo/config.toml 不改写 $variable', () {
    for (final Directory crate in crates()) {
      final File config = File(p.join(crate.path, '.cargo', 'config.toml'));
      if (!config.existsSync()) continue;
      expect(
        maskHashComments(read(config.path)),
        isNot(contains(variable)),
        reason:
            '${p.relative(config.path, from: repoRoot)}：离工作目录更近的配置优先，'
            '在这里给 $variable 写值会盖掉仓库根那份按 worktree 解析的路径',
      );
    }
  });
}
