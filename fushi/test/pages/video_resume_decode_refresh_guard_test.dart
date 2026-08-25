import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// 解码链刷新原语所在文件（不在视频页 part 语料里，守卫单独读它）。
const String kVideoPlayerControllerPath =
    'lib/src/media/video/video_player_controller.dart';

/// BUG-1863：移动端从后台切回来，画面「静止的地方变成灰色、运动的地方正常」。
///
/// 那个灰是 `#808080`（`1 << (bit_depth - 1)`），libavcodec 在**参考帧缺失**时 error
/// concealment 就填这个值；运动区域正常说明 P 帧残差解得好好的。合起来只有一个含义：
/// 解码器在播放中途被重建过，却没有回到关键帧就继续喂包。移动端在不可见期间被系统
/// 回收硬件解码器（MediaCodec 是有限资源）会造成这个中途重建，画面要等下一个 IDR 才
/// 自愈。media_kit 只在 surface 真被重建时刷新（`widListener` 尾部的
/// `player.seek(currentPosition)`），而 surface 是否重建与解码器是否被回收是两件独立的
/// 事——这就是「有时候才灰」的缺口。
///
/// media_kit 跑不了 headless、系统回收解码器也没法在单测里制造，所以这里测纯判据 +
/// 锁调用点契约。**真机未复测**（报修时手机 adb 离线），见 BUG-1863 的备注。
void main() {
  group('shouldRefreshDecodeOnResume', () {
    test('移动端真进过后台 + 有画面 + 可 seek → 刷新', () {
      expect(
        VideoPlayerController.shouldRefreshDecodeOnResume(
          enteredRealBackground: true,
          hasVideo: true,
          seekable: true,
          isMobile: true,
        ),
        isTrue,
      );
    });

    test('inactive 一瞥（没真进后台）不刷新', () {
      // 通知栏下拉 / 多任务一瞥期间 app 仍持有解码器，刷新只是无谓卡顿。
      expect(
        VideoPlayerController.shouldRefreshDecodeOnResume(
          enteredRealBackground: false,
          hasVideo: true,
          seekable: true,
          isMobile: true,
        ),
        isFalse,
      );
    });

    test('纯音频 / 首帧未出画不刷新', () {
      expect(
        VideoPlayerController.shouldRefreshDecodeOnResume(
          enteredRealBackground: true,
          hasVideo: false,
          seekable: true,
          isMobile: true,
        ),
        isFalse,
      );
    });

    test('不可 seek（直播 / 时长未知）不刷新', () {
      // 直播流上这一 seek 可能把播放头甩走，宁可留着灰屏也不打断直播。
      expect(
        VideoPlayerController.shouldRefreshDecodeOnResume(
          enteredRealBackground: true,
          hasVideo: true,
          seekable: false,
          isMobile: true,
        ),
        isFalse,
      );
    });

    test('桌面一律不刷新', () {
      // 窗口失焦不会让系统回收解码器；桌面切窗后 seek 只会给用户无谓卡顿。
      expect(
        VideoPlayerController.shouldRefreshDecodeOnResume(
          enteredRealBackground: true,
          hasVideo: true,
          seekable: true,
          isMobile: false,
        ),
        isFalse,
      );
    });
  });

  group('BUG-1863 调用点契约', () {
    final String src = readVideoFushiSource();
    final String code = maskCommentsAndScriptLines(src);

    String region(String startSig, String endSig) {
      final int start = src.indexOf(startSig);
      expect(start, greaterThanOrEqualTo(0), reason: 'missing $startSig');
      final int end = src.indexOf(endSig, start + startSig.length);
      expect(end, greaterThan(start), reason: 'missing $endSig after $startSig');
      return code.substring(start, end);
    }

    test('只有 paused / hidden 置「真进过后台」标记，inactive 不置', () {
      final String body = region(
        'void didChangeAppLifecycleState(AppLifecycleState state) {',
        'Future<void> _flushAllForProcessExit() async {',
      );
      final int inactive = body.indexOf('case AppLifecycleState.inactive:');
      final int paused = body.indexOf('case AppLifecycleState.paused:');
      final int resumed = body.indexOf('case AppLifecycleState.resumed:');
      expect(inactive, greaterThanOrEqualTo(0));
      expect(paused, greaterThan(inactive));
      expect(resumed, greaterThan(paused));
      // 标记只能出现在 paused/hidden 这一段里：落进 inactive 段就等于「通知栏下拉一下
      // 也要 seek」，落在 resumed 段之后就永远不会被置真。
      expect(body.substring(inactive, paused).contains('_enteredRealBackground'),
          isFalse,
          reason: 'inactive 期间 app 仍持有解码器，不该记「进过后台」（BUG-1863）');
      expect(
          body.substring(paused, resumed).contains('_enteredRealBackground = true'),
          isTrue,
          reason: '真后台（paused / hidden）必须记下标记，否则回前台无从判断（BUG-1863）');
    });

    test('resumed 分支调用解码链刷新', () {
      final String body = region(
        'case AppLifecycleState.resumed:',
        'case AppLifecycleState.detached:',
      );
      expect(body.contains('_refreshDecodeAfterResumeIfNeeded()'), isTrue,
          reason: '回前台必须走一次刷新判断（BUG-1863）');
    });

    test('标记无条件清除，不会攒到下一次 resume', () {
      final String body = region(
        'void _refreshDecodeAfterResumeIfNeeded() {',
        'Future<void> _flushAllForProcessExit() async {',
      );
      final int read = body.indexOf('final bool wasBackgrounded =');
      final int clear = body.indexOf('_enteredRealBackground = false');
      expect(read, greaterThanOrEqualTo(0), reason: '必须先取快照再清');
      expect(clear, greaterThan(read));
      // 清除必须在任何 return 之前：若被塞进「判据成立」分支里，某次不满足条件的 resume
      // 会把标记留到下一次 resume，变成「某次切窗后莫名 seek 一下」。
      final int firstReturn = body.indexOf('return');
      expect(firstReturn, greaterThan(clear),
          reason: '标记要在第一个 return 之前就清掉（BUG-1863）');
      expect(body.contains('controller.refreshDecodeAfterResume()'), isTrue,
          reason: '判据成立时必须真调刷新');
    });

    test('刷新不走用户 seek 链路', () {
      // seekMs 是「用户改变了播放位置」：会清主动跳转快照、作废「只播这一句就停」、
      // 触发字幕权威重算。解码链刷新的播放位置根本没变，套那套副作用是错的。
      // 断言落在 controller 文件（不在视频页语料里），同样先掩注释再切。
      final String controllerSrc =
          File(kVideoPlayerControllerPath).readAsStringSync();
      final String controllerCode =
          maskCommentsAndScriptLines(controllerSrc.replaceAll('\r\n', '\n'));
      const String sig = 'Future<void> refreshDecodeAfterResume() async {';
      final int start = controllerCode.indexOf(sig);
      expect(start, greaterThanOrEqualTo(0), reason: 'missing $sig');
      final int end = controllerCode.indexOf('bool get isBuffering', start);
      expect(end, greaterThan(start), reason: 'missing isBuffering after $sig');
      final String body = controllerCode.substring(start, end);
      expect(body.contains('seekMs('), isFalse,
          reason: '刷新只是把播放头 seek 回原地，不该带用户 seek 的副作用（BUG-1863）');
      expect(body.contains('player.seek(player.state.position)'), isTrue,
          reason: '刷新必须 seek 到当前位置本身（BUG-1863）');
    });

    test('刷新判据不在页面里被重新实现一遍', () {
      expect(code.contains('VideoPlayerController.shouldRefreshDecodeOnResume('),
          isTrue,
          reason: '判据是 controller 上的纯函数（可单测），页面不得另写一份（BUG-1863）');
    });
  });
}
