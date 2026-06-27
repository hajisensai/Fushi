import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-900 源码守卫：app 回前台（[AppLifecycleState.resumed]）时阅读器必须把
/// Flutter 焦点收回正文 _focusNode，修复「Alt+Tab 切窗回来后页级 / 全局快捷键整体
/// 失灵、只能重启复活」。OS 层焦点丢失 headless 难稳定复现，故用接线守卫固化
/// 「resumed 必调回收 helper + helper 含路由 isCurrent 门控（绝不夺对话框焦点）」
/// 这两个不变式，防回归被删（对齐 video_page_keyboard_focus_static_test.dart）。
void main() {
  late String src;
  setUpAll(() {
    final File f =
        File('lib/src/pages/implementations/reader_hibiki_page.dart');
    expect(f.existsSync(), isTrue, reason: '文件不存在');
    src = f.readAsStringSync();
  });

  test('存在 _reclaimReaderFocusIfOwned 回收 helper', () {
    expect(src, contains('void _reclaimReaderFocusIfOwned()'),
        reason: '应有统一的 resumed 焦点回收 helper');
  });

  test('didChangeAppLifecycleState 的 resumed 分支调回收 helper', () {
    final int lifecycle = src.indexOf('void didChangeAppLifecycleState(');
    expect(lifecycle, greaterThanOrEqualTo(0));
    final int end = src.indexOf('\n  }', lifecycle);
    final String body = src.substring(lifecycle, end);
    expect(body, contains('AppLifecycleState.resumed'),
        reason: 'resumed 分支不能缺失，否则切窗回来不回收焦点');
    expect(body, contains('_reclaimReaderFocusIfOwned();'),
        reason: 'resumed 时必须调回收 helper');
    // 既有 paused/inactive 落库分支不得被破坏。
    expect(body, contains('_syncAndFlushPosition()'),
        reason: 'paused/inactive 落库分支必须保留');
  });

  test('回收 helper 含完整门控（光标 / 歌词 / 弹窗 + 路由 isCurrent）', () {
    final int start = src.indexOf('void _reclaimReaderFocusIfOwned()');
    expect(start, greaterThanOrEqualTo(0));
    final int end = src.indexOf('\n  }', start);
    final String body = src.substring(start, end);
    expect(
        body.contains('_caretActive') || body.contains('_caretSurface'), isTrue,
        reason: 'helper 必须门控光标态');
    expect(body, contains('_lyricsMode'), reason: 'helper 必须门控歌词态');
    expect(
        body.contains('isDictionaryShown') || body.contains('_hasVisiblePopup'),
        isTrue,
        reason: 'helper 必须门控弹窗态');
    expect(body, contains('_readerContentReady'), reason: 'helper 必须门控内容就绪');
    // [M1] 红线：必须有路由 isCurrent 判定，否则压着对话框时会夺对话框焦点。
    expect(body, contains('ModalRoute.of(context)'), reason: 'helper 必须取所有者路由');
    expect(body, contains('isCurrent'),
        reason: 'helper 必须含路由 isCurrent 门控（否则夺对话框焦点，Never break userspace）');
    expect(body, contains('_focusNode.requestFocus()'),
        reason: 'helper 必须 requestFocus 正文节点');
  });
}
