import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// BUG-2590：媒体服务器兼容层（飞牛、「UHD Media Server」等）没有
/// `/Videos/…/Subtitles/…/Stream` 抽取端点，内嵌文本轨下载一律 404；但 DirectPlay
/// 送来的是原始 mkv，轨就在 libmpv 正在 demux 的流里。守卫钉住两段式回落：
///
///  1. 下载失败先把轨交给 libmpv 自绘（[_showRemoteEmbeddedTrackViaPlayer]），只有
///     回落也不成才报「无法加载」；回落只在流是原始容器时做，按容器内序号
///     （`containerTrackOrdinal`，Emby 全局流号不能直接当 mpv 轨号）选轨。
///  2. 桌面后台抽取（[_upgradeRemoteEmbeddedTrackToCues]）完成后只在同一集、用户
///     仍选着该轨时才切 cue overlay，不抢占。
///  3. 起播恢复 `embedded:<n>` 时同样先吃缓存、下载失败同样回落自绘。
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
      expect(body.contains('_cachedRemoteEmbeddedSubtitle('), isTrue,
          reason: '本机已抽过的轨不再问服务器');
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
      expect(body.contains('_upgradeRemoteEmbeddedTrackToCues('), isTrue);
      expect(body.contains('isDesktopPlatform'), isTrue,
          reason: '后台整读一遍容器只在桌面做（蜂窝流量翻倍不可接受）');
    });

    test('_upgradeRemoteEmbeddedTrackToCues 换集 / 换字幕不抢占，静默切换', () {
      final String body = maskComments(
        methodBody(
          readVideoFushiSource(),
          'Future<void> _upgradeRemoteEmbeddedTrackToCues(',
        ),
      );
      expect(body.contains('extractRemoteEmbeddedSubtitle('), isTrue);
      expect(body.contains('seq != _episodeLoadSeq'), isTrue,
          reason: '抽取要几分钟，期间换集就作废');
      expect(body.contains('_currentSubtitleSource != source'), isTrue,
          reason: '用户已换字幕 / 关字幕则不抢占');
      expect(body.contains('showLoadingOverlay: false'), isTrue,
          reason: '播放中途静默切换，不闪加载遮罩');
      expect(body.contains('video_subtitle_remote_extracted'), isTrue,
          reason: '样式突然变了要告诉用户为什么');
    });

    test('起播恢复 embedded:<n>：先吃缓存，下载失败回落自绘', () {
      final String body = maskComments(
        methodBody(readVideoFushiSource(), 'Future<void> _loadRemoteEpisode('),
      );
      expect(body.contains('_cachedRemoteEmbeddedSubtitle('), isTrue);
      expect(body.contains('playerRenderedTrack = track'), isTrue,
          reason: '恢复路径的下载失败不能再静默落回无字幕');
      expect(body.contains('_showRemoteEmbeddedTrackViaPlayer('), isTrue);
      expect(
          body.contains(
              '_remoteStreamIsOriginalContainer = urls.streamIsOriginalContainer'),
          isTrue);
    });
  });
}
