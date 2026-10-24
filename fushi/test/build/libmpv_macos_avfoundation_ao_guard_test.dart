import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/darwin_vendored_libmpv.dart';

/// BUG-3662：macOS 随包 libmpv 必须同时编进 `coreaudio` 与 `avfoundation` 两个音频输出。
///
/// macOS 27 上 mpv 的 `ao_coreaudio` 给 AudioUnit 设输入声道布局一律失败
/// （`unable to set the input channel layout on the audio unit (-50)`，与片源、声道
/// 设置无关，Homebrew 原版 mpv 同样复现）。原来的构建 `-Dauto_features=disabled`
/// 只开了 `coreaudio`，失败后没有可退的输出，mpv 打出
/// `Could not open/initialize audio device -> no sound` 并停用音轨：所有视频只有画面。
/// mpv 默认输出顺序里 `avfoundation` 紧跟 `coreaudio`，编进去后 coreaudio 起不来就
/// 自动退到它（AVSampleBufferAudioRenderer），coreaudio 正常的机器行为不变。
///
/// 产物来自 hajisensai/libmpv-darwin-build 的 `nix/packages/mk-pkg-mpv/video.nix`
/// （macOS 分支 `-Davfoundation=enabled`）；换回只带 coreaudio 的产物会在这里红。
void main() {
  test('macOS libmpv 每个 CPU slice 都带 coreaudio 与 avfoundation 音频输出', () {
    for (final DarwinLibmpvSlice slice in verifiedDarwinLibmpv('macos')) {
      // 两个字符串都是 mpv 里 `struct ao_driver.description`，只有编进对应
      // ao_*.c / ao_*.m 时才会出现在二进制里。
      expect(
        slice.mpv,
        contains('AVFoundation AVSampleBufferAudioRenderer'),
        reason:
            '${slice.identity}: avfoundation AO missing, no fallback when '
            'coreaudio fails to initialize (BUG-3662)',
      );
      expect(
        slice.mpv,
        contains('CoreAudio AudioUnit'),
        reason: '${slice.identity}: coreaudio AO missing',
      );
    }
  });

  test('本仓 Darwin 构建叠加的 macOS mpv 选项同样开启 avfoundation', () {
    final String overlay = File(
      '../tool/bluray/platforms/patches/darwin-build.patch',
    ).readAsStringSync();
    expect(
      overlay,
      contains('+      OPTIONS+=(-Dcoreaudio=enabled -Davfoundation=enabled '),
    );
  });
}
