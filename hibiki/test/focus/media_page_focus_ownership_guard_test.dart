import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 架构守卫：媒体页（视频 / 阅读器）把键盘焦点的回收**全部**交给
/// `PageFocusOwnership`，不得再各自裸调 `requestFocus`。
///
/// 为什么需要这条守卫：统一之前，视频页 29 处、阅读器页 28 处焦点补丁各自带一套
/// 略有出入的门控（弹窗可见时该不该抢、要不要判路由 isCurrent、要不要等下一帧），
/// 于是新增一个覆盖层就漏一处归还，表现为用户侧「视频/漫画特别容易丢快捷键」。
/// 把回收收敛到单一入口后，判据只有一份（各页的 `_canOwn*Focus`）；这条守卫防止
/// 有人图省事又在某个回调里补一句裸 `requestFocus` 把判据绕过去。
void main() {
  /// 正文键盘节点名 → 允许出现裸 `requestFocus` 的文件（仓库相对路径，`/` 分隔）。
  const Map<String, Set<String>> bodyFocusNodes = <String, Set<String>>{
    '_videoFocusNode': <String>{},
    '_focusNode': <String>{
      // popup header ↔ 正文之间的焦点来回属于**页面内部**焦点转移（在两个都由
      // Flutter 拥有的节点之间搬运），不是「从原生控件手里夺回」，套 cause 模型是
      // 硬凑。这两处保留裸调，但必须留在 caret 域内。
      'lib/src/pages/implementations/reader_hibiki/caret.part.dart',
    },
  };

  const List<String> mediaPageRoots = <String>[
    'lib/src/pages/implementations/video_hibiki_page.dart',
    'lib/src/pages/implementations/video_hibiki',
    'lib/src/pages/implementations/reader_hibiki_page.dart',
    'lib/src/pages/implementations/reader_hibiki',
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

  test('媒体页不得绕过 PageFocusOwnership 裸调 requestFocus', () {
    final List<String> violations = <String>[];
    for (final String root in mediaPageRoots) {
      for (final File file in dartFilesUnder(root)) {
        // CI 跑 Linux、开发机是 Windows：路径分隔符必须归一化后再比对豁免名单，
        // 否则豁免在一端静默失效。
        final String normalized = file.path.replaceAll('\\', '/');
        final String source = file.readAsStringSync();
        bodyFocusNodes.forEach((String node, Set<String> allowed) {
          if (allowed.contains(normalized)) return;
          final String needle = '$node.requestFocus()';
          if (source.contains(needle)) {
            violations.add('$normalized: $needle');
          }
        });
      }
    }
    expect(
      violations,
      isEmpty,
      reason: '焦点请求必须经 _focusOwnership.reclaim / reclaimAfterFrame / '
          'guardOverlay —— 裸调会绕过该页的 _canOwn*Focus 判据（播放器/内容就绪、'
          '查词浮层可见、光标态、所有者路由 isCurrent），正是统一前每个补丁互相'
          '漂移的老路。命中：$violations',
    );
  });

  test('两个媒体页都接入了 PageFocusOwnership', () {
    for (final String page in <String>[
      'lib/src/pages/implementations/video_hibiki_page.dart',
      'lib/src/pages/implementations/reader_hibiki_page.dart',
    ]) {
      final String source = File(page).readAsStringSync();
      expect(source, contains('PageFocusOwnership'),
          reason: '$page 必须用统一的焦点所有者');
      expect(source, contains('FocusReclaimCause'),
          reason: '$page 的回收必须自证原因（cause），判据按 cause 分流');
    }
  });
}
