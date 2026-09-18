import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// 媒体服务器 / 互联远端的内嵌字幕轨必须按**当前集**下载。
///
/// 合集连播切集后 `widget.remoteInfo` 仍是打开播放页时那一集，只有
/// `_effectiveRemoteInfo` / `_effectiveRemoteClient` 跟着当前成员走。主字幕的
/// `_applyRemoteEmbeddedSubtitle` 曾用 `widget.remoteInfo`：切到第 2 集再选内嵌轨，
/// 下载的是第 1 集的同号轨——字幕与画面对不上，用户报「选了 srt 轨不生效」。副字幕
/// 的同款函数早已按当前集取，这条守卫把两处钉在同一口径上。
///
/// 同时钉死：下载失败必须有归宿（OSD + 日志），不能再从 `unawaited` 里静默逃逸。
void main() {
  group('远端内嵌字幕轨按当前集下载', () {
    for (final String method in <String>[
      'Future<void> _applyRemoteEmbeddedSubtitle(',
      'Future<void> _applyRemoteEmbeddedSecondarySubtitle(',
    ]) {
      test('$method 用 _effectiveRemoteInfo / _effectiveRemoteClient', () {
        final String body = maskComments(
          methodBody(readVideoFushiSource(), method),
        );
        expect(body.contains('widget.remoteInfo'), isFalse,
            reason: '打开播放页时那一集不是当前集：\n$body');
        expect(body.contains('widget.remoteClient'), isFalse);
        expect(body.contains('_effectiveRemoteInfo'), isTrue);
        expect(body.contains('_effectiveRemoteClient'), isTrue);
        expect(body.contains('episodeIndex: ep'), isTrue,
            reason: 'host-playlist 模式按集取轨');
      });

      test('$method 的下载失败有 OSD 与日志归宿', () {
        final String body = maskComments(
          methodBody(readVideoFushiSource(), method),
        );
        expect(body.contains('getRemoteVideoSubtitle'), isTrue);
        expect(body.contains('ErrorLogService'), isTrue,
            reason: '下载 4xx / 5xx / 断网要落日志');
        expect(body.contains('video_subtitle_load_failed'), isTrue,
            reason: '用户要看到失败而不是「点了没反应」');
      });
    }
  });
}
