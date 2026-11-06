import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart' show maskComments;

/// BUG-3888 source-scan guard: on Windows, Flutter's raster thread must never
/// wait for libmpv.
///
/// media_kit's `GpuSurfaceTexture` callback runs on Flutter's raster thread in
/// the middle of `LayerTree::Paint`. Upstream called
/// `ANGLESurfaceManager::Read()` there, which blocked (`INFINITE`) on the mutex
/// that `Draw()` holds across `mpv_render_context_render` + `glFinish()` — every
/// slow libmpv frame became a Flutter raster stall (field: 300–880 ms frames in
/// 1–3 s bursts after toggling the subtitle list). The copy into the shared
/// texture now happens at the end of `Draw()` on media_kit's render thread.
/// See `third_party/media_kit_video/PATCHES.md`.
void main() {
  // Tests run with CWD = `fushi/`; vendored packages live at the workspace root.
  const String managerSourcePath =
      '../third_party/media_kit_video/windows/angle_surface_manager.cc';
  const String managerHeaderPath =
      '../third_party/media_kit_video/windows/angle_surface_manager.h';
  const String videoOutputPath =
      '../third_party/media_kit_video/windows/video_output.cc';

  /// Masks `//` and `/* */` comments so tokens that only survive in prose
  /// describing the removed code cannot satisfy or trip an assertion.
  String code(String path) => maskComments(File(path).readAsStringSync());

  /// Body of `ANGLESurfaceManager::<name>(...) { ... }` (brace-matched).
  String functionBody(String source, String name) {
    final int start = source.indexOf('ANGLESurfaceManager::$name(');
    expect(start, isNonNegative, reason: 'expected a $name definition');
    final int open = source.indexOf('{', start);
    int depth = 0;
    for (int i = open; i < source.length; i++) {
      if (source[i] == '{') depth++;
      if (source[i] == '}' && --depth == 0) {
        return source.substring(open, i + 1);
      }
    }
    fail('unbalanced braces in $name');
  }

  test('the texture callback does not take the render lock', () {
    final String output = code(videoOutputPath);
    expect(
      output.contains('surface_manager_->Read('),
      isFalse,
      reason:
          'the GpuSurfaceTexture callback runs on Flutter\'s raster thread; '
          'it must not call into ANGLESurfaceManager (BUG-3888)',
    );
    expect(code(managerHeaderPath).contains('void Read('), isFalse);
    expect(
      code(managerSourcePath).contains('ANGLESurfaceManager::Read('),
      isFalse,
    );
  });

  // A keyed mutex only synchronises devices that call AcquireSync/ReleaseSync.
  // The consumer is Flutter's ExternalTextureD3d (eglCreatePbufferFromClientBuffer
  // + eglBindTexImage once per handle); neither it nor ANGLE's D3D11 backend
  // ever acquires the mutex (ANGLE only exposes it through
  // eglQuerySurfacePointerANGLE(EGL_DXGI_KEYED_MUTEX_ANGLE)). A producer-only
  // keyed mutex therefore syncs nothing and leaves Flutter touching a
  // keyed-mutex resource without holding it, which D3D11 leaves undefined.
  // Turning it on needs an engine patch that acquires on the raster side.
  test('no producer-only keyed mutex on the shared texture', () {
    final String manager = code(managerSourcePath);
    final bool pluginUsesKeyedMutex =
        manager.contains('D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX') ||
        manager.contains('IDXGIKeyedMutex');
    if (!pluginUsesKeyedMutex) return;
    final Iterable<File> enginePatches =
        Directory('../ci/patches/flutter-engine')
            .listSync(recursive: true)
            .whereType<File>()
            .where((File f) => f.path.endsWith('.patch'));
    final bool engineAcquires = enginePatches.any((File f) {
      final String patch = f.readAsStringSync();
      return patch.contains('external_texture_d3d') &&
          patch.contains('AcquireSync');
    });
    expect(
      engineAcquires,
      isTrue,
      reason:
          'the shared texture uses a keyed mutex but no Flutter engine patch '
          'acquires it in ExternalTextureD3d (BUG-3888)',
    );
  });

  // The engine side of the keyed mutex (engine-d3d-keyed-mutex.patch): the
  // raster thread copies the shared texture into an engine-owned one under key
  // 0 and never samples it directly, never waits for the key, and only does
  // D3D11 immediate-context calls once ANGLE's device is multithread protected.
  group('engine keyed mutex patch', () {
    String enginePatch() {
      final Iterable<File> patches = Directory('../ci/patches/flutter-engine')
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => f.path.endsWith('engine-d3d-keyed-mutex.patch'));
      expect(patches, hasLength(1), reason: 'one keyed mutex engine patch');
      // Only the added lines: context lines are the stock engine.
      return patches.single
          .readAsLinesSync()
          .where((String l) => l.startsWith('+') && !l.startsWith('+++'))
          .join('\n');
    }

    test('acquires without waiting, copies, releases at once', () {
      final String patch = enginePatch();
      final int acquire = patch.indexOf('AcquireSync(0, 0)');
      final int copy = patch.indexOf(
        'CopyResource(private_texture_.Get(), shared_texture_.Get())',
      );
      final int release = patch.indexOf('ReleaseSync(0)');
      expect(acquire, isNonNegative, reason: 'raster thread must never wait');
      expect(copy, greaterThan(acquire));
      expect(release, greaterThan(copy));
      // WAIT_TIMEOUT is a success HRESULT: it must be told apart from S_OK.
      expect(patch, contains('static_cast<HRESULT>(WAIT_TIMEOUT)'));
    });

    test('GL binds the engine-owned copy, not the keyed share handle', () {
      final String patch = enginePatch();
      expect(
        patch,
        contains('reinterpret_cast<EGLClientBuffer>(private_texture_.Get())'),
      );
      expect(patch, contains('EGL_D3D_TEXTURE_ANGLE'));
      expect(patch, contains('D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX'));
    });

    test('ANGLE device is multithread protected before the copy is used', () {
      final String patch = enginePatch();
      expect(patch, contains('SetMultithreadProtected(TRUE)'));
      expect(patch, contains('protected_device()'));
    });

    test('plugin turns the keyed mutex on only behind the engine export', () {
      final String patch = enginePatch();
      const String export = 'FlutterDesktopGpuSurfaceSupportsKeyedMutex';
      expect(patch, contains('FLUTTER_EXPORT bool $export()'));
      final String manager = code(managerSourcePath);
      expect(manager, contains('GetProcAddress('));
      expect(manager, contains('"$export"'));
      // The keyed-mutex flag is only applied when the export says yes.
      final String create = functionBody(manager, 'CreateD3DTexture');
      final int gate = create.indexOf('EngineSyncsKeyedMutexTextures()');
      final int flag = create.indexOf('D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX');
      expect(gate, isNonNegative);
      expect(flag, greaterThan(gate));
      // Draw writes the shared texture under key 0.
      final String draw = functionBody(manager, 'Draw');
      final int acquire = draw.indexOf('keyed_mutex_->AcquireSync(0,');
      final int copy = draw.indexOf('CopyResource(', acquire);
      final int release = draw.indexOf('keyed_mutex_->ReleaseSync(0)');
      expect(acquire, isNonNegative);
      expect(copy, greaterThan(acquire));
      expect(release, greaterThan(copy));
    });
  });

  test('Draw publishes the frame into the shared texture after glFinish', () {
    final String draw = functionBody(code(managerSourcePath), 'Draw');
    final int finish = draw.indexOf('SwapBuffers();');
    final int copy = draw.indexOf('CopyResource(');
    final int release = draw.indexOf('ReleaseMutex(mutex_)');
    expect(finish, isNonNegative, reason: 'Draw must glFinish the frame');
    expect(copy, greaterThan(finish), reason: 'copy only a finished frame');
    expect(
      release,
      greaterThan(copy),
      reason: 'copy under the mutex (Create / SetHalfFloat swap textures)',
    );
  });
}
