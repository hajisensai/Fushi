import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 架构守卫：媒体页（视频 / 阅读器）把键盘焦点的回收**全部**交给
/// `PageFocusOwnership`，不得再各自裸调 `requestFocus`。
///
/// 为什么需要这条守卫：统一之前，视频页 29 处、阅读器页 28 处焦点补丁各自带一套
/// 略有出入的门控（弹窗可见时该不该抢、要不要判路由 isCurrent、要不要等下一帧），
/// 于是新增一个覆盖层就漏一处归还，表现为用户侧「视频/漫画特别容易丢快捷键」。
/// 把回收收敛到单一入口后，判据只有一份（各页的 `_canOwn*Focus`）；这条守卫防止
/// 有人图省事又在某个回调里补一句裸 `requestFocus` 把判据绕过去。
void main() {
  /// 允许出现任何形式 `requestFocus` 的文件（仓库相对路径，`/` 分隔）。
  ///
  /// 扫的是**裸 token**而不是 `<节点>.requestFocus()` 这一种写法：只认后者的话，
  /// `FocusScope.of(context).requestFocus(_focusNode)`、先把节点存进局部变量再调、
  /// 或换成 `node..requestFocus()` 都能绕过守卫——而绕过的后果与直接裸调完全一样
  /// （跳过该页 `_canOwn*Focus` 判据）。按文件放行、按 token 拦截，没有写法能溜。
  const Set<String> requestFocusAllowedFiles = <String>{
    // popup header ↔ 正文之间的焦点来回属于**页面内部**焦点转移（在两个都由
    // Flutter 拥有的节点之间搬运），不是「从原生控件手里夺回」，套 cause 模型是
    // 硬凑。这几处保留裸调，但必须留在 caret 域内。
    'lib/src/pages/implementations/reader_fushi/caret.part.dart',
  };

  const List<String> mediaPageRoots = <String>[
    'lib/src/pages/implementations/video_fushi_page.dart',
    'lib/src/pages/implementations/video_fushi',
    'lib/src/pages/implementations/reader_fushi_page.dart',
    'lib/src/pages/implementations/reader_fushi',
    // 漫画阅读器（pages/implementations/manga_hibiki_page.dart 只是 3 行兼容
    // export，真实现在这里）。它曾是三个媒体页里唯一零焦点回收的那个。
    'lib/src/media/manga/reader',
  ];

  Iterable<File> dartFilesUnder(String path) {
    final FileSystemEntity entity =
        FileSystemEntity.isDirectorySync(path) ? Directory(path) : File(path);
    if (entity is File) return <File>[entity];
    return (entity as Directory)
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => f.path.endsWith('.dart'));
  }

  /// 剥掉注释——注释里合法地讲解 `requestFocus`，扫的是代码。
  /// TODO-2477：走共享词法掩码，串里的 `//`（URL）不再把该行剩余截掉，
  /// 块注释也一并掩掉（旧写法对 `/* requestFocus() */` 零覆盖）。
  String codeOnly(String source) => maskComments(source);

  test('媒体页不得绕过 PageFocusOwnership 裸调 requestFocus', () {
    final List<String> violations = <String>[];
    for (final String root in mediaPageRoots) {
      for (final File file in dartFilesUnder(root)) {
        // CI 跑 Linux、开发机是 Windows：路径分隔符必须归一化后再比对豁免名单，
        // 否则豁免在一端静默失效。
        final String normalized = file.path.replaceAll('\\', '/');
        if (requestFocusAllowedFiles.contains(normalized)) continue;
        final String source = codeOnly(file.readAsStringSync());
        if (!source.contains('requestFocus')) continue;
        for (final String line in source.split('\n')) {
          if (line.contains('requestFocus')) {
            violations.add('$normalized: ${line.trim()}');
          }
        }
      }
    }
    expect(
      violations,
      isEmpty,
      reason: '焦点请求必须经 _focusOwnership.reclaim / reclaimAfterFrame / '
          'guardOverlay —— 任何形式的 requestFocus（含 FocusScope.of(context)'
          '.requestFocus(node) 与经局部变量中转）都会绕过该页的 _canOwn*Focus 判据'
          '（播放器/内容就绪、查词浮层可见、光标态、所有者路由 isCurrent），正是'
          '统一前每个补丁互相漂移的老路。命中：$violations',
    );
  });

  test('三个媒体页都接入了 PageFocusOwnership', () {
    for (final String page in <String>[
      'lib/src/pages/implementations/video_fushi_page.dart',
      'lib/src/pages/implementations/reader_fushi_page.dart',
      'lib/src/media/manga/reader/manga_hibiki_page.dart',
    ]) {
      final String source = File(page).readAsStringSync();
      expect(source, contains('PageFocusOwnership'),
          reason: '$page 必须用统一的焦点所有者');
      expect(source, contains('FocusReclaimCause'),
          reason: '$page 的回收必须自证原因（cause），判据按 cause 分流');
    }
  });
}
