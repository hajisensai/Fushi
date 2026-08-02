// 守卫：Windows 文件名黑名单字符集只允许一处真相源（命名统一 G1，BUG-1125）。
//
// 背景：全仓曾有 10+ 份手写 `[\\/:*?"<>|]` 及排列变体，其中 home_video_page 的
// 一份漏写反斜杠（BUG-1125：云视频 id 含 `\` 时字幕与封面落到不同目录）。收敛到
// `lib/src/utils/misc/safe_file_name.dart` 后，本测试扫描 lib/ 源码，禁止再手写
// 该字符类的 RegExp（结构参考 bugs_per_file_guard_test.dart，纯 dart:io）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../helpers/scan_scale.dart';

/// 手写黑名单字符类的指纹子串（覆盖历史上出现过的全部排列变体）。
const List<String> _fingerprints = <String>[
  r':*?"<>|', // [\\/:*?"<>|] / [\/:*?"<>|] / [:*?"<>|] / [...\x00-\x1f]
  r'<>:"/', // [<>:"/\\|?*] / [\x00-\x1F<>:"/\\|?*]
  r':"|?*', // [<>:"|?*\x00-\x1F]
];

/// 唯一允许持有该字符类的真相源。
const String _allowedFile = 'lib/src/utils/misc/safe_file_name.dart';

void main() {
  test('lib/ 下除唯一真相源外不得手写 Windows 文件名黑名单 RegExp', () {
    final Directory libDir = Directory('lib');
    expect(libDir.existsSync(), isTrue,
        reason: '需在 hibiki/ 包根下运行（flutter test 默认即是）');

    final List<String> violations = <String>[];
    final Iterable<File> files = libDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => f.path.endsWith('.dart'));
    expectScanScale(files.length,
        what: 'lib/ 下的 .dart', atLeast: 750, measured: 939);
    for (final File f in files) {
      final String rel = f.path.replaceAll(r'\', '/');
      if (rel == _allowedFile || rel.endsWith('/$_allowedFile')) continue;
      final List<String> lines = f.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        final String line = lines[i];
        // 只匹配真正构造 RegExp 的行；注释/文档里引用历史字符串不算违规。
        if (!line.contains('RegExp(')) continue;
        for (final String fp in _fingerprints) {
          if (line.contains(fp)) {
            violations.add('$rel:${i + 1}: ${line.trim()}');
            break;
          }
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason: 'Windows 文件名黑名单字符集已收敛到 $_allowedFile 的 '
          'safeWindowsFileName / windowsUnsafeFileNameChars——直接复用，'
          '勿再复制字符集（BUG-1125 正是复制时漏了反斜杠）：\n${violations.join('\n')}',
    );
  });
}
