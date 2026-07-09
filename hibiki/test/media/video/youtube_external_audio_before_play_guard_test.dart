import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫（TODO-1280）：**YouTube 分离流的 audio-only 音轨必须在恢复 seek + play() 之前外挂**。
///
/// 背景（用户原报）：YouTube 视频「一开始没声音、点暂停也没反应，手动跳转（seek）之后才有声」。
/// 根因：YouTube 走 ANDROID_VR 分离流——video-only 主流经 libmpv 播放、audio-only 流经
/// `AudioTrack.uri`（media_kit → libmpv `audio-add <url> select`）外挂。旧实现在
/// `controller.load()` **返回之后**（此时 `player.play()` 已开始播放）才在页面侧调
/// `setExternalAudioTrack` 外挂音轨。libmpv 对「播放已开始后才 audio-add」的外挂音频不会
/// 自动 seek 到当前时间轴 → 新音频 demuxer 从 0 起、与视频错位/静默，直到用户手动 seek
/// 触发所有源重新初始化才同步出声。
///
/// 根因修复：把 audio-only 音轨的外挂下沉进 `load()`，放在 http-header-fields 注入之后
/// （音频流同走 googlevideo，UA 不匹配会 403）、**恢复 seek + play() 之前**。这样起播
/// （位置 0）或恢复 seek（跳到断点）时都会把外挂音频一并同步 → 初始就有声。
///
/// 真实音画同步只能在真机（可能 ANDROID_VR 流）复测；此守卫锁住「外挂音轨早于 seek/play」
/// 的静态时序不变量，防止有人把它挪回 load 之后（回归无声）。
void main() {
  String read(String relPath) {
    for (final String prefix in <String>['', '../']) {
      final File f = File('$prefix$relPath');
      if (f.existsSync()) return f.readAsStringSync();
    }
    throw StateError('找不到文件：$relPath');
  }

  group('YouTube 外挂音轨早于 seek/play 不变量 (TODO-1280)', () {
    final String ctrl =
        read('lib/src/media/video/video_player_controller.dart');

    test('load() 有 externalAudioTrackUrl 参数（音轨 URL 下沉进 load）', () {
      expect(ctrl.contains('String? externalAudioTrackUrl'), isTrue,
          reason:
              'load() 必须接收 externalAudioTrackUrl，才能在 load 内 seek/play 之前外挂');
    });

    test('load() 内经 AudioTrack.uri 外挂 externalAudioTrackUrl', () {
      expect(ctrl.contains('AudioTrack.uri(externalAudioTrackUrl)'), isTrue,
          reason:
              '必须用 AudioTrack.uri(externalAudioTrackUrl)（libmpv audio-add）外挂音轨');
    });

    test('外挂音轨 (audio-add) 出现在恢复 seek 与 play() 之前', () {
      final int attachAt =
          ctrl.indexOf('AudioTrack.uri(externalAudioTrackUrl)');
      final int seekAt =
          ctrl.indexOf('player.seek(Duration(milliseconds: resolvedStartMs))');
      final int playAt = ctrl.indexOf('await player.play();');
      expect(attachAt, greaterThanOrEqualTo(0), reason: '找不到外挂音轨调用');
      expect(seekAt, greaterThanOrEqualTo(0), reason: '找不到恢复 seek 调用');
      expect(playAt, greaterThanOrEqualTo(0),
          reason: '找不到 autoPlay 的 play() 调用');
      expect(attachAt, lessThan(seekAt),
          reason: '外挂音轨必须在恢复 seek 之前，seek 才能把音频同步到断点位置');
      expect(attachAt, lessThan(playAt),
          reason: '外挂音轨必须在 play() 之前，否则播放已开始、新加音频不会自动 seek → 无声');
    });

    test('外挂音轨在 http-header-fields 注入之后（audio-only 流同需 UA 防 403）', () {
      final int headerAt = ctrl.indexOf('applyHttpHeaderFieldsToPlayer');
      final int attachAt =
          ctrl.indexOf('AudioTrack.uri(externalAudioTrackUrl)');
      expect(headerAt, greaterThanOrEqualTo(0));
      expect(attachAt, greaterThan(headerAt),
          reason:
              'audio-only 流经 googlevideo，须在 http-header-fields 全局属性设好后再 audio-add');
    });

    test('旧的 play 之后外挂路径已移除（不得再暴露 setExternalAudioTrack）', () {
      expect(ctrl.contains('Future<void> setExternalAudioTrack('), isFalse,
          reason: 'setExternalAudioTrack 是 load 返回后（play 已开始）才外挂的错误路径，'
              '已下沉进 load，必须删除以杜绝再次误用');
    });
  });

  group('页面按新契约透传音轨 URL、不再 load 后外挂 (TODO-1280)', () {
    final String page =
        read('lib/src/pages/implementations/video_hibiki_page.dart');

    test('远端 YouTube load 把 audioStreamUrl 透传给 externalAudioTrackUrl', () {
      expect(
          page.contains('externalAudioTrackUrl: urls.audioStreamUrl'), isTrue,
          reason: '页面必须把 audio-only 流 URL 透传进 _applyLoad→load 在 seek/play 前外挂');
    });

    test('页面不再在 load 返回后调 setExternalAudioTrack（回归无声）', () {
      expect(page.contains('setExternalAudioTrack('), isFalse,
          reason: 'load 返回时 play 已开始，此时外挂音轨不会自动 seek 到当前位置 → 无声');
    });
  });
}
