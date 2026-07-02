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

  // BUG-344: video_player_controller 多处异步 mpv FFI 下发用方法开头捕获的局部
  // `player` 引用；await 缺口内用户退出 / 换集触发 [dispose]（`_loadToken++` +
  // `unawaited(_player.dispose())` 异步释放 libmpv NativePlayer + `_player=null`），
  // 恢复后继续向已释放 native handle 下发 FFI = 原生 use-after-free（访问违例
  // 0xc0000005）。既有不变量 [_isCurrentLoad]（`_player==player && _loadToken==loadToken`
  // 双判据）必须在**每个 await 之后**重校验、过期放弃。无法纯单测（需真实 libmpv
  // player），故源码层钉死这条时序不变式。分两条路径：
  //   - A 层：[selectEmbeddedGraphicTrack]（选内嵌图形字幕轨，PGS/DVD 位图）3 处下发。
  //   - load() 主路径：[load] 开头 8 处早期 await FFI 下发（更高频，与用户崩溃更贴合）
  //     + autoPlay 的 play() 守卫用双判据。
  group('VideoPlayerController guards against libmpv UAF on dispose (BUG-344)',
      () {
    final String src = read('lib/src/media/video/video_player_controller.dart');

    String methodBody(String headerRegex, String trailerRegex) {
      final RegExpMatch? m = RegExp(
        headerRegex + r'(.*?)' + trailerRegex,
        dotAll: true,
      ).firstMatch(src);
      expect(m, isNotNull,
          reason: '找不到方法体: header=$headerRegex trailer=$trailerRegex');
      return m!.group(1)!;
    }

    // ---- A 层：selectEmbeddedGraphicTrack ----
    String graphicBody() => methodBody(
          r'Future<bool> selectEmbeddedGraphicTrack\(int streamIndex\) async \{',
          r'\n  \}',
        );

    test('A: selectEmbeddedGraphicTrack captures loadToken before first await',
        () {
      final String b = graphicBody();
      final int tokenAt = b.indexOf('final int loadToken = _loadToken;');
      final int firstAwaitAt =
          b.indexOf('await _waitUntilSubtitleTracksReady(player);');
      expect(tokenAt, greaterThanOrEqualTo(0),
          reason: '必须在第一个 await 前捕获 loadToken 快照');
      expect(firstAwaitAt, greaterThan(tokenAt),
          reason: 'loadToken 必须在第一条 await 语句之前捕获');
    });

    test(
        'A: selectEmbeddedGraphicTrack re-checks _isCurrentLoad after every '
        'native await (>=3, no bare _player!=player)', () {
      final String b = graphicBody();
      final int rechecks =
          RegExp(r'_isCurrentLoad\(player, loadToken\)').allMatches(b).length;
      expect(rechecks, greaterThanOrEqualTo(3),
          reason:
              '三处原生下发（setSubtitleTrack + 两次 setProperty）后都必须重校验 _isCurrentLoad，'
              '否则退出/换集期间向已释放 libmpv handle 下发 → 原生 UAF');
      expect(b.contains('if (_player != player) return false;'), isFalse,
          reason:
              'BUG-344: 禁止回退到只比 _player!=player 的单次校验（漏 loadToken 且后续 await 不重校验）');
    });

    test(
        'A: selectEmbeddedGraphicTrack inserts a recheck between each native '
        'send', () {
      final String b = graphicBody();
      final int setTrackAt = b.indexOf('await player.setSubtitleTrack(real[');
      final int firstApplyAt =
          b.indexOf('await applySubtitleMpvPropertiesToPlayer(');
      final int secondApplyAt = b.indexOf(
          'await applySubtitleMpvPropertiesToPlayer(', firstApplyAt + 1);
      expect(setTrackAt, greaterThanOrEqualTo(0));
      expect(firstApplyAt, greaterThan(setTrackAt));
      expect(secondApplyAt, greaterThan(firstApplyAt));
      final int recheckAfterSetTrack =
          b.indexOf('_isCurrentLoad(player, loadToken)', setTrackAt);
      expect(recheckAfterSetTrack, greaterThan(setTrackAt));
      expect(recheckAfterSetTrack, lessThan(firstApplyAt),
          reason: 'setSubtitleTrack 后、下一次原生下发前必须重校验');
      final int recheckAfterFirstApply =
          b.indexOf('_isCurrentLoad(player, loadToken)', firstApplyAt);
      expect(recheckAfterFirstApply, greaterThan(firstApplyAt));
      expect(recheckAfterFirstApply, lessThan(secondApplyAt),
          reason: '第一次 setProperty 后、第二次原生下发前必须重校验');
    });

    // ---- selectSubtitleTrack（TODO-409 / BUG-430）----
    // 切/关字幕路径上唯一一处 await libmpv 原生下发的方法。关字幕（`no()`）是高频路径，
    // await 期间退出/换集触发 dispose → 向已释放 handle 下发 = 原生 UAF。必须与
    // selectEmbeddedGraphicTrack 同范式：await 前捕获 loadToken，await 后重校验。
    String selectSubtitleBody() => methodBody(
          r'Future<void> selectSubtitleTrack\(SubtitleTrack track\) async \{',
          r'\n  \}',
        );

    test(
        'selectSubtitleTrack captures loadToken before the native await and '
        'rechecks _isCurrentLoad after it (TODO-409 UAF guard)', () {
      final String b = selectSubtitleBody();
      final int tokenAt = b.indexOf('final int loadToken = _loadToken;');
      final int sendAt = b.indexOf('await player.setSubtitleTrack(track);');
      final int recheckAt =
          b.indexOf('_isCurrentLoad(player, loadToken)', sendAt);
      expect(tokenAt, greaterThanOrEqualTo(0),
          reason: 'await 前必须捕获 loadToken 快照（与 selectEmbeddedGraphicTrack 一致）');
      expect(sendAt, greaterThan(tokenAt),
          reason: 'setSubtitleTrack 原生下发必须在 loadToken 捕获之后');
      expect(recheckAt, greaterThan(sendAt),
          reason: 'setSubtitleTrack 后必须重校验 _isCurrentLoad，否则退出/换集期间向已释放 '
              'libmpv handle 下发 → 原生 UAF（回退字幕闪退，TODO-409）');
      expect(
          b.contains('if (!_isCurrentLoad(player, loadToken)) return;'), isTrue,
          reason: '过期一律干净 return 放弃下发，不触野 handle');
    });

    test('selectSubtitleTrack snapshots _player into a local before the await',
        () {
      final String b = selectSubtitleBody();
      // 局部化 player（与 selectEmbeddedGraphicTrack 同），杜绝 await 后 `_player?.` 解到
      // 已被 dispose 置 null / 已被新 load 接管的字段。
      expect(b.contains('final Player? player = _player;'), isTrue,
          reason:
              '必须把 _player 提为局部 player，禁止 await 后裸用 _player?.setSubtitleTrack');
      expect(b.contains('await _player?.setSubtitleTrack'), isFalse,
          reason:
              'TODO-409: 禁止回退到无守卫的 `await _player?.setSubtitleTrack(track)`（原生 UAF 窗口）');
    });

    // ---- load() 主路径（本轮核心）----
    // load() 紧跟着 `bool _isCurrentLoad(...)` getter，用它锚定方法体结束（方法体内
    // 含多处 4/6 空格缩进的 `}`，非贪婪到 `\n  }\n\n  bool _isCurrentLoad` 精确收口）。
    String loadBody() => methodBody(
          r'Future<void> load\(\{',
          r'\n  \}\n\n  bool _isCurrentLoad',
        );

    test('load() captures loadToken before the first native FFI send', () {
      final String b = loadBody();
      final int tokenAt = b.indexOf('final int loadToken = ++_loadToken;');
      // BUG-528：open 现随 Media(httpHeaders:) 多行下发（防盗链 header 须在 open 前设），
      // 锚点收敛到唯一的 `await player.open(`。
      final int firstOpenAt = b.indexOf('await player.open(');
      expect(tokenAt, greaterThanOrEqualTo(0),
          reason: 'load 必须在第一处原生下发前捕获 loadToken（开头 ++_loadToken）');
      expect(firstOpenAt, greaterThan(tokenAt),
          reason: 'player.open 必须在 loadToken 捕获之后');
    });

    test(
        'load() re-checks _isCurrentLoad after every early native await '
        '(open / network / setSubtitleTrack(no) / suppression / shaders / '
        'mpvConfig / volume / rate)', () {
      final String b = loadBody();
      // 每个早期下发语句后，在下一个早期下发语句之前，必须出现一次
      // `_isCurrentLoad(player, loadToken)` 重校验。按出现顺序成对断言。
      const List<String> sends = <String>[
        // BUG-528：open 现随 Media(httpHeaders:) 多行下发，锚点用唯一的 `await player.open(`。
        'await player.open(',
        'await applyNetworkCachePropertiesToPlayer(player, sourceUri);',
        'await player.setSubtitleTrack(SubtitleTrack.no());',
        // 字幕抑制（多行调用）：用其首行锚定。
        'buildSubtitleSuppressionProperties(),',
        'await applyShadersToPlayer(player, _shaderPaths);',
        'await applyMpvConfigToPlayer(player, _mpvConfig);',
        'await player.setVolume(initialVolume);',
        'await player.setRate(initialSpeed);',
      ];
      for (int i = 0; i < sends.length; i++) {
        final int sendAt = b.indexOf(sends[i]);
        expect(sendAt, greaterThanOrEqualTo(0),
            reason: '找不到早期原生下发语句: ${sends[i]}');
        final int recheckAt =
            b.indexOf('_isCurrentLoad(player, loadToken)', sendAt);
        expect(recheckAt, greaterThan(sendAt),
            reason: '「${sends[i]}」之后必须紧跟 _isCurrentLoad 重校验（BUG-344 主路径）');
        // 重校验必须落在下一个早期下发语句之前（不能整段共用一处）。
        if (i + 1 < sends.length) {
          final int nextSendAt = b.indexOf(sends[i + 1], sendAt + 1);
          expect(nextSendAt, greaterThan(sendAt));
          expect(recheckAt, lessThan(nextSendAt),
              reason:
                  '「${sends[i]}」的重校验必须落在下一处下发「${sends[i + 1]}」之前——每个 await 独立守卫');
        }
      }
      // 早期下发后的重校验过期一律 `return`（干净放弃，不留半初始化）。至少 8 处。
      final int returnGuards = RegExp(
        r'if \(!_isCurrentLoad\(player, loadToken\)\) return;',
      ).allMatches(b).length;
      expect(returnGuards, greaterThanOrEqualTo(8),
          reason:
              'load 主路径 8 处早期 await 后都要 `if (!_isCurrentLoad(...)) return;` 干净放弃');
    });

    test('load() autoPlay play() uses the dual predicate, not bare identity',
        () {
      final String b = loadBody();
      expect(b.contains('if (autoPlay && _isCurrentLoad(player, loadToken))'),
          isTrue,
          reason: 'autoPlay 守卫必须用 _isCurrentLoad 双判据——换集复用同一 player 时单判 '
              '`_player == player` 会误向被新 load 接管的 player 发 play()');
      expect(b.contains('if (autoPlay && _player == player)'), isFalse,
          reason: 'BUG-344: 禁止回退到 autoPlay 单判据 `_player == player`');
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
