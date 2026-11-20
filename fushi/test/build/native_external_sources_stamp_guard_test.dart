import 'dart:io';

import 'package:test/test.dart';
import 'package:path/path.dart' as p;

/// 守卫（BUG-4988）：预编译原生库的戳记 / 缓存键必须覆盖 crate 经 `#[path = ...]`
/// 编进来的 crate 外源码。
///
/// 洞的形状：`tool/native_libs.ps1` 与 dist worker 的键只哈希 `native/<crate>` 目录，
/// 而 `native/fushi_music/src/lib.rs` 用 `#[path]` 把 `native/fushi_compute/src/legacy_text.rs`
/// 编进库里——改了那个文件，fushi_music 的键不变，本机 / worker 上的旧库被当成新库继续用，
/// 测试跑的是旧判据。
///
/// 钉住：
/// - 每个 `#[path]` 指向 crate 目录外的文件都列在 `native/<crate>/external_sources.txt`；
/// - 列出的文件都存在；
/// - 三个算键的脚本都读这份清单（ps1 自己算，两个 worker 脚本调 `tool/native_source_key.sh`），
///   不再直接拿 `git rev-parse HEAD:native/<crate>` 当键；
/// - fushi_music 的 Rust 门在这些外部文件改动时也触发。
void main() {
  // 测试 cwd 是 `fushi/`。
  final String repo = p.normalize(p.absolute('..'));
  String read(String rel) =>
      File(p.join(repo, rel)).readAsStringSync().replaceAll('\r\n', '\n');

  List<String> externalList(String crate) {
    final File f = File(p.join(repo, 'native', crate, 'external_sources.txt'));
    if (!f.existsSync()) return const <String>[];
    return f
        .readAsLinesSync()
        .map((String l) => l.trim())
        .where((String l) => l.isNotEmpty && !l.startsWith('#'))
        .toList();
  }

  final RegExp pathAttr = RegExp(r'#\[path\s*=\s*"([^"]+)"\s*\]');

  final List<Directory> crates =
      Directory(p.join(repo, 'native'))
          .listSync()
          .whereType<Directory>()
          .where(
            (Directory d) => File(p.join(d.path, 'Cargo.toml')).existsSync(),
          )
          .toList()
        ..sort((Directory a, Directory b) => a.path.compareTo(b.path));

  test('crate 外的 #[path] 源码都列进 external_sources.txt', () {
    final List<String> missing = <String>[];
    int externalSeen = 0;
    for (final Directory crate in crates) {
      final String name = p.basename(crate.path);
      final Directory src = Directory(p.join(crate.path, 'src'));
      if (!src.existsSync()) continue;
      final Set<String> listed = externalList(name).toSet();
      for (final File rs
          in src
              .listSync(recursive: true)
              .whereType<File>()
              .where((File f) => f.path.endsWith('.rs'))) {
        for (final RegExpMatch m in pathAttr.allMatches(
          rs.readAsStringSync(),
        )) {
          final String target = p.normalize(
            p.join(p.dirname(rs.path), m.group(1)!),
          );
          if (p.isWithin(crate.path, target)) continue;
          externalSeen++;
          final String rel = p.posix.joinAll(
            p.split(p.relative(target, from: repo)),
          );
          if (!listed.contains(rel)) missing.add('$name: $rel');
        }
      }
    }
    expect(externalSeen, greaterThan(0), reason: '扫描器没找到任何外部 #[path]');
    expect(missing, isEmpty, reason: '缺 external_sources.txt 条目：$missing');
  });

  test('external_sources.txt 列出的文件都存在', () {
    for (final Directory crate in crates) {
      for (final String rel in externalList(p.basename(crate.path))) {
        expect(
          File(p.join(repo, rel)).existsSync(),
          isTrue,
          reason: '${p.basename(crate.path)}: $rel 不存在',
        );
      }
    }
  });

  test('算键的脚本都把 external_sources.txt 并进键', () {
    final String ps1 = read('tool/native_libs.ps1');
    expect(ps1, contains('external_sources.txt'));
    final String keyScript = read('tool/native_source_key.sh');
    expect(keyScript, contains('external_sources.txt'));
    expect(keyScript, contains('git hash-object --stdin'));
    for (final String rel in <String>[
      'fushi/tool/dist_test/worker_prepare.sh',
      'fushi/tool/dist_test/worker_build.sh',
    ]) {
      final String sh = read(rel);
      expect(sh, contains('tool/native_source_key.sh'), reason: rel);
      expect(
        sh,
        isNot(contains('rev-parse "HEAD:native/')),
        reason: '$rel：键不能只取 native/<crate> 的树哈希',
      );
    }
  });

  test('fushi_music 的 Rust 门在外部源码改动时也触发', () {
    final String gate = read('.github/workflows/native-music-gate.yml');
    for (final String rel in externalList('fushi_music')) {
      expect(gate, contains("- '$rel'"), reason: rel);
    }
  });
}
