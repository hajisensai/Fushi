import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-2119：视频页退出汇聚点里，落库与 pop 之间不得再出现任何 `await`。
///
/// 真机现场：`await flushPosition()` 在连接被毒化后永远抛错 / 永不完成，
/// `nav.pop()` 永远到不了，Esc / 返回箭头 / 手柄 B / 系统返回一起失灵。
/// 退出必须走 [exitAfterPersist]（同步发起落库、无条件 pop）。
void main() {
  test('_handleBackOrExit 只经 exitAfterPersist 退出，不 await 落库', () {
    final String source = File(
      'lib/src/pages/implementations/video_fushi_page.dart',
    ).readAsStringSync();
    final String body = maskComments(
      methodBody(source, 'Future<void> _handleBackOrExit() async'),
    );

    expect(body, contains('exitAfterPersist('));
    expect(body, contains('exit: nav.pop'));
    expect(
      body,
      isNot(contains('await ')),
      reason: '退出路径上任何 await 都会把「能不能离开页面」押在一次异步操作上',
    );
    expect(
      body,
      isNot(contains('if (mounted) nav.pop()')),
      reason: '旧形态：先 await 落库再看 mounted 决定 pop',
    );
  });

  test('换集（episode.part）同样不 await 落库，走 persistInBackground', () {
    final String source = maskComments(
      File(
        'lib/src/pages/implementations/video_fushi/episode.part.dart',
      ).readAsStringSync(),
    );
    expect(source, contains('persistInBackground('));
    expect(
      source,
      isNot(contains('await _persistPosition(')),
      reason: '换集前 await 落库：连接被毒化时换集按钮 / 剧集列表 / 连播全部卡死',
    );
  });
}
