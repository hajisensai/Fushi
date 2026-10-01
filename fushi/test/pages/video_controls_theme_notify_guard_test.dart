import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// BUG-2832：media_kit fork 的控制条 theme `updateShouldNotify` 原样继承了上游的
/// 反写——`identical(normal, old.normal) && identical(fullscreen, old.fullscreen)`，
/// 即**什么都没变时才通知、换了新 theme 反而不通知**。控制条主体是
/// `const _Material(Desktop)VideoControls()`，父级重建会被短路，这条通知是新 theme
/// 送达它的唯一途径。于是开字幕列表把播放区挤进 mini 档后，本仓按新密度画出了居中
/// 大三键，media_kit 却还拿旧 theme 画完整顶 / 底栏——截图里两套控件并存。
///
/// 这里直接拿真实的 fork 部件调 `updateShouldNotify`（不需要 libmpv）。
void main() {
  // 两个 theme 实例必须是不同对象：不加 const 构造，免得被规范化成同一个实例。
  group('MaterialVideoControlsTheme（移动端）', () {
    final MaterialVideoControlsThemeData a =
        // ignore: prefer_const_constructors
        MaterialVideoControlsThemeData();
    final MaterialVideoControlsThemeData b =
        // ignore: prefer_const_constructors
        MaterialVideoControlsThemeData();

    MaterialVideoControlsTheme theme(
      MaterialVideoControlsThemeData normal,
      MaterialVideoControlsThemeData fullscreen,
    ) => MaterialVideoControlsTheme(
      normal: normal,
      fullscreen: fullscreen,
      child: const SizedBox.shrink(),
    );

    test('换了新 theme 实例必须通知依赖方重建', () {
      expect(theme(b, a).updateShouldNotify(theme(a, a)), isTrue);
      expect(theme(a, b).updateShouldNotify(theme(a, a)), isTrue);
    });

    test('同一对实例不必通知', () {
      expect(theme(a, b).updateShouldNotify(theme(a, b)), isFalse);
    });
  });

  group('MaterialDesktopVideoControlsTheme（桌面端）', () {
    final MaterialDesktopVideoControlsThemeData a =
        // ignore: prefer_const_constructors
        MaterialDesktopVideoControlsThemeData();
    final MaterialDesktopVideoControlsThemeData b =
        // ignore: prefer_const_constructors
        MaterialDesktopVideoControlsThemeData();

    MaterialDesktopVideoControlsTheme theme(
      MaterialDesktopVideoControlsThemeData normal,
      MaterialDesktopVideoControlsThemeData fullscreen,
    ) => MaterialDesktopVideoControlsTheme(
      normal: normal,
      fullscreen: fullscreen,
      child: const SizedBox.shrink(),
    );

    test('换了新 theme 实例必须通知依赖方重建', () {
      expect(theme(b, a).updateShouldNotify(theme(a, a)), isTrue);
      expect(theme(a, b).updateShouldNotify(theme(a, a)), isTrue);
    });

    test('同一对实例不必通知', () {
      expect(theme(a, b).updateShouldNotify(theme(a, b)), isFalse);
    });
  });
}
