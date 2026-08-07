import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1307 源码守卫：YouTube 首帧被「字幕解析(~19s) + 重复 videos.get 取被丢弃的 title
/// (~9s)」串行阻塞 ~28s。修复拆两段——① 快解析 gate（只 getManifest 取流即起播，跳过
/// videos.get 与字幕）；② 字幕后置（load 返回后异步 resolveYoutubeCaptions，cue 灌 1302 的
/// YouTube 字幕轨 [_kYoutubeCaptionsSource]，而非前置注入 preresolvedCues）；③ A1 多 client
/// 兜底（androidVr -> ios -> tv）；④ 阶段反馈提前到 buildStreamVideoLaunch 之前。
///
/// 首帧真机联网测速（>25s -> ~getManifest）需真设备，见 TODO-1307 报告；此处落最强可落地层：
/// 源码语料守卫（切片断言快解析/后置/A1/A2/阶段反馈均在位，删任一即红），与 1302 守卫同构。
void main() {
  // 归一 CRLF -> LF（去掉 CR），避免行尾差异影响子串断言（不用字符串转义字面量）。
  String read(String p) =>
      File(p).readAsStringSync().replaceAll(String.fromCharCode(13), '');

  late String launchSrc;
  late String pageSrc;
  late String resolverSrc;
  setUpAll(() {
    launchSrc = read('lib/src/media/video/stream_video_launch.dart');
    pageSrc = read('lib/src/pages/implementations/video_fushi_page.dart');
    resolverSrc = read('lib/src/media/video/youtube_source_resolver.dart');
  });

  test('① 快解析 gate：buildStreamVideoLaunch 的 YouTube 分支用 withCaptions:false',
      () {
    expect(
      // TODO-1314：快解析 gate 现经可注入的默认 resolver 闭包（参数名 u）保留，行为不变。
      launchSrc.contains('resolveYoutubeSource(u, withCaptions: false)'),
      isTrue,
      reason: 'YouTube 分支必须走快解析 gate（withCaptions:false），不前置阻塞字幕/title',
    );
    expect(
      launchSrc.contains('resolveYoutubeSource(url);'),
      isFalse,
      reason: '不得用默认 withCaptions:true 在首帧前串行解析字幕 + 重复 videos.get',
    );
  });

  test('① 字幕后置：起播不再前置注入 preresolvedCues，改传 watch URL', () {
    expect(
      launchSrc.contains('preresolvedCues: resolved.cues'),
      isFalse,
      reason: '字幕后置：起播 client 不再前置注入 preresolvedCues（那是首帧前的字幕阻塞源）',
    );
    expect(
      launchSrc.contains('youtubeCaptionsUrl: url'),
      isTrue,
      reason: 'watch URL 必须存进 client 供 load 后字幕后置解析',
    );
  });

  test('② track-list-first：load 后异步解析字幕轨列表 + 回填 client + 自动应用最佳轨', () {
    // TODO-1302 回归修复：字幕轨**列表**（非单条 cue）后置解析，列表回填不依赖 cue 就绪 →
    // 修「快加载 withCaptions:false 后字幕整个消失」。
    expect(
      pageSrc.contains(
          'unawaited(_resolveDeferredYoutubeCaptionTracks(client, seq))'),
      isTrue,
      reason: 'load 后必须异步 kick 字幕轨列表解析（不阻塞首帧）',
    );
    expect(
      pageSrc.contains('resolveYoutubeCaptionTracks('),
      isTrue,
      reason:
          'track-list-first 必须走 resolveYoutubeCaptionTracks 入口（单次 getPlayerResponse 取轨表）',
    );
    expect(
      pageSrc.contains('client.setYoutubeCaptionTracks(tracks)'),
      isTrue,
      reason: '字幕轨列表必须回填 client.youtubeCaptionTracks，供字幕轨选择器渲染（不依赖 cue 就绪）',
    );
    expect(
      pageSrc.contains('pickBestYoutubeCaptionTrack(tracks'),
      isTrue,
      reason: '默认自动应用必须按 A3（人工>ASR·精确语言）选最佳轨',
    );
    expect(
      pageSrc.contains('_applyYoutubeCaptionTrack(controller, best'),
      isTrue,
      reason: '选中轨必须经 _applyYoutubeCaptionTrack 懒下载其 cue 挂 overlay',
    );
  });

  test('② 字幕轨列表回填不被「无 cue」门控（修回归：列表独立于 cue 解析）', () {
    // 回归根因：旧 _resolveDeferredYoutubeCaptions 把字幕轨行 + overlay 都吊在一次 cue 解析成败上
    // （preresolvedCues.isEmpty 门控），一次解析空/失败 → 选择器与 overlay 双空。新模型只以
    // youtubeCaptionsUrl 非空触发轨列表解析，列表回填与 cue 下载解耦。
    expect(
      pageSrc.contains(
          'client is UrlStreamVideoClient && client.youtubeCaptionsUrl != null'),
      isTrue,
      reason: '字幕轨后置只以 youtubeCaptionsUrl 非空触发，不再用 preresolvedCues.isEmpty 门控',
    );
    expect(
      pageSrc.contains('client.preresolvedCues.isEmpty &&'),
      isFalse,
      reason: '不得再用 preresolvedCues.isEmpty 门控字幕轨后置（那把列表吊死在一次 cue 解析上）',
    );
  });

  test('③ A1 多 client 兜底：androidVr -> ios -> tv 且逐个取（不合并）', () {
    expect(
      resolverSrc.contains('kYoutubeManifestClientFallback'),
      isTrue,
      reason: 'A1：必须有多 client 兜底顺序常量',
    );
    expect(
      resolverSrc.contains('_getManifestWithClientFallback(client, videoId'),
      isTrue,
      reason: 'A1：resolveYoutubeSource 必须经逐个兜底 helper 取 manifest',
    );
    expect(
      resolverSrc.contains('ytClients: <yt.YoutubeApiClient>[api]'),
      isTrue,
      reason: 'A1：必须对单一 client 逐个取，避免多 client 流合并致选中 403 直链',
    );
  });

  test('④ 阶段反馈提前：connecting 在 buildStreamVideoLaunch 调用之前', () {
    final int iConnect = pageSrc.indexOf('// TODO-1307：把「正在连接视频流…」阶段反馈提前');
    final int iBuild = pageSrc.indexOf('await buildStreamVideoLaunch(row)');
    expect(iConnect, greaterThan(0),
        reason: 'stream book 分支必须提前置 connecting 阶段反馈');
    expect(iBuild, greaterThan(0));
    expect(iConnect, lessThan(iBuild),
        reason: 'connecting 阶段必须在 buildStreamVideoLaunch（慢网可数秒）之前置起');
  });

  test('A2：字幕解析只做一次 getPlayerResponse（不再取多余 WatchPage）', () {
    // 不再 import watch_page.dart、不再调用 WatchPage.get（androidVr getPlayerResponse 无需
    // WatchPage 即返回全部字幕轨，实测省 ~1.3s 往返）。注意断言真实用法而非注释里的词。
    expect(
      resolverSrc.contains('watch_page.dart'),
      isFalse,
      reason: 'A2：不得再 import 内部 WatchPage（消除多余往返 + 未用 import 告警）',
    );
    expect(
      resolverSrc.contains('WatchPage.get('),
      isFalse,
      reason: 'A2：字幕解析不得再取 WatchPage',
    );
    expect(
      resolverSrc
          .contains('.getPlayerResponse(id, yt.YoutubeApiClient.androidVr)'),
      isTrue,
      reason: 'A2：字幕只做一次 androidVr getPlayerResponse',
    );
  });
}
