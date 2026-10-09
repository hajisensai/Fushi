import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_double_tap_center_action.dart';

/// 双击落空（中带；或「双击快退快进」关闭时画面任意位置）的分流判据。
///
/// 页面 `_handleVideoPointerUp` 先跑 `_handleDoubleTapSeek`：设置开启时左 / 右三分之一
/// 命中即快退快进并早返回；设置关闭（默认 0）时它整体返回 false（源码守卫
/// `video_double_tap_seek_guard_test.dart` 钉住 `if (action == 0) return false;`），
/// 于是任意位置的双击都落到这里。用户 2026-10-05 拍板：桌面触屏与移动端一致——
/// 落空双击 = 播放/暂停、不进全屏；桌面鼠标双击仍切全屏。
void main() {
  VideoDoubleTapCenterAction resolve({
    required bool desktop,
    required bool touch,
    bool tapTogglesPlayback = true,
  }) =>
      resolveVideoDoubleTapCenterAction(
        desktopControls: desktop,
        touchLikePointer: touch,
        tapTogglesPlayback: tapTogglesPlayback,
      );

  test('桌面触屏双击中带（双击快退快进开启时）= 播放/暂停，不进全屏', () {
    expect(resolve(desktop: true, touch: true),
        VideoDoubleTapCenterAction.togglePlayback);
  });

  test('桌面触屏双击快退快进关闭（默认）时任意位置双击 = 播放/暂停', () {
    // 关闭时左右分区不生效，左 / 中 / 右的双击全部落到本判据——判据不收位置，
    // 结论只能与位置无关。
    expect(resolve(desktop: true, touch: true),
        VideoDoubleTapCenterAction.togglePlayback);
  });

  test('桌面鼠标双击中带仍切全屏，且不受「点击画面播放/暂停」开关影响', () {
    expect(resolve(desktop: true, touch: false),
        VideoDoubleTapCenterAction.toggleFullscreen);
    expect(resolve(desktop: true, touch: false, tapTogglesPlayback: false),
        VideoDoubleTapCenterAction.toggleFullscreen);
  });

  test('移动端双击 = 播放/暂停（BUG-221，与指针类型无关）', () {
    expect(resolve(desktop: false, touch: true),
        VideoDoubleTapCenterAction.togglePlayback);
    expect(resolve(desktop: false, touch: false),
        VideoDoubleTapCenterAction.togglePlayback);
  });

  test('关掉「点击画面播放/暂停」后触屏双击不改播放态，也不进全屏', () {
    expect(resolve(desktop: true, touch: true, tapTogglesPlayback: false),
        VideoDoubleTapCenterAction.none);
    expect(resolve(desktop: false, touch: true, tapTogglesPlayback: false),
        VideoDoubleTapCenterAction.none);
  });
}
