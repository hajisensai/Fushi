import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 合成器内 HDR（`ci/patches/flutter-engine/<版本>/`）的源码守卫。
///
/// 这条链路横跨 Flutter 引擎补丁、ANGLE 补丁、media_kit 原生纹理和 runner，
/// 任何一环退回原样都不会编译失败，只会静默变成「HDR 被钳成 SDR」「上下颠倒」
/// 或「原版引擎下 app 起不来」——这些断言把实测踩过的点咬住。
void main() {
  final String fushi = _fushiDir();
  final String repo = Directory(fushi).parent.path;
  final String flutterVersion = _fvmFlutterVersion(fushi);
  final String patchDir = '$repo/ci/patches/flutter-engine/$flutterVersion';
  final String window = _read('$fushi/windows/runner/flutter_window.cpp');
  final String mediaKit = '$repo/third_party/media_kit_video/windows';

  test('引擎补丁目录与 .fvmrc 同版本（升级 Flutter 必须重新移植补丁）', () {
    final List<String> versions = Directory('$repo/ci/patches/flutter-engine')
        .listSync()
        .whereType<Directory>()
        .map(
          (Directory d) =>
              d.uri.pathSegments.lastWhere((String s) => s.isNotEmpty),
        )
        .toList();
    expect(versions, <String>[flutterVersion]);
    for (final String name in <String>[
      'engine-hdr-output.patch',
      'angle-scrgb-swapchain.patch',
      'README.md',
    ]) {
      expect(File('$patchDir/$name').existsSync(), isTrue, reason: name);
    }
  });

  test('artifacts.json 指向本仓 release 资产、带 SHA-256（CI 据此安装补丁引擎）', () {
    final Map<String, Object?> artifacts =
        jsonDecode(_read('$patchDir/artifacts.json')) as Map<String, Object?>;
    final String patchVersion = artifacts['patchVersion']! as String;
    final String url = artifacts['url']! as String;
    expect(artifacts['engineVersion'], matches(RegExp(r'^[0-9a-f]{40}$')));
    expect(artifacts['sha256'], matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(
      url,
      startsWith('https://github.com/hajisensai/Fushi/releases/download/'),
    );
    expect(url, contains('flutter-engine-$flutterVersion-$patchVersion/'));
    // 引擎 release 的 tag 不能像 app 版本号：app 更新检查与发布 workflow 都按
    // 「数字或 v+数字开头」认 app release。
    expect(url, isNot(contains('/download/v')));
  });

  test('补丁是 LF（git apply 在 CRLF 补丁上整份失败）', () {
    for (final String name in <String>[
      'engine-hdr-output.patch',
      'angle-scrgb-swapchain.patch',
    ]) {
      final List<int> bytes = File('$patchDir/$name').readAsBytesSync();
      expect(bytes.contains(13), isFalse, reason: name);
    }
  });

  test('ANGLE：scRGB 交换链必须 flip 模型 + SetColorSpace1，否则 DWM 钳到 1.0', () {
    final String angle = _read('$patchDir/angle-scrgb-swapchain.patch');
    expect(angle, contains('+    outExtensions->glColorspaceScrgbLinear'));
    expect(angle, contains('DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL'));
    expect(angle, contains('CheckColorSpaceSupport'));
    expect(angle, contains('SetColorSpace1(colorSpace)'));
    expect(angle, contains('DXGI_COLOR_SPACE_RGB_FULL_G10_NONE_P709'));
  });

  test('引擎：HDR 窗口 surface 带 scRGB-linear 色彩空间，且以它为能力前提', () {
    final String engine = _read('$patchDir/engine-hdr-output.patch');
    expect(
      RegExp(
        r'^\+\s+EGL_GL_COLORSPACE_KHR,$',
        multiLine: true,
      ).hasMatch(engine),
      isTrue,
    );
    expect(engine, contains('EGL_GL_COLORSPACE_SCRGB_LINEAR_EXT'));
    expect(engine, contains('"EGL_EXT_gl_colorspace_scrgb_linear"'));
  });

  test('引擎：输出 pass 保存并恢复 GL 状态（与 Skia 共用上下文，泄漏即 ANGLE 内崩溃）', () {
    final String engine = _read('$patchDir/engine-hdr-output.patch');
    expect(engine, contains('+class ScopedOutputPassState {'));
    expect(engine, contains('ScopedOutputPassState saved(*gl_, resolver_'));
    // 恢复属性 0 的指针 / 开关、ARRAY_BUFFER、程序与 0 号单元纹理。
    for (final String restore in <String>[
      'gl_.VertexAttribPointer(0, attrib_size_',
      'gl_.BindBuffer(GL_ARRAY_BUFFER, array_buffer_);',
      'gl_.UseProgram(program_);',
      'gl_.BindTexture(GL_TEXTURE_2D, texture0_);',
    ]) {
      expect(engine, contains(restore), reason: restore);
    }
  });

  test('runner 运行期解析补丁导出：原版引擎没有它也必须能启动', () {
    expect(window, contains('GetProcAddress('));
    expect(window, contains('"FlutterDesktopViewSetHdrOutput"'));
    // 只能经函数指针调用；直接调用会让原版 flutter_windows.dll 加载失败。
    expect(
      RegExp(r'[^"]FlutterDesktopViewSetHdrOutput\(').hasMatch(window),
      isFalse,
    );
  });

  test('runner 钉 Skia：补丁只实现 Skia 路径，3.47 起 Windows 默认 Impeller', () {
    final String main = _read('$fushi/windows/runner/main.cpp');
    expect(
      main,
      contains(
        'project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);',
      ),
    );
  });

  test('media_kit：半浮点纹理与 mpv 渲染目标同一任务内切换', () {
    final String output = _read('$mediaKit/video_output.cc');
    final int setHdr = output.indexOf('void VideoOutput::SetHdrOutput(');
    expect(setHdr, greaterThan(0));
    final String body = output.substring(setHdr);
    final int halfFloat = body.indexOf(
      'surface_manager_->SetHalfFloat(enabled)',
    );
    final int target = body.indexOf('SetRenderTarget(now_half_float');
    expect(halfFloat, greaterThan(0));
    expect(target, greaterThan(halfFloat));
    // 线性目标与半浮点编码 pass 绑定：target-trc 只在这里写。
    expect('"target-trc"'.allMatches(output).length, 1);
  });

  test('media_kit：HDR 分支不翻转 Y（与 8-bit pbuffer 同向，上下分屏片实测）', () {
    final String output = _read('$mediaKit/video_output.cc');
    // 只看参数表里的用法（注释里提到它的名字不算）。
    expect(output, isNot(contains('{MPV_RENDER_PARAM_FLIP_Y,')));
  });

  test('media_kit：format=3（RGBA16F）只在半浮点纹理时交出', () {
    final String output = _read('$mediaKit/video_output.cc');
    expect(
      output,
      contains(
        'texture->format = surface_manager_->half_float()\n'
        '                          ? static_cast<FlutterDesktopPixelFormat>(3)',
      ),
    );
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

String _fvmFlutterVersion(String fushi) {
  final Object? json = jsonDecode(_read('$fushi/.fvmrc'));
  return (json! as Map<String, Object?>)['flutter']! as String;
}

String _read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');
