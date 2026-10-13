// BUG-3296 取证守卫：画质增强「开 / 关」在 app 侧下发给 libmpv 的差异只有缩放链
// （scale / cscale / dscale / *-antiring）与 glsl-shaders；hwdec、几何（video-aspect-override /
// video-zoom / panscan / video-rotate）等完全相同。真机定位压扁问题时以此为前提——
// 若哪天开关顺带改了 hwdec 或几何属性，这里先红。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_mpv_config.dart';
import 'package:fushi/src/media/video/video_shader_manager.dart';

Set<String> _diffKeys(Map<String, String> a, Map<String, String> b) =>
    <String>{...a.keys, ...b.keys}.where((String k) => a[k] != b[k]).toSet();

void main() {
  test('Windows 桌面：highQuality 开 / 关只改缩放链，hwdec 与几何一致', () {
    final VideoMpvConfig on = VideoMpvConfig.defaults.copyWith(
      highQuality: true,
    );
    final VideoMpvConfig off = VideoMpvConfig.defaults.copyWith(
      highQuality: false,
    );
    final Map<String, String> pOn = buildMpvProperties(
      on,
      isAndroid: false,
      isMobile: false,
      isWindows: true,
      isApple: false,
    );
    final Map<String, String> pOff = buildMpvProperties(
      off,
      isAndroid: false,
      isMobile: false,
      isWindows: true,
      isApple: false,
    );

    expect(_diffKeys(pOn, pOff), <String>{
      'scale',
      'cscale',
      'dscale',
      'scale-antiring',
      'cscale-antiring',
    });
    expect(pOff['scale'], 'bilinear');
    expect(pOn['scale'], 'ewa_lanczossharp');
    // 两态都是同一张 hwdec 候选表 [kWindowsAutoHwdec]（零拷贝 d3d11va 优先）；单测进程不装配
    // 显卡能力，故是不含 nvdec-copy 的那张（见 resolvePlatformHwdec）。
    expect(pOn['hwdec'], kWindowsAutoHwdec);
    expect(pOff['hwdec'], kWindowsAutoHwdec);
  });

  test('关档的着色器下发 = 清空 glsl-shaders，不触碰其它属性', () {
    expect(buildShaderChangeListCommands(const <String>[]), <List<String>>[
      <String>['change-list', 'glsl-shaders', 'clr', ''],
    ]);
  });
}
