import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-3874：手机遥控器对「浏览器里的视频」完全无法控制——遥控宿主只有原生播放器页的
/// 本地 / 远端片源登记过绑定，网页站点的两种播放形态（原生播放器页的网页档、内置网页
/// 播放器页）从没登记，手机一直停在「等待电脑打开视频」。
///
/// 两页的绑定都是页面 State 的私有方法、依赖 WebView2，没有可注入的缝；与
/// `remote_mine_fields_media_ready_test.dart` 的接线守卫同形，钉住「登记了」与「按网页档
/// 分流的执行体」。执行体里可单测的部分在 `video_remote_binding_support_test.dart`。
void main() {
  group('原生播放器页网页档', () {
    late String webSource;
    late String remote;
    setUpAll(() {
      webSource = maskComments(
        File(
          'lib/src/pages/implementations/video_fushi/web_source.part.dart',
        ).readAsStringSync(),
      );
      remote = maskComments(
        File(
          'lib/src/pages/implementations/video_fushi/remote_control.part.dart',
        ).readAsStringSync(),
      );
    });

    test('_initWebSource 装好 controller 后登记遥控绑定', () {
      final String body = methodBody(webSource, 'Future<void> _initWebSource(');
      final int adopt = body.indexOf('_controller = controller;');
      final int register = body.indexOf('_registerVideoRemote(controller);');
      expect(adopt, greaterThanOrEqualTo(0));
      expect(register, greaterThan(adopt));
    });

    test('字幕轨 / 在线字幕 / 制卡按网页档分流，会话身份含站点视频 key', () {
      final String body = compactCode(
        methodBody(remote, 'void _registerVideoRemote('),
      );
      expect(body, contains('finalboolweb=controller.isWebBackend;'));
      expect(body, contains('mine:web?_mineRemoteWebCue:_mineRemoteVideoCue'));
      expect(
        body,
        contains(
          'subtitleTracks:web?_remoteWebSubtitleOptions:_remoteSubtitleOptions',
        ),
      );
      expect(body, contains('_downloadRemoteWebOnlineSubtitle(controller,id)'));
      expect(
        compactCode(methodBody(remote, 'String _videoRemoteIdentity(')),
        contains('controller.isWebBackend?_webVideoKey'),
      );
    });

    test('网页档在线字幕登记成站点视频的一条轨，不直接 setCues', () {
      final String body = methodBody(
        remote,
        'Future<VideoRemoteSubtitleApply> _downloadRemoteWebOnlineSubtitle(',
      );
      expect(body, contains('_webTracks[key] = WebVideoTrack('));
      expect(body, contains('_selectWebTrack(key);'));
      expect(body, isNot(contains('setCues(')));
    });
  });

  group('内置网页播放器页', () {
    late String page;
    setUpAll(() {
      page = maskComments(
        File(
          'lib/src/pages/implementations/web_video_fushi_page.dart',
        ).readAsStringSync(),
      );
    });

    test('_init 登记、dispose 撤销', () {
      expect(
        methodBody(page, 'Future<void> _init('),
        contains('_registerRemote();'),
      );
      expect(
        methodBody(page, 'void dispose('),
        contains('_unregisterRemote();'),
      );
    });

    test('制卡交接页（机器驱动重放）不登记', () {
      final String body = compactCode(
        methodBody(page, 'void _registerRemote('),
      );
      expect(
        body,
        contains(
          'if(widget.autoRunMineQueue||widget.returnHostingAfterMining!=null){return;}',
        ),
      );
      expect(body, contains('_appModel.videoRemoteHost.register(binding);'));
    });

    test('播放控制意图都推进 controlRevision', () {
      for (final String method in <String>[
        'Future<void> _seekMs(',
        'Future<void> _play(',
        'Future<void> _pause(',
        'Future<void> _togglePlay(',
        'Future<void> _setRate(',
      ]) {
        expect(
          methodBody(page, method),
          contains('_remoteControlRevision++;'),
          reason: method,
        );
      }
    });

    test('手机关字幕后不再自动挑轨', () {
      expect(
        compactCode(methodBody(page, 'void _reselectTrack(')),
        contains('_subtitlesOff?null:chooseWebVideoTrackKey('),
      );
    });
  });
}
