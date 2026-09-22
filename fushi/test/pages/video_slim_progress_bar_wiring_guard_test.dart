import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// 底部细进度条（`video_slim_progress_bar` 偏好）的接线守卫。
///
/// 判据（[videoSlimProgressBarVisible]，纯函数）已由
/// `test/media/video/video_controls_density_test.dart` 逐条钉死，渲染行为由
/// `test/media/video/video_slim_progress_bar_test.dart` 覆盖。本守卫只补这两者
/// 之间**够不到**的那一段：页面是否真的把偏好喂给了判据、把判据喂给了组件、
/// 并且把组件挂进了 controls 子树。
///
/// 这段只能静态断：media_kit 的控制条在 headless 宿主里根本渲染不出来（无
/// libmpv），页面 widget 测试压根到不了这棵子树——这也是本页其余一整批守卫
/// 都是源码级的原因。
void main() {
  late String src;
  setUpAll(() => src = readVideoFushiSource());

  test('偏好 → 判据 → 组件 三段接线齐全', () {
    expect(
      src.contains('appModel.videoSlimProgressBar'),
      isTrue,
      reason: '细进度条必须现读偏好；不读它这个开关就是个摆设',
    );
    expect(
      src.contains('videoSlimProgressBarVisible('),
      isTrue,
      reason: '显隐必须走共享纯函数判据，不许在页面里另写一套 if',
    );
    expect(
      src.contains('VideoSlimProgressBar('),
      isTrue,
      reason: '判据算出来要显形时必须真的挂组件',
    );
    expect(
      src.contains('_buildVideoSlimProgressBar(controller)'),
      isTrue,
      reason: '组件必须挂进 controls 子树（全屏路由复用同一 builder，挂这里全屏也跟着走）',
    );
  });

  test('判据的四个输入都从真实来源取，没有写死', () {
    final int start = src.indexOf('Widget _buildVideoSlimProgressBar(');
    expect(start, greaterThanOrEqualTo(0));
    final int end = src.indexOf('Widget _miniWindowIconButton(', start);
    expect(end, greaterThan(start));
    final String body = src.substring(start, end);

    expect(
      body.contains('preferenceEnabled: enabled'),
      isTrue,
      reason: '开关位取自偏好',
    );
    expect(
      body.contains('surface: _miniWindowSurface'),
      isTrue,
      reason: '小窗表面位取自真实表面（系统画中画下必须不画，否则与系统控件重影）',
    );
    expect(
      body.contains('controlsVisible: controlsVisible'),
      isTrue,
      reason: '控制条可见性取自 _videoControlsVisible 的 ValueListenableBuilder，'
          '不是快照——控制条淡出时细线要当场接管',
    );
    expect(
      body.contains('valueListenable: _videoControlsVisible'),
      isTrue,
      reason: '必须订阅控制条可见性，否则淡出后细线不出现（或淡入后不消失）',
    );
  });

  test('用播放器 chrome 的主题色口径，不是裸 colorScheme.primary', () {
    final int start = src.indexOf('Widget _buildVideoSlimProgressBar(');
    final int end = src.indexOf('Widget _miniWindowIconButton(', start);
    final String body = src.substring(start, end);
    // 两条都剥注释再判（[containsCodeLine]）：要求型断言下「实现删光、字面量留在
    // 注释里」是合法的骗绿写法；反过来负向断言不剥注释会被本文件自己的说明性注释
    // 命中（本守卫第一版就栽在这上面）。
    expect(
      containsCodeLine(body, '_videoChromeAccent(cs)'),
      isTrue,
      reason: '细线裸压固定深色 scrim：必须取亮 tone primary（videoChromeAccentColor）；'
          '注释里写着这句不算实现',
    );
    expect(
      containsCodeLine(body, 'cs.primary'),
      isFalse,
      reason: '不许绕过 chrome 配色口径直接用 colorScheme.primary——'
          '浅色 / eink 主题下它是深色，压在深色 scrim 上看不见',
    );
  });

  group('点击跳转', () {
    test('细线接上跳转回调，且被四个遮挡门控管着', () {
      final int start = src.indexOf('Widget _buildVideoSlimProgressBar(');
      final int end = src.indexOf('Widget _miniWindowIconButton(', start);
      final String body = src.substring(start, end);
      expect(
        containsCodeLine(body, 'onSeekFraction:'),
        isTrue,
        reason: '小窗里它是唯一的进度控件、常规档它是控制条淡出后唯一还在的那条，'
            '不可点等于没有进度控制',
      );
      for (final String gate in <String>[
        '_immersiveLocked',
        '_videoSidePanel',
        '_episodeListVisible',
        '_videoControlEditMode',
      ]) {
        expect(
          body.contains(gate),
          isTrue,
          reason: '细线挂在 media_kit 控制条那层 IgnorePointer **之外**：不自己订阅 '
              '$gate，它就是这四个门控唯一漏掉的可点区（沉浸锁住了还能被点着跳转）',
        );
      }
    });

    test('跳转走 controller.seekMs，不绕到 player.seek', () {
      final String body = methodBody(
        src,
        'Future<void> _seekToProgressFraction(double fraction)',
      );
      expect(
        body.contains('controller.seekMs('),
        isTrue,
        reason: 'seekMs 内部才有 seek 在途保护 + 字幕权威同步',
      );
      expect(
        containsCodeLine(body, 'player.seek('),
        isFalse,
        reason: 'media_kit 那条路绕过本仓 controller，要在 onSeekEnd 里补 '
            'notifyExternalSeek 才补得回来（BUG-796）',
      );
      expect(
        containsCodeLine(body, '_pokeControlsVisible()'),
        isFalse,
        reason: '这条线存在的意义就是「控制条不在时也能操作」；点一下就把整条控制条'
            '唤起来，等于每次跳转都重新糊一次画面',
      );
    });
  });
}
