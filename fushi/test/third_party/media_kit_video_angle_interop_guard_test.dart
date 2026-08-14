import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1644 source-scan guard: the vendored `media_kit_video` Windows ANGLE
/// surface manager must keep rendering on **our** Direct3D 11 device.
///
/// Root cause: upstream `ANGLESurfaceManager` builds its `EGLDisplay` with
/// `eglGetPlatformDisplayEXT(EGL_PLATFORM_ANGLE_ANGLE, EGL_DEFAULT_DISPLAY, …)`,
/// which makes ANGLE create a hidden `ID3D11Device` of its own — separate from
/// the device media_kit created for the shared textures. libmpv's `d3d11-egl`
/// hardware decoding interop can only reach the device that is reachable
/// through the display (`EGL_DEVICE_EXT` → `EGL_D3D11_DEVICE_ANGLE`), i.e.
/// ANGLE's hidden one, which was never created with
/// `D3D11_CREATE_DEVICE_VIDEO_SUPPORT`. FFmpeg's `d3d11va_device_init` then
/// fails its `ID3D11VideoDevice` / `ID3D11VideoContext` QueryInterface, the
/// interop bails silently, and `hwdec=d3d11va` degrades to `d3d11va-copy`:
/// every decoded frame round-trips GPU → system memory → GPU.
///
/// Fix (mirrors mpv's own `context_angle.c`): create one process-wide device
/// with the video + BGRA flags, mark it multithread protected, and hand it to
/// ANGLE via `eglCreateDeviceANGLE` + `eglGetPlatformDisplayEXT(
/// EGL_PLATFORM_DEVICE_EXT, …)`. This test guards the *patch* — a future
/// re-vendor of media_kit_video that drops it silently reintroduces the
/// per-frame readback. See `third_party/media_kit_video/PATCHES.md`.
void main() {
  // Tests run with CWD = `fushi/`; vendored packages live at the workspace root.
  const String managerSourcePath =
      '../third_party/media_kit_video/windows/angle_surface_manager.cc';
  const String managerHeaderPath =
      '../third_party/media_kit_video/windows/angle_surface_manager.h';
  const String videoOutputPath =
      '../third_party/media_kit_video/windows/video_output.cc';

  /// Strips `//` line comments and `/* */` block comments so a guarded token
  /// that only survives inside prose (a comment describing the removed code)
  /// can never satisfy an assertion.
  String stripComments(String source) {
    final StringBuffer out = StringBuffer();
    bool inLine = false;
    bool inBlock = false;
    for (int i = 0; i < source.length; i++) {
      final String c = source[i];
      final String next = i + 1 < source.length ? source[i + 1] : '';
      if (inLine) {
        if (c == '\n') {
          inLine = false;
          out.write(c);
        }
        continue;
      }
      if (inBlock) {
        if (c == '*' && next == '/') {
          inBlock = false;
          i++;
        }
        continue;
      }
      if (c == '/' && next == '/') {
        inLine = true;
        i++;
        continue;
      }
      if (c == '/' && next == '*') {
        inBlock = true;
        i++;
        continue;
      }
      out.write(c);
    }
    return out.toString();
  }

  late String managerCode;
  late String headerCode;
  late String videoOutputCode;

  setUp(() {
    managerCode = stripComments(File(managerSourcePath).readAsStringSync());
    headerCode = stripComments(File(managerHeaderPath).readAsStringSync());
    videoOutputCode = stripComments(File(videoOutputPath).readAsStringSync());
  });

  test('vendored media_kit_video override is wired in pubspec', () {
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    final RegExp override = RegExp(
      r'media_kit_video:\s*\n\s*path:\s*\.\./third_party/media_kit_video',
    );
    expect(
      override.hasMatch(pubspec),
      isTrue,
      reason: 'dependency_overrides must point media_kit_video at '
          '../third_party/media_kit_video (BUG-1644). Without it the pub.dev '
          'package returns and Windows hardware decoding drops back to '
          'd3d11va-copy.',
    );
  });

  group('BUG-1644: ANGLE is bound to media_kit\'s own Direct3D 11 device', () {
    test('the EGLDisplay is created from our device, not EGL_DEFAULT_DISPLAY',
        () {
      expect(
        managerCode.contains('eglCreateDeviceANGLE'),
        isTrue,
        reason: 'angle_surface_manager.cc must wrap its ID3D11Device with '
            'eglCreateDeviceANGLE; without it mpv can only see ANGLE\'s '
            'hidden device and d3d11va falls back to d3d11va-copy.',
      );
      expect(
        managerCode.contains('EGL_D3D11_DEVICE_ANGLE'),
        isTrue,
        reason: 'eglCreateDeviceANGLE must be called with '
            'EGL_D3D11_DEVICE_ANGLE so ANGLE adopts a D3D11 device.',
      );
      expect(
        managerCode.contains('EGL_PLATFORM_DEVICE_EXT'),
        isTrue,
        reason: 'the display must come from '
            'eglGetPlatformDisplayEXT(EGL_PLATFORM_DEVICE_EXT, ...); the '
            'EGL_PLATFORM_ANGLE_ANGLE/EGL_DEFAULT_DISPLAY form makes ANGLE '
            'create its own device.',
      );
    });

    test('the shared device asks for video + BGRA support', () {
      expect(
        managerCode.contains('D3D11_CREATE_DEVICE_VIDEO_SUPPORT'),
        isTrue,
        reason: 'FFmpeg\'s d3d11va_device_init QueryInterfaces for '
            'ID3D11VideoDevice/ID3D11VideoContext; a device created without '
            'D3D11_CREATE_DEVICE_VIDEO_SUPPORT can refuse them and the '
            'd3d11-egl interop then bails silently.',
      );
      expect(
        managerCode.contains('D3D11_CREATE_DEVICE_BGRA_SUPPORT'),
        isTrue,
        reason: 'ANGLE requires BGRA support on the device it renders with.',
      );
    });

    test('the shared device is marked multithread protected', () {
      expect(
        managerCode.contains('SetMultithreadProtected(TRUE)'),
        isTrue,
        reason: 'libmpv decodes on its own threads while Flutter\'s raster '
            'thread reads the shared texture; the device must be thread safe '
            'before it is handed to ANGLE.',
      );
    });

    test('the legacy EGL_DEFAULT_DISPLAY chain survives as a fallback', () {
      for (final String attributes in <String>[
        'kD3D11DisplayAttributes',
        'kD3D11_9_3DisplayAttributes',
        'kD3D9DisplayAttributes',
        'kWrapDisplayAttributes',
      ]) {
        expect(
          managerCode.contains(attributes),
          isTrue,
          reason: 'the upstream $attributes fallback must stay reachable so '
              'machines that cannot take the device-backed display keep '
              'working exactly like pub.dev (BUG-1644 must not regress '
              'playback on old drivers).',
        );
      }
    });

    test('the process-wide device is not released per instance', () {
      final int cleanUp = managerCode.indexOf('void ANGLESurfaceManager::CleanUp');
      expect(cleanUp, isNonNegative,
          reason: 'expected a CleanUp definition in angle_surface_manager.cc');
      final int nextFunction =
          managerCode.indexOf('\nbool ANGLESurfaceManager::', cleanUp);
      final String body = managerCode.substring(
          cleanUp, nextFunction < 0 ? managerCode.length : nextFunction);
      expect(
        body.contains('d3d_11_device_->Release()'),
        isFalse,
        reason: 'the device is shared by every ANGLESurfaceManager now; '
            'releasing it per instance frees it under the surviving '
            'VideoOutputs. CleanUp must delegate to ReleaseSharedResources() '
            'on the last instance instead.',
      );
      expect(
        body.contains('ReleaseSharedResources()'),
        isTrue,
        reason: 'the last instance must tear the shared display & device down '
            'through ReleaseSharedResources().',
      );
    });

    test('the interop outcome is observable', () {
      expect(
        headerCode.contains('uses_shared_d3d11_device'),
        isTrue,
        reason: 'ANGLESurfaceManager must expose whether ANGLE actually runs '
            'on the shared device, otherwise a silent fallback to '
            'd3d11va-copy is undiagnosable in the field.',
      );
      expect(
        videoOutputCode.contains('uses_shared_d3d11_device'),
        isTrue,
        reason: 'VideoOutput must log the interop state next to '
            '"Using H/W rendering.".',
      );
    });
  });
}
