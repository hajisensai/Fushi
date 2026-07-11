import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫（BUG-739）：**反复切换音频输出设备后视频音量不衰减的根因不变量**。
///
/// 背景：视频走 media_kit 裸 `Player()`（`audio-device=auto`）。OS 切换音频输出设备时，
/// libmpv 重建 ao，其软件 `volume` 属性可能被重置/衰减，media_kit 被动把降低值镜像进
/// `state.volume`。而 [VideoPlayerController.volume] getter 直接读 `state.volume` 作真值，
/// app 只在 `load()` 与用户操作时下发音量、之后从不回补 —— 于是反复切换设备后视频音量
/// 逐步变小甚至归零。查词音频（`desktop_audio_playback.dart`）每次播放前都 `setVolume`
/// 绝对值，天然免疫，故只有视频受影响。
///
/// 根因修复：订阅 media_kit `stream.audioDevice`，在当前输出设备变化时把「音量目标」
/// （`_lastVolume`，静音时为 0）重新下发给 libmpv，恢复「libmpv 音量 == app 目标」不变量
/// （与查词路径每次重设绝对音量同构）。本守卫钉死这条订阅存在且回补的是目标音量，
/// 防止有人删掉订阅或改成回补错误的值而悄悄回归本 bug。真实的设备切换音量行为只能在
/// 桌面真机（Win/macOS）切换输出设备复测；此守卫锁住静态不变量。
void main() {
  String read(String relPath) {
    for (final String prefix in <String>['', '../']) {
      final File f = File('$prefix$relPath');
      if (f.existsSync()) return f.readAsStringSync();
    }
    throw StateError('找不到文件：$relPath');
  }

  group('视频音量设备切换不衰减不变量 (BUG-739)', () {
    final String src = read('lib/src/media/video/video_player_controller.dart');

    test('VideoPlayerController 订阅 stream.audioDevice（设备切换后回补音量）', () {
      expect(src.contains('stream.audioDevice.listen'), isTrue,
          reason: '必须订阅 media_kit stream.audioDevice：OS 切换输出设备后 libmpv '
              '重建 ao 会衰减软件 volume，app 需在设备变化时回补音量目标');
    });

    test('设备切换回调回补的是「音量目标」_lastVolume（静音时为 0），不是别的值', () {
      // 锚到订阅回调体：`stream.audioDevice.listen(...) { ... setVolume(... _lastVolume ...) }`。
      final int at = src.indexOf('stream.audioDevice.listen');
      expect(at, greaterThanOrEqualTo(0),
          reason: '找不到 stream.audioDevice.listen 订阅');
      // 取订阅点之后一小段，确认回调里下发的是 _muted ? 0.0 : _lastVolume。
      final String after = src.substring(at, at + 400);
      expect(after.contains('setVolume'), isTrue,
          reason: '设备切换回调必须调用 setVolume 把音量重新下发给 libmpv');
      expect(after.contains('_lastVolume'), isTrue,
          reason: '回补的必须是音量目标 _lastVolume（单一语义真值），而不是读回已衰减的 '
              'state.volume/volume getter');
      expect(after.contains('_muted'), isTrue,
          reason: '回补须尊重静音态：静音时下发 0，否则设备切换会解除用户的静音');
    });

    test('_audioDeviceSub 在 dispose 里被取消（防订阅泄漏）', () {
      expect(src.contains('_audioDeviceSub'), isTrue, reason: '设备变化订阅须存字段以便取消');
      expect(src.contains('_audioDeviceSub?.cancel()'), isTrue,
          reason: 'dispose 必须取消 _audioDeviceSub，随 Player 生命周期释放');
    });

    test('保留根因说明注释（防注释丢失后被误删订阅）', () {
      expect(src.contains('BUG-739'), isTrue,
          reason: '订阅点/字段须保留 BUG-739 根因注释，让 reviewer 看到不变量来由');
    });
  });

  group('查词音频每次播放重设绝对音量（对照：为何查词免疫 BUG-739）', () {
    test('desktop_audio_playback 每次播放前 setVolume 绝对值', () {
      final String src = read('lib/src/utils/misc/desktop_audio_playback.dart');
      expect(src.contains('setVolume'), isTrue,
          reason: '查词音频免疫本 bug 的根因：每个 clip 播放前都重设绝对音量，'
              '天然抹平 libmpv 漂移。删掉它会让查词也回归设备切换音量衰减');
    });
  });
}
