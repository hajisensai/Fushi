import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// BUG-2441：`player.stream.error` 是**证据，不是判决**——这条守卫钉死它。
///
/// 为什么需要一条守卫而不是靠注释：这个错误极其容易重犯。它读起来太像「播放器报错
/// 了 → 那就是打不开 → 显示失败页」，而真相是 media_kit 把 mpv 里 level == error 且
/// prefix ∈ `{file, ffmpeg(tcp:), vd, ad, cplayer, stream}` 的日志**全部**灌进这条流
/// （`media_kit/lib/src/player/native/player/real.dart`），其中有几类在**完全正常**的
/// 播放里必然出现：
///   - hwdec 候选逐个试错 → `[vd] Could not open codec.`
///   - 外挂音轨 / 外挂字幕打不开 → `[cplayer] Can not open external file …`
///   - 网络分片瞬时失败 → `[stream] Failed to open …`
///
/// 一旦把它接到失败判定上，`load()` 刚返回那一段（`mediaOpened` 尚未被观测到翻真，
/// media_kit 的 `open()` 先 `stop()` 清 state、`loadfile` 只下发不等解析完，重容器上
/// 这个窗口有一秒以上）里的任一条正常错误，都会把**正在正常起播**的页面打成失败页
/// ——而播放器不会因此停下，音频会在失败页背后继续响。
///
/// 判决权只属于 `VideoPlayerController.shouldDiagnoseMediaNeverOpened`（纯函数，
/// 真值表在 `test/media/video/video_player_controller_test.dart`）。
void main() {
  group('BUG-2441 mpv error 只留证不判决', () {
    test('_handlePlaybackError 不触碰任何失败态', () {
      final String src = readVideoFushiSource();
      // 必须剥注释再断言：本方法的文档里就写着「不得置失败态」这类词，
      // 直接对原文 contains 会命中注释、把守卫变成对文字而非对代码的断言。
      final String body =
          maskComments(methodBody(src, 'void _handlePlaybackError('));

      expect(body.contains('_failed'), isFalse,
          reason: '_handlePlaybackError 不得置失败态：mpv 的 error 流在正常播放中也会响，'
              '拿它当判据会把正在起播的视频打成「打不开」。判决交给 '
              'shouldDiagnoseMediaNeverOpened。实际方法体：\n$body');
      expect(body.contains('_failReason'), isFalse,
          reason: '同上：失败文案属于失败判定的产物，不该由一条日志事件写。');
      expect(body.contains('setState'), isFalse,
          reason: '本方法只落日志 + 记一条诊断文本，不该驱动任何 UI 重建。');
    });

    test('_handlePlaybackError 仍然留证（不是被整个删掉）', () {
      // 反向守卫：上面三条否定断言在「方法体空了」时同样恒真。留证是这条路径存在的
      // 唯一理由——没有它，libmpv 层失败就又回到了全仓零通道的状态。
      final String src = readVideoFushiSource();
      // 必须剥注释再断言：本方法的文档里就写着「不得置失败态」这类词，
      // 直接对原文 contains 会命中注释、把守卫变成对文字而非对代码的断言。
      final String body =
          maskComments(methodBody(src, 'void _handlePlaybackError('));

      expect(body.contains('ErrorLogService'), isTrue,
          reason: 'mpv 层错误必须落日志，否则失败时依旧无从定位。');
      expect(body.contains('_lastPlaybackErrorMessage'), isTrue,
          reason: '最后一条错误文本要留给真判失败时附进诊断日志。');
    });

    test('失败判定不读 mpv 错误文本', () {
      // BUG-2441 审查发现：`_describeLoadFailure` 是给 Dart 异常设计的裸子串匹配，
      // 喂 mpv 原始文本会误分类——`\\NAS\Network Share\…` 命中 'network' 报成网络
      // 故障、文件名含 `Private` 命中 'private' 报成「受限」，把本地文件问题指向
      // 完全错误的排查方向。判失败时文案固定用 not_opened。
      final String src = readVideoFushiSource();
      final String body =
          maskComments(methodBody(src, 'void _promoteVideoReadyOrDiagnose('));

      expect(body.contains('_describeLoadFailure'), isFalse,
          reason: '判「打不开」时不得把 mpv 文本过 _describeLoadFailure 的子串匹配。');
      expect(body.contains('video_load_failed_not_opened'), isTrue,
          reason: '判失败要给出「打不开」这句专用文案。');
    });
  });
}
