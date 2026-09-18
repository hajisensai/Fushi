import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// BUG-2590：媒体服务器兼容层（飞牛、「UHD Media Server」等）没有
/// `/Videos/…/Subtitles/…/Stream` 抽取端点，内嵌文本轨下载一律 404；但 DirectPlay
/// 送来的是原始 mkv，轨就在 libmpv 正在 demux 的流里。守卫钉住回落：
///
///  1. 下载失败先把轨交给 libmpv 自绘（[_showRemoteEmbeddedTrackViaPlayer]），只有
///     回落也不成才报「无法加载」；回落只在流是原始容器时做，按容器内序号
///     （`containerTrackOrdinal`，Emby 全局流号不能直接当 mpv 轨号）选轨。
///  2. 起播恢复 `embedded:<n>` 时下载失败同样回落自绘。
///  3. **不**在后台用 ffmpeg 把流再读一遍抽成 cue（整集流量翻倍，用户 2026-09-19
///     拍板不要）——页面里不得再出现远端流的 ffmpeg 抽取入口。
void main() {
  group('远端内嵌轨：服务器抽不出 → libmpv 自绘回落', () {
    test('_applyRemoteEmbeddedSubtitle 下载失败先回落自绘，再报失败', () {
      final String body = maskComments(
        methodBody(readVideoFushiSource(),
            'Future<void> _applyRemoteEmbeddedSubtitle('),
      );
      final int fallback = body.indexOf('_showRemoteEmbeddedTrackViaPlayer(');
      final int failed = body.indexOf('video_subtitle_load_failed');
      expect(fallback, greaterThanOrEqualTo(0),
          reason: '404 不能直接判失败——轨就在直出流里：\n$body');
      expect(failed, greaterThan(fallback), reason: '先回落、回落不成才报失败');
      expect(body.contains('ErrorLogService'), isTrue,
          reason: '服务器 404 仍要落日志（调试日志页可见服务器返回码）');
    });

    test('_showRemoteEmbeddedTrackViaPlayer 只对原始容器、按容器内序号选轨并持久化', () {
      final String body = maskComments(
        methodBody(
          readVideoFushiSource(),
          'Future<bool> _showRemoteEmbeddedTrackViaPlayer(',
        ),
      );
      expect(body.contains('_remoteStreamIsOriginalContainer'), isTrue,
          reason: '转码 HLS 不带容器内字幕轨');
      expect(
        body.contains('track.containerTrackOrdinal ?? track.streamIndex'),
        isTrue,
        reason: 'Emby 的 streamIndex 是全局流号（视频/音频也占号），mpv 要字幕序号',
      );
      expect(body.contains('selectEmbeddedGraphicTrack('), isTrue,
          reason: '复用图形轨的 libmpv 自绘通路（同一降级语义）');
      expect(body.contains('setRemoteSubtitleSource('), isTrue,
          reason: '回落选中也要持久化，重进才能恢复');
      expect(body.contains('video_subtitle_remote_player_rendered'), isTrue,
          reason: '降级（不可查词）要告诉用户');
    });

    test('起播恢复 embedded:<n>：下载失败回落自绘', () {
      final String body = maskComments(
        methodBody(readVideoFushiSource(), 'Future<void> _loadRemoteEpisode('),
      );
      expect(body.contains('playerRenderedTrack = track'), isTrue,
          reason: '恢复路径的下载失败不能再静默落回无字幕');
      expect(body.contains('_showRemoteEmbeddedTrackViaPlayer('), isTrue);
      expect(
          body.contains(
              '_remoteStreamIsOriginalContainer = urls.streamIsOriginalContainer'),
          isTrue);
    });

    test('不得在后台用 ffmpeg 把远端流再读一遍抽字幕（流量翻倍）', () {
      final String src = maskComments(readVideoFushiSource());
      for (final String banned in <String>[
        'extractRemoteEmbeddedSubtitle(',
        'remoteEmbeddedSubtitleCacheDir(',
        'extractEmbeddedSubtitlesViaFfmpeg(',
      ]) {
        expect(src.contains(banned), isFalse,
            reason: '视频页出现了远端流 ffmpeg 抽取入口：$banned');
      }
    });
  });
}
