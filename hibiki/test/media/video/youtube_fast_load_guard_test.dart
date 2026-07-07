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
    pageSrc = read('lib/src/pages/implementations/video_hibiki_page.dart');
    resolverSrc = read('lib/src/media/video/youtube_source_resolver.dart');
  });

  test('① 快解析 gate：buildStreamVideoLaunch 的 YouTube 分支用 withCaptions:false',
      () {
    expect(
      launchSrc.contains('resolveYoutubeSource(url, withCaptions: false)'),
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

  test('② 字幕后置接 1302 字幕轨：load 后异步解析 + 回填 client + 登记合成哨兵', () {
    expect(
      pageSrc
          .contains('unawaited(_resolveDeferredYoutubeCaptions(client, seq))'),
      isTrue,
      reason: 'load 后必须异步 kick 字幕后置解析（不阻塞首帧）',
    );
    expect(
      pageSrc.contains('resolveYoutubeCaptions(captionsUrl)'),
      isTrue,
      reason: '字幕后置必须走 resolveYoutubeCaptions 入口',
    );
    expect(
      pageSrc.contains('client.setPreresolvedCues(cues)'),
      isTrue,
      reason: '字幕就绪必须回填 client.preresolvedCues，供 1302 菜单渲染/重选',
    );
    expect(
      pageSrc.contains('_currentSubtitleSource = _kYoutubeCaptionsSource'),
      isTrue,
      reason: '自动应用必须登记 1302 合成源哨兵 _kYoutubeCaptionsSource',
    );
  });

  test('② 只 YouTube 客户端且无既有 cue 时触发字幕后置（不重复解析）', () {
    expect(
      pageSrc.contains('client.preresolvedCues.isEmpty &&') &&
          pageSrc.contains('client.youtubeCaptionsUrl != null'),
      isTrue,
      reason: '字幕后置只在 YouTube 客户端(youtubeCaptionsUrl 非空)且尚无预解析 cue 时触发',
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
