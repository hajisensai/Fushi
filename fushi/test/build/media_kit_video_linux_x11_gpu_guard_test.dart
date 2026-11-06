import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-4120: under X11 (Steam Game Mode / gamescope Xwayland) video fell back to
/// mpv's software renderer.
///
/// Flutter's Linux embedder renders through EGL on X11 too, but there it
/// composites by CPU copy and never leaves an EGL context current on the GTK
/// thread. The vendored media_kit_video only took the GPU path when an EGL
/// context was current, so X11 always printed "EGL display or context is
/// invalid" and used `MPV_RENDER_API_TYPE_SW`.
///
/// This guard pins the parts of the fix that a C++ edit could silently undo:
/// - Flutter's EGLDisplay is resolved from the GDK display when nothing is
///   current, for both X11 and Wayland;
/// - the GPU path is gated on that display, not on a current context;
/// - mpv's isolated context is released instead of being left bound to the
///   GTK thread;
/// - Flutter texture names freed with no context current are deleted later on
///   the raster thread, not leaked.
///
/// Real-device check: Steam Deck Game Mode prints
/// "H/W rendering with isolated EGL context" in the console log.
void main() {
  const String dir = '../third_party/media_kit_video/linux';
  final String videoOutput = File('$dir/video_output.cc').readAsStringSync();
  final String textureGl = File('$dir/texture_gl.cc').readAsStringSync();

  test('Flutter EGL display resolved from GDK on X11 and Wayland', () {
    expect(videoOutput, contains('video_output_resolve_flutter_egl_display'));
    expect(videoOutput, contains('EGL_PLATFORM_X11_EXT'));
    expect(videoOutput, contains('EGL_PLATFORM_WAYLAND_EXT'));
    expect(
      videoOutput,
      contains('gdk_x11_display_get_xdisplay(display), NULL'),
    );
  });

  test('GPU path is not gated on a current EGL context', () {
    expect(
      videoOutput,
      isNot(
        contains(
          'if (flutter_display != EGL_NO_DISPLAY && '
          'flutter_context != EGL_NO_CONTEXT) {',
        ),
      ),
    );
    expect(videoOutput, contains('if (self->egl_display != EGL_NO_DISPLAY) {'));
    expect(videoOutput, contains('video_output_choose_flutter_like_config'));
  });

  test('GDK GLX context released around mpv EGL work (glvnd)', () {
    // libglvnd rejects eglMakeCurrent with EGL_BAD_ACCESS while a GLX context
    // owns the thread; seen on the Deck as "Failed to make isolated EGL
    // context current. Error: 0x3002".
    expect(videoOutput, contains('glXMakeContextCurrent(saved.display, None'));
    expect(
      'video_output_release_glx_context();'.allMatches(videoOutput).length,
      2,
    );
    expect(
      'video_output_restore_glx_context(&saved_glx);'
          .allMatches(videoOutput)
          .length,
      2,
    );
  });

  test('mpv context released when no context was current before', () {
    expect(
      videoOutput,
      contains(
        'eglMakeCurrent(own_display, EGL_NO_SURFACE, EGL_NO_SURFACE,\n'
        '                   EGL_NO_CONTEXT);',
      ),
    );
    // No raw restore that is a no-op when the previous display was
    // EGL_NO_DISPLAY.
    expect(
      videoOutput,
      isNot(contains('eglMakeCurrent(flutter_display, flutter_draw_surface')),
    );
    expect(textureGl, contains('video_output_restore_egl_context('));
  });

  test('Flutter texture names freed off-context are deleted on raster', () {
    expect(textureGl, contains('texture_gl_orphan_flutter_name(self->name)'));
    expect(
      RegExp(
        r'texture_gl_populate_texture\([^{]*\{[^}]*'
        r'texture_gl_delete_orphaned_flutter_names\(\);',
      ).hasMatch(textureGl),
      isTrue,
    );
  });
}
