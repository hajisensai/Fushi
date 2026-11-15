import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Dockerfile 的续行必须是真换行。
///
/// PR #3071 的 `tool/linux/flatpak/Dockerfile` 把「`\` + 换行」写成了字面量的
/// `\n`：`apt-get install ... curl \n      ostree gnupg`。shell 把未加引号的 `\n`
/// 读成字母 `n`，于是 apt 去装一个叫 `n` 的包，镜像构建直接失败——而 Linux
/// Flatpak 的 baseapp / linux / publish 三个 CI job 都先 `docker build` 这个镜像，
/// 本地没有 Docker 时只能靠这条守卫在合入前拦住。
///
/// 判据：空白之后紧跟 `\n` 再跟空白（续行被压成一行的形状）。`printf '...\n...'`
/// 这类合法转义前面不是空白，不受影响。
void main() {
  final Directory repoRoot = Directory('..');
  final RegExp flattenedContinuation = RegExp(r'\s\\n\s');

  List<File> dockerfiles() {
    final List<File> out = <File>[];
    for (final FileSystemEntity e in Directory(
      p.join(repoRoot.path, 'tool'),
    ).listSync(recursive: true, followLinks: false)) {
      if (e is File && p.basename(e.path).startsWith('Dockerfile')) out.add(e);
    }
    return out;
  }

  test('the Flatpak and Linux build images are among the checked files', () {
    final List<String> names = dockerfiles()
        .map((File f) => p.relative(f.path, from: repoRoot.path))
        .map((String s) => s.replaceAll(r'\', '/'))
        .toList();
    expect(names, contains('tool/linux/flatpak/Dockerfile'));
    expect(names, contains('tool/linux/Dockerfile'));
  });

  test('no Dockerfile under tool/ has a line continuation flattened into a '
      'literal \\n', () {
    final List<String> offenders = <String>[];
    for (final File f in dockerfiles()) {
      final List<String> lines = f.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        if (flattenedContinuation.hasMatch(lines[i])) {
          offenders.add('${f.path}:${i + 1}: ${lines[i].trim()}');
        }
      }
    }
    expect(offenders, isEmpty);
  });
}
