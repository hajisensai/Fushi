import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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

  /// Drops `//` line comments so tokens that only survive in prose describing
  /// the removed code cannot satisfy or trip an assertion.
  String code(String path) => File(path)
      .readAsLinesSync()
      .map((String line) {
        final int i = line.indexOf('//');
        return i < 0 ? line : line.substring(0, i);
      })
      .join('\n');

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
