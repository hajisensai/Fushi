// 守卫：ios/macos 下 Flutter 机器生成文件不得被 git 跟踪。
//
// 背景（BUG 记录见 docs/bugs/）：fushi/ios/Flutter/Generated.xcconfig 等文件曾被
// 强行 add 入库，内容烧死了单台机器的 FLUTTER_ROOT（如 D:\flutter_sdk\...），导致
// 其它机器 checkout 后 iOS `pod install` 直接报
// "cannot load such file -- .../D:\flutter_sdk\...\podhelper" 失败。
// 这些文件本就在 fushi/ios/.gitignore 里声明忽略，必须由每台机器的 flutter 工具
// 自行生成。本测试用 `git ls-files -i -c` 找出「已跟踪但被 .gitignore 忽略」的文件，
// 排除有意跟踪的图标资源（被 fushi/.gitignore 的 golden-diff `*.png` 规则连带匹配）。
//
// 纯 dart:io + git CLI，不依赖 Flutter 运行时；从 fushi/ 向上找仓库根。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 从当前 cwd 向上找含 docs/BUGS.md 的仓库根。
Directory _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File('${dir.path}/docs/BUGS.md').existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('找不到含 docs/BUGS.md 的仓库根（从 ${Directory.current.path} 向上）');
}

/// 有意跟踪、但被宽泛 ignore 规则（`*.png`）连带匹配的路径，不算违规。
bool _isIntentionallyTracked(String path) {
  return path.contains('/Assets.xcassets/');
}

void main() {
  test('ios/macos 不跟踪 .gitignore 声明忽略的 Flutter 生成文件', () {
    final root = _repoRoot();
    final ProcessResult result = Process.runSync(
      'git',
      [
        'ls-files',
        '-i',
        '-c',
        '--exclude-standard',
        '--',
        'fushi/ios',
        'fushi/macos',
      ],
      workingDirectory: root.path,
    );
    if (result.exitCode != 0) {
      // 环境无 git（如某些打包环境）时不阻塞其它测试。
      markTestSkipped('git 不可用：${result.stderr}');
      return;
    }
    final List<String> offenders = (result.stdout as String)
        .split('\n')
        .map((String l) => l.trim())
        .where((String l) => l.isNotEmpty && !_isIntentionallyTracked(l))
        .toList();
    expect(
      offenders,
      isEmpty,
      reason: '这些文件被 .gitignore 声明忽略却仍被 git 跟踪（会把单机生成内容'
          '如 FLUTTER_ROOT 烧进仓库，弄坏其它机器的 iOS/macOS 构建）。'
          '用 `git rm --cached <file>` 移出跟踪：\n${offenders.join('\n')}',
    );
  });
}
