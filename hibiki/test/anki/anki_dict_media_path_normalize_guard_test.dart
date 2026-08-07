import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-902 守卫：制卡时词典媒体（外字 gaiji + 词典内嵌图片）登记进 payload 的 `path`
/// 必须先经 `normalizeDictMediaPath` 归一化（trim / `\\`→`/` / 去开头 `./` 或 `/`），
/// 与显示路径（`rewriteDictionaryMediaPath`）同款。
///
/// 病根：`getMediaFilename` 曾用**生 path** 登记，`writeDictionaryMediaCache` 再拿生
/// path 引 `FushiDicts.getMediaFile` → path 带开头 `./`/`/` 的词典命中失败 → 字节不落盘
/// → AnkiConnect/AnkiDroid/AnkiMobile 三个 repo 读不到缓存 → 卡片里
/// `<img src="fushi_dict_N.ext">` 占位符不被替换成真实文件名，留成坏图。显示路径早已
/// 归一化，故弹窗里图看得见、只制卡掉图（外字/内容图混排时脏 path 的词典排在后面就末尾掉图）。
///
/// 归一化后 payload.path 干净，writer 与三个 repo 都按同一干净 path 的 sha1 命名缓存
/// 文件，契约一致。popup.js 的运行时 node 守卫 CI 不跑，故在此对**三份镜像**的源码做
/// 静态断言以进 CI 真跑，并锁死三镜像一致（防某一份漂移退回生 path）。
void main() {
  const List<String> popupMirrors = <String>[
    'assets/popup/popup.js',
    'assets/browser_extension/vendor/popup.js',
    // 第三份镜像在仓库根 tools/ 下（本测试 cwd 是 hibiki/）。
    '../tools/browser-extension/vendor/popup.js',
  ];

  /// 抽取 `function getMediaFilename(...) { ... }` 的函数体（单层花括号，该函数无嵌套块）。
  String getMediaFilenameBody(String source, String label) {
    final int start = source.indexOf('function getMediaFilename(');
    expect(start, greaterThanOrEqualTo(0),
        reason: '$label 应存在 getMediaFilename 函数');
    final int brace = source.indexOf('{', start);
    expect(brace, greaterThanOrEqualTo(0),
        reason: '$label getMediaFilename 应有函数体');
    int depth = 0;
    for (int i = brace; i < source.length; i++) {
      final String ch = source[i];
      if (ch == '{') depth++;
      if (ch == '}') {
        depth--;
        if (depth == 0) return source.substring(brace + 1, i);
      }
    }
    fail('$label getMediaFilename 花括号未闭合');
  }

  test('三份 popup.js 的 getMediaFilename 都先归一化 path（不再用生 path 登记）', () {
    for (final String rel in popupMirrors) {
      final File f = File(rel);
      expect(f.existsSync(), isTrue, reason: '缺镜像文件: $rel');
      final String body = getMediaFilenameBody(f.readAsStringSync(), rel);

      // 必须调用 normalizeDictMediaPath(path) 并把归一化结果作为 key/登记的 path。
      expect(body.contains('normalizeDictMediaPath(path)'), isTrue,
          reason: '$rel getMediaFilename 必须用 normalizeDictMediaPath(path) 归一化，'
              '否则脏 path 的词典制卡掉图（BUG-902）');
      // 登记进 currentDictionaryMedia 的 path 字段必须是归一化后的值，不能是生 path。
      expect(body.contains('path: normalizedPath'), isTrue,
          reason:
              '$rel 登记的 path 必须是归一化后的 normalizedPath（与 writer/repo 命名契约一致）');
      // 显式挡住旧写法：裸 `path,`（登记生 path）不得再出现在对象字面量里。
      expect(RegExp(r'\n\s*path,\s*\n').hasMatch(body), isFalse,
          reason: '$rel 不得再用生 path 登记（BUG-902 回归）');
    }
  });

  test('三份 popup.js 的 getMediaFilename 逐字一致（三镜像 parity）', () {
    final List<String> bodies = <String>[
      for (final String rel in popupMirrors)
        getMediaFilenameBody(File(rel).readAsStringSync(), rel),
    ];
    for (int i = 1; i < bodies.length; i++) {
      expect(bodies[i], bodies.first,
          reason: 'popup.js 镜像 ${popupMirrors[i]} 的 getMediaFilename 与主 '
              '${popupMirrors.first} 不一致；三镜像必须逐字同步');
    }
  });
}
