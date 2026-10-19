import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// Windows HDR 只有一个窗口：视频是 Flutter 纹理，HDR 时引擎交换链切 FP16 scRGB
/// （`docs/specs/2026-10-06-hdr-in-flutter-compositor.md`）。
///
/// 早先的「宿主窗直通」让 libmpv 的 `vo=gpu-next` 画进钉在主窗正后方的独立顶层窗口，
/// 主窗 DWM blur-behind 挖洞透出它——两个窗口在全屏切换 / 移动 / 层级变化时会错位
/// （BUG-2964 的顶部横线、全屏时界面短暂消失）。Windows libmpv 打上
/// `mpv-gl-dovi-p5.patch` 后杜比视界也不再需要它，整套已删除。这些断言咬住它不回来，
/// 以及仍然要成立的单窗口契约。
void main() {
  final String runnerDir = _runnerDir();
  final String window = _read('$runnerDir/flutter_window.cpp');
  final String cmake = _read('$runnerDir/CMakeLists.txt');

  test('runner 里没有第二个视频窗口', () {
    expect(File('$runnerDir/hdr_video_host_window.cpp').existsSync(), isFalse);
    expect(File('$runnerDir/hdr_video_host_window.h').existsSync(), isFalse);
    expect(cmake, isNot(contains('hdr_video_host_window')));
    for (final FileSystemEntity f in Directory(runnerDir).listSync()) {
      if (f is! File || !(f.path.endsWith('.cpp') || f.path.endsWith('.h'))) {
        continue;
      }
      final String code = maskComments(f.readAsStringSync());
      expect(
        code,
        isNot(contains('DwmEnableBlurBehindWindow')),
        reason: '${f.path}：主窗透明挖洞只为宿主窗存在过',
      );
    }
  });

  test('Dart 侧不切 vo、不建宿主窗、不在视频纹理上挖洞', () {
    final String lib = '${_fushiDir()}/lib';
    for (final String path in <String>[
      '$lib/src/media/video/video_player_controller.dart',
      '$lib/src/media/video/video_hdr_output.dart',
      '$lib/src/pages/implementations/video_fushi_page.dart',
      '$lib/src/pages/implementations/video_fushi/layout.part.dart',
      '$lib/src/pages/implementations/video_fushi/fullscreen.part.dart',
      '$lib/src/utils/components/fushi_desktop_title_bar.dart',
    ]) {
      final String code = maskComments(_read(path));
      for (final String forbidden in <String>[
        'gpu-next',
        "'wid'",
        'hdrHost',
        'HdrHost',
      ]) {
        expect(code, isNot(contains(forbidden)), reason: '$path：$forbidden');
      }
      // 透明底只为「底层合成」（WebView2 垫在 Flutter 下面，underlay_composition.dart）
      // 存在：宿主窗那套挖洞已删，任何透明分支都必须由 underlayCompositionActive 驱动。
      if (code.contains('Colors.transparent : colors.surface')) {
        expect(
          code,
          contains('underlayCompositionActive'),
          reason: '$path：透明底色只能跟底层合成走',
        );
      }
    }
    final String texture = _read(
      '${_fushiDir()}/../third_party/media_kit_video/lib/src/video/video_texture.dart',
    );
    expect(texture, isNot(contains('controller.hidden')));
  });

  // BUG-2964：主窗 DWM 边距只能由一处按 main_surface_composition.h 派生。
  test('主窗 DWM 边距只有一个写入者，按 MainSurfaceState 派生', () {
    expect(
      'DwmExtendFrameIntoClientArea('.allMatches(window).length,
      1,
      reason: '边距写入必须只在 ApplyMainSurfaceComposition 一处',
    );
    final String body = _functionBody(
      window,
      'void FlutterWindow::ApplyMainSurfaceComposition(',
    );
    expect(body, contains('fushi::MainFrameMargins(main_surface_state())'));
    expect(body, contains('DwmExtendFrameIntoClientArea('));
  });

  test('字幕层 HDR 亮度归一：runner 回报 SDR 白电平、HDR 输出时激活也重读、两层图形都包上', () {
    final String display = _read('$runnerDir/hdr_display_info.cpp');
    expect(cmake, contains('"hdr_display_info.cpp"'));
    // SDR 白电平只有 DisplayConfig 给，DXGI GetDesc1 没有。
    expect(display, contains('DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL'));
    expect(display, contains('QuerySdrWhiteNits(desc.DeviceName)'));
    final String dart = _read(
      '${_fushiDir()}/lib/src/media/video/video_hdr_output.dart',
    );
    expect(window, contains('"sdrWhiteNits"'));
    expect(dart, contains("value['sdrWhiteNits']"));
    // 改「SDR 内容亮度」滑块没有窗口消息：HDR 输出开着时主窗重新激活也要通知重判。
    expect(window, contains('compositor_hdr_output_on_ = enabled && on;'));
    expect(window, contains('message == WM_DISPLAYCHANGE || hdr_activated'));
    // 弹幕与字幕都在视频平面上，必须都经 _hdrGraphicsWhiteLevel。
    final String layout = _read(
      '${_fushiDir()}/lib/src/pages/implementations/video_fushi/layout.part.dart',
    );
    for (final String overlay in <String>[
      'VideoDanmakuOverlay(',
      'VideoSubtitleOverlay(',
    ]) {
      final int at = layout.indexOf(overlay);
      expect(at, greaterThan(0), reason: overlay);
      expect(
        layout.substring(at - 120, at),
        contains('_hdrGraphicsWhiteLevel('),
        reason: overlay,
      );
    }
  });

  test('通道名与方法两侧一致，宿主窗方法不再存在', () {
    final String dart = _read(
      '${_fushiDir()}/lib/src/media/video/video_hdr_output.dart',
    );
    expect(dart, contains("'app.fushi/hdr_output'"));
    expect(window, contains('"app.fushi/hdr_output"'));
    for (final String method in <String>[
      'displayInfo',
      'compositorHdrSupported',
      'setCompositorHdrOutput',
    ]) {
      expect(window, contains('method == "$method"'), reason: method);
      expect(dart, contains("'$method'"), reason: method);
    }
    for (final String method in <String>['create', 'setRect', 'destroy']) {
      expect(window, isNot(contains('method == "$method"')), reason: method);
    }
    expect(window, contains('"onDisplayChanged"'));
  });
}

String _fushiDir() {
  final Directory cwd = Directory.current;
  if (File('${cwd.path}/pubspec.yaml').existsSync() &&
      Directory('${cwd.path}/windows/runner').existsSync()) {
    return cwd.path;
  }
  return '${cwd.path}/fushi';
}

String _runnerDir() => '${_fushiDir()}/windows/runner';

String _read(String path) => File(path).readAsStringSync();

/// [source] 里以 [signature] 开头的 C++ 函数定义，截到第一个列首的 `}`。
String _functionBody(String source, String signature) {
  final int at = source.indexOf(signature);
  expect(at, greaterThanOrEqualTo(0), reason: signature);
  final Match? close = RegExp(r'\r?\n\}\r?\n').firstMatch(source.substring(at));
  expect(close, isNotNull, reason: signature);
  return source.substring(at, at + close!.start);
}
