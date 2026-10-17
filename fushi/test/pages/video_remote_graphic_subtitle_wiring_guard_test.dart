import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// 远端图形字幕（PGS / VobSub / DVB）：远端播放页能选图形轨交给 libmpv 自绘，并且
/// 逐句时间表的整轨来源按来源分流——互联 host 回传它抽好的整轨（client **绝不**按
/// token 流地址整片读），媒体服务器 / URL 流由播放器按流地址 + 请求头抽取。
///
/// 页面要 media_kit 真实加载才能走到这些分支，宿主跑不了；用源码守卫钉住接线。
void main() {
  late String src;
  setUpAll(() => src = maskComments(readVideoFushiSource()));

  test('远端图形轨可选：原始容器直出 + 非外挂文件（转码 HLS 不带轨）', () {
    final String body = methodBody(src, 'bool _remoteGraphicTrackSelectable(');
    expect(body.contains('!track.isText'), isTrue);
    expect(body.contains('!track.isExternalFile'), isTrue);
    expect(body.contains('_remoteStreamIsOriginalContainer'), isTrue);
  });

  test('选图形轨：交 libmpv 自绘并带上远端整轨来源，选中即持久化', () {
    final String body = methodBody(
      src,
      'Future<bool> _showRemoteGraphicTrackViaPlayer(',
    );
    expect(body.contains('selectEmbeddedGraphicTrack('), isTrue);
    expect(body.contains('timingInput:'), isTrue);
    expect(body.contains('buildRemoteGraphicSubtitleTimingInput('), isTrue);
    expect(
      body.contains('track.containerTrackOrdinal ?? track.streamIndex'),
      isTrue,
      reason: 'Emby 的 streamIndex 是全局流号，mpv 要容器内字幕序号',
    );
    expect(body.contains('_rememberRemoteSubtitleSource('), isTrue);
  });

  test('手选与重进恢复都走图形轨分支（不再一律「不支持」）', () {
    final String apply = methodBody(
      src,
      'Future<void> _applyRemoteEmbeddedSubtitle(',
    );
    expect(apply.contains('_showRemoteGraphicTrackViaPlayer('), isTrue);
    final String restore = methodBody(src, 'Future<void> _loadRemoteEpisode(');
    expect(restore.contains('_showRemoteGraphicTrackViaPlayer('), isTrue);
    expect(restore.contains('!track.isText'), isTrue);
  });

  test('互联 host 能回传整轨时只给 host 整轨来源；其它来源交播放器按流地址抽取', () {
    final String body = methodBody(
      src,
      'GraphicSubtitleTimingInput? buildRemoteGraphicSubtitleTimingInput(',
    );
    expect(
      body.contains('is! RemoteVideoGraphicSubtitleTrackFetch) return null'),
      isTrue,
    );
    expect(body.contains('GraphicSubtitleTimingHostTrack('), isTrue);
    expect(body.contains('getRemoteVideoGraphicSubtitleTrack('), isTrue);
    expect(body.contains('getRemoteVideoGraphicSubtitleTrackHeader('), isTrue);
  });

  test('模糊遮蔽层与时间表共用网络流抽取输入（整条流只读一遍）', () {
    expect(
      src.contains('regionInput:') &&
          src.contains('controller.activeGraphicSubtitleRemoteInput'),
      isTrue,
    );
  });

  test('模糊遮蔽层拿控制器已到手的位图时间表（互联播放按位图糊的唯一来源）', () {
    // 互联时遮蔽层推导不出抽轨请求（client 不许整片读流），只能用控制器从 host 下回来
    // 的那份整轨解出的位图框。
    expect(
      src.contains('regionTrack: controller.graphicSubtitleRegionTrack'),
      isTrue,
    );
  });
}
