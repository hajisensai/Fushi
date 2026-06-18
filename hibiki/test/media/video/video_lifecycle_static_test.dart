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

    test('exposes video width/height and subscribes to stream (BUG-105)', () {
      expect(src.contains('get videoWidth'), isTrue,
          reason: 'overlay 的 \\pos 映射需要视频原始宽度');
      expect(src.contains('get videoHeight'), isTrue,
          reason: 'overlay 的 \\pos 映射需要视频原始高度');
      expect(src.contains('stream.width'), isTrue,
          reason: '分辨率到位后须 notify 让 overlay 重定位 \\pos');
      expect(src.contains('stream.height'), isTrue,
          reason: '分辨率到位后须 notify 让 overlay 重定位 \\pos');
    });
  });

  // 网络缓存调优（TODO-033 #1）：远端 http(s) 直传须在 open 后注入缓存/预读参数，
  // 缓解 WiFi 抖动卡顿；本地文件不注入（applyNetworkCachePropertiesToPlayer 内按
  // scheme 门控）。无法纯单测（需真实 libmpv player），故源码层钉死注入位置。
  group('VideoPlayerController network cache tuning (TODO-033 #1)', () {
    final String src = read('lib/src/media/video/video_player_controller.dart');

    test('load() injects network cache tuning after player.open', () {
      // load() 体很长且含嵌套闭包，非贪婪匹配到 `\n  }` 会停在参数列表收尾；改为
      // 从方法体开头（`}) async {`）截到「关闭 libmpv 画面字幕渲染」这段注释——
      // open + 注入都在此段内，足够断言注入位置。
      final int bodyStart =
          src.indexOf('}) async {', src.indexOf('Future<void> load({'));
      expect(bodyStart, greaterThanOrEqualTo(0), reason: '找不到 load 方法体');
      final int bodyEnd = src.indexOf('关闭 libmpv 画面字幕渲染', bodyStart);
      expect(bodyEnd, greaterThan(bodyStart), reason: '找不到 load 体内的注入段尾界标');
      final String b = src.substring(bodyStart, bodyEnd);
      final int openAt = b.indexOf('player.open(');
      final int injectAt = b.indexOf('applyNetworkCachePropertiesToPlayer(');
      expect(openAt, greaterThanOrEqualTo(0), reason: 'load 必须 open 媒体');
      expect(injectAt, greaterThan(openAt),
          reason: '网络缓存调优必须在 player.open 之后注入（属性作用于已打开的流）');
      expect(
          b.contains('applyNetworkCachePropertiesToPlayer(player, sourceUri)'),
          isTrue,
          reason: '必须把 sourceUri 透传给注入函数，由其按 scheme 决定是否生效');
    });
  });

  group('VideoPlayerController restore bootstrap (TODO-250)', () {
    final String src = read('lib/src/media/video/video_player_controller.dart');

    test('load() does not persist synthetic initialPositionMs', () {
      final int bodyStart =
          src.indexOf('}) async {', src.indexOf('Future<void> load({'));
      expect(bodyStart, greaterThanOrEqualTo(0), reason: '找不到 load 方法体');
      final int bodyEnd = src.indexOf('订阅播放态翻转', bodyStart);
      expect(bodyEnd, greaterThan(bodyStart), reason: '找不到 load 恢复段尾界标');
      final String b = src.substring(bodyStart, bodyEnd);
      expect(b, isNot(contains('updateCueForPosition(initialPositionMs)')),
          reason: 'initialPositionMs 是 load 合成的恢复目标，不是真实 player tick，不能走持久化路径');
      expect(
        b,
        contains('resolvedStartMs = resolveEpisodeStart('),
        reason: 'load 必须先按 start intent 和 duration 决定真实起播点',
      );
      expect(
        b,
        contains('player.state.duration.inMilliseconds'),
        reason: '恢复前要用真实 duration 判定近片尾保存位置',
      );
      expect(
        b,
        contains(
          '_syncCueForPosition(resolvedStartMs, persistPosition: false)',
        ),
        reason: 'load 仍要用解析后的实际起播点初始化字幕，但必须跳过位置持久化',
      );
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

    test('pop handler delegates to _handleBackOrExit (PopScope/Esc 共用汇聚点)', () {
      // PopScope 与 Escape 快捷键共用 _handleBackOrExit，保证两条退出路径一致。
      final RegExpMatch? body = RegExp(
        r'onPopInvokedWithResult: \(bool didPop, Object\? _\) async \{(.*?)\n      \},',
        dotAll: true,
      ).firstMatch(page);
      expect(body, isNotNull, reason: '找不到 onPopInvokedWithResult 异步处理体');
      expect(body!.group(1), contains('_handleBackOrExit()'),
          reason: 'onPop 必须委托给退出汇聚点 _handleBackOrExit');
    });

    test('_handleBackOrExit awaits flushPosition() before manually popping',
        () {
      final RegExpMatch? body = RegExp(
        r'Future<void> _handleBackOrExit\(\) async \{(.*?)\n  \}',
        dotAll: true,
      ).firstMatch(page);
      expect(body, isNotNull, reason: '找不到 _handleBackOrExit 方法体');
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

  // TODO-099: video page forces landscape on enter, restores on exit.
  // Mobile-only; desktop is no-op. Source-level guard (needs a real device
  // orientation system, cannot be exercised in a pure unit test).
  group('VideoHibikiPage forced landscape wiring (TODO-099)', () {
    final String page =
        read('lib/src/pages/implementations/video_hibiki_page.dart');

    test('initState locks landscape on entering the video page', () {
      final RegExpMatch? body = RegExp(
        r'void initState\(\) \{(.*?)\n  \}',
        dotAll: true,
      ).firstMatch(page);
      expect(body, isNotNull, reason: 'initState method body not found');
      expect(body!.group(1), contains('_lockLandscapeForVideo()'),
          reason: 'initState must lock landscape on entering the page');
    });

    test('the lock method is mobile-gated and locks only landscape', () {
      final RegExpMatch? body = RegExp(
        r'Future<void> _lockLandscapeForVideo\(\) async \{(.*?)\n  \}',
        dotAll: true,
      ).firstMatch(page);
      expect(body, isNotNull,
          reason: '_lockLandscapeForVideo method body not found');
      final String b = body!.group(1)!;
      expect(b, contains('if (!isMobilePlatform) return;'),
          reason: 'must be mobile-gated (desktop no-op)');
      expect(b, contains('setPreferredOrientations'),
          reason: 'must lock via SystemChrome.setPreferredOrientations');
      expect(b, contains('DeviceOrientation.landscapeLeft'),
          reason: 'landscape lock must include landscapeLeft');
      expect(b, contains('DeviceOrientation.landscapeRight'),
          reason: 'landscape lock must include landscapeRight');
      expect(b.contains('DeviceOrientation.portraitUp'), isFalse,
          reason: 'landscape lock must not re-allow portrait');
    });

    test('dispose restores the orientation on leaving the page', () {
      final RegExpMatch? body = RegExp(
        r'void dispose\(\) \{(.*?)\n  \}',
        dotAll: true,
      ).firstMatch(page);
      expect(body, isNotNull, reason: 'dispose method body not found');
      expect(body!.group(1), contains('_restoreOrientationOnExit()'),
          reason: 'dispose must restore orientation on leaving the page');
    });

    test('the restore method is mobile-gated and re-allows portrait', () {
      final RegExpMatch? body = RegExp(
        r'Future<void> _restoreOrientationOnExit\(\) async \{(.*?)\n  \}',
        dotAll: true,
      ).firstMatch(page);
      expect(body, isNotNull,
          reason: '_restoreOrientationOnExit method body not found');
      final String b = body!.group(1)!;
      expect(b, contains('if (!isMobilePlatform) return;'),
          reason: 'must be mobile-gated (desktop no-op)');
      expect(b, contains('DeviceOrientation.portraitUp'),
          reason: 'restore must re-allow portrait (so novels can be portrait)');
      expect(b, contains('DeviceOrientation.landscapeLeft'),
          reason: 'restore to app default must include landscapeLeft');
      expect(b, contains('DeviceOrientation.landscapeRight'),
          reason: 'restore to app default must include landscapeRight');
    });
  });
}
