import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：视频退出 flush 的「时序不变式」——无法用纯单测覆盖（需真实 libmpv
/// player），故在源码层钉死结构：
///
/// **退出 flush（问题 1）**：`VideoPlayerController.dispose` 必须**先**强制保存
/// 当前位置（绕过整秒节流）**再**释放 player，否则退出瞬间同一整秒内的最后几百
/// 毫秒进度被节流吞掉 →「退出再进没回到上次位置」。
void main() {
  String read(String relPath) => File(relPath).readAsStringSync();

  group('VideoPlayerController exit flush (问题 1)', () {
    final String src = read('lib/src/media/video/video_player_controller.dart');

    test('dispose force-saves the position before disposing the player', () {
      final RegExpMatch? body = RegExp(
        r'void dispose\(\) \{(.*?)\n  \}',
        dotAll: true,
      ).firstMatch(src);
      expect(body, isNotNull, reason: '找不到 dispose 方法体');
      final String b = body!.group(1)!;
      final int saveAt = b.indexOf('_forceSavePositionSync()');
      final int playerDisposeAt = b.indexOf('_player?.dispose()');
      expect(saveAt, greaterThanOrEqualTo(0),
          reason: 'dispose 必须强制保存当前位置（退出 flush）');
      expect(playerDisposeAt, greaterThan(saveAt),
          reason: '强制保存必须在释放 player 之前（之后 positionMs 读不到）');
    });

    test('a public flushPosition() awaits the persistence write', () {
      final RegExpMatch? body = RegExp(
        r'Future<void> flushPosition\(\) async \{(.*?)\n  \}',
        dotAll: true,
      ).firstMatch(src);
      expect(body, isNotNull, reason: '找不到 flushPosition 方法体');
      expect(body!.group(1), contains('await onPositionWrite?.call('),
          reason: 'flushPosition 必须 await 到真正落库（durability）');
    });
  });

  // 真正的断点是**页面层**：controller.dispose() 里的 `_forceSavePositionSync()`
  // 是 fire-and-forget，与 Navigator 同步销毁 State 竞争、写不完，导致「退出再进
  // 没回到上次位置」。页面必须在路由 pop **之前** await `_controller.flushPosition()`
  // 把退出瞬间位置可靠落库（对齐阅读器 `onWillPop` 先 await 落库再 pop）。后台生命
  // 周期也要 flush，覆盖硬杀进程（dispose 不跑）。这两条无法纯单测（需真实 libmpv），
  // 故在源码层钉死结构。
  group('VideoHibikiPage exit/background flush wiring (问题 1)', () {
    final String page =
        read('lib/src/pages/implementations/video_hibiki_page.dart');

    test('PopScope intercepts the route pop (canPop:false) to await the flush',
        () {
      expect(page, contains('canPop: false'),
          reason: '页面必须自管退出（canPop:false），才能在 pop 前 await 落库');
    });

    test('pop handler awaits flushPosition() before manually popping the route',
        () {
      final RegExpMatch? body = RegExp(
        r'onPopInvokedWithResult: \(bool didPop, Object\? _\) async \{(.*?)\n      \},',
        dotAll: true,
      ).firstMatch(page);
      expect(body, isNotNull, reason: '找不到 onPopInvokedWithResult 异步处理体');
      final String b = body!.group(1)!;
      final int flushAt = b.indexOf('await _controller?.flushPosition()');
      final int popAt = b.indexOf('nav.pop()');
      expect(flushAt, greaterThanOrEqualTo(0),
          reason: '退出前必须 await _controller.flushPosition()（可靠落库）');
      expect(popAt, greaterThan(flushAt),
          reason: '手动 pop 必须在 await flush 之后（否则 State 销毁后写不完）');
    });

    test('background lifecycle flushes the playback position (hard-kill cover)',
        () {
      final RegExpMatch? body = RegExp(
        r'void didChangeAppLifecycleState\(AppLifecycleState state\) \{(.*?)\n  \}',
        dotAll: true,
      ).firstMatch(page);
      expect(body, isNotNull, reason: '找不到 didChangeAppLifecycleState 方法体');
      expect(body!.group(1), contains('_controller?.flushPosition()'),
          reason: '退到后台时必须 flush 播放位置（dispose 在硬杀时不跑）');
    });
  });
}
