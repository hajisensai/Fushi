import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// BUG-2590：媒体服务器兼容层（飞牛、「UHD Media Server」等）没有
/// `/Videos/…/Subtitles/…/Stream` 抽取端点，内嵌文本轨下载一律 404；但 DirectPlay
/// 送来的是原始 mkv，轨就在 libmpv 正在 demux 的流里。守卫钉住回落：
///
///  1. 下载失败先把轨交给 libmpv 解码（[_showRemoteEmbeddedTrackViaPlayer]），只有
///     回落也不成才报「无法加载」；回落只在流是原始容器时做，按容器内序号
///     （`containerTrackOrdinal`，Emby 全局流号不能直接当 mpv 轨号）选轨。
///  2. 起播恢复 `embedded:<n>` 时下载失败同样回落。
///  4. BUG-2648：回落**不是**自绘——libmpv 只解码、`sub-text` 回流成可点 cue
///     （自绘的字画进画面、不可查词、字幕列表为空）。
///  3. **不**在后台用 ffmpeg 把流再读一遍抽成 cue（整集流量翻倍，用户 2026-09-19
///     拍板不要）——页面里不得再出现远端流的 ffmpeg 抽取入口。
void main() {
  group('远端内嵌轨：服务器抽不出 → libmpv 解码回流', () {
    test('_applyRemoteEmbeddedSubtitle 下载失败先回落，再报失败', () {
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
      expect(body.contains('track.isExternalFile'), isTrue,
          reason: '外挂文件轨（在线源字幕链接 / Emby 外挂字幕）不在流里，'
              '按 streamIndex 去选会选中另一条不相干的内嵌轨');
      expect(body.contains('selectExternalTextSubtitleViaPlayer(url)'), isTrue,
          reason: 'BUG-3191：外挂文件轨按它自己的地址交给 libmpv 原格式读');
      expect(
        body.contains('track.containerTrackOrdinal ?? track.streamIndex'),
        isTrue,
        reason: 'Emby 的 streamIndex 是全局流号（视频/音频也占号），mpv 要字幕序号',
      );
      expect(body.contains('selectEmbeddedTextTrackViaPlayer('), isTrue,
          reason: 'BUG-2648：文本轨走 libmpv 解码 → sub-text 回流成可点 cue');
      expect(body.contains('selectEmbeddedGraphicTrack('), isFalse,
          reason: 'BUG-2648：文本轨不能再走图形自绘（字画进画面、不可查词）');
      expect(body.contains('setRemoteSubtitleSource('), isTrue,
          reason: '回落选中也要持久化，重进才能恢复');
      expect(body.contains('video_subtitle_remote_player_decoded'), isTrue,
          reason: '字幕随播放逐句出现（列表不会预先完整）要告诉用户');
    });

    test('起播恢复 embedded:<n>：下载失败回落', () {
      final String body = maskComments(
        methodBody(readVideoFushiSource(), 'Future<void> _loadRemoteEpisode('),
      );
      expect(body.contains('playerRenderedTrack = track'), isTrue,
          reason: '恢复路径的下载失败不能再静默落回无字幕');
      expect(body.contains('? (track.url?.isNotEmpty ?? false)'), isTrue,
          reason: '恢复路径：外挂文件轨按自己的地址回落（BUG-3191）');
      expect(body.contains(': urls.streamIsOriginalContainer'), isTrue,
          reason: '恢复路径：内嵌轨只在原始容器上回落，不能按流号去选容器里不相干的轨');
      expect(body.contains('_showRemoteEmbeddedTrackViaPlayer('), isTrue);
      expect(
          body.contains(
              '_remoteStreamIsOriginalContainer = urls.streamIsOriginalContainer'),
          isTrue);
    });

    // BUG-3260：外挂轨下到了却解析不出时交给 libmpv 的是**刚下好的本地文件**——
    // 轨的 url 是 DeliveryUrl，下载可能是它失效后回落到手拼端点才成功的；恢复路径的
    // 落地名也不能写死 `.srt`（Emby 外挂 ASS 会被按 SRT 解析成空）。
    test('外挂轨解析为空：libmpv 读本地已下载文件，落地名随原格式', () {
      final String manual = maskComments(
        methodBody(readVideoFushiSource(),
            'Future<void> _applyRemoteEmbeddedSubtitle('),
      );
      expect(manual.contains('track.copyWith(url: subtitle.path)'), isTrue,
          reason: '手选路径 onEmptyCues 要交本地文件：\n$manual');
      final String restore = maskComments(
        methodBody(readVideoFushiSource(), 'Future<void> _loadRemoteEpisode('),
      );
      expect(
          restore.contains(
              'playerRenderedTrack = track.copyWith(url: subtitle.path)'),
          isTrue,
          reason: '恢复路径解析为空同样交本地文件');
      expect(
          restore.contains("track?.fileName ?? 'embedded_\$streamIndex.srt'"),
          isTrue,
          reason: '恢复路径落地名要随轨的原格式扩展名');
    });

    // 副字幕同一条回落：此前副字幕只会下载抽取，兼容层 Emby 上主字幕能用、
    // 副字幕一选就「加载失败」、重进也静默恢复不了。
    test('副字幕 _applyRemoteEmbeddedSecondarySubtitle 下载失败先回落，再报失败', () {
      final String body = maskComments(
        methodBody(readVideoFushiSource(),
            'Future<void> _applyRemoteEmbeddedSecondarySubtitle('),
      );
      final int fallback =
          body.indexOf('_showRemoteEmbeddedSecondaryTrackViaPlayer(');
      final int failed = body.indexOf('video_subtitle_load_failed');
      expect(fallback, greaterThanOrEqualTo(0),
          reason: '副字幕的 404 同样不能直接判失败：\n$body');
      expect(failed, greaterThan(fallback), reason: '先回落、回落不成才报失败');
    });

    test('_showRemoteEmbeddedSecondaryTrackViaPlayer 走副槽、按容器内序号选轨并持久化', () {
      final String body = maskComments(
        methodBody(
          readVideoFushiSource(),
          'Future<bool> _showRemoteEmbeddedSecondaryTrackViaPlayer(',
        ),
      );
      expect(body.contains('_remoteStreamIsOriginalContainer'), isTrue);
      expect(body.contains('track.isExternalFile'), isTrue);
      expect(
        body.contains('track.containerTrackOrdinal ?? track.streamIndex'),
        isTrue,
      );
      expect(body.contains('selectEmbeddedSecondaryTextTrackViaPlayer('), isTrue,
          reason: '副字幕走 libmpv secondary-sid 槽，不能占主字幕的 sid');
      expect(body.contains('selectEmbeddedTextTrackViaPlayer('), isFalse,
          reason: '走主槽会把用户的主字幕顶掉');
      expect(body.contains('videoRemoteSecondarySubtitlePrefKey('), isTrue,
          reason: '回落选中也要持久化，重进才能恢复');
      expect(body.contains('_currentSecondarySubtitleSource = source'), isTrue);
    });

    test('副字幕重进恢复 embedded:<n>：下载失败回落到副槽', () {
      final String body = maskComments(
        methodBody(readVideoFushiSource(),
            'Future<void> _restoreRemoteSecondarySubtitle('),
      );
      expect(body.contains('selectEmbeddedSecondaryTextTrackViaPlayer('), isTrue,
          reason: '恢复路径的下载失败不能再静默落回无副字幕');
      expect(body.contains('_remoteStreamIsOriginalContainer'), isTrue);
      expect(body.contains('track.isExternalFile'), isTrue);
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

    test('副槽不选主字幕正占着的同一条轨（libmpv 静默不切，不得假装成功）', () {
      final String body = compactCode(
        methodBody(
          File('lib/src/media/video/video_player_controller.dart')
              .readAsStringSync(),
          'Future<bool> selectEmbeddedSecondaryTextTrackViaPlayer(',
        ),
      );
      final int guard = body.indexOf(
        'if(player.state.track.subtitle.id==real[streamIndex].id)returnfalse;',
      );
      expect(guard, greaterThanOrEqualTo(0));
      expect(guard, lessThan(body.indexOf('setSecondaryCues(')),
          reason: '要在清副 cue、下发 secondary-sid 之前拦下');
    });
  });
}
