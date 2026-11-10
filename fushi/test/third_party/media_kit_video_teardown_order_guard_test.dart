import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart' show maskComments;

/// BUG-4332 source-scan guard: the Windows `VideoOutput` teardown order of the
/// vendored media_kit_video.
///
/// Field crashes (3.3.0, Windows): `libmpv-2.dll` abort (0x40000015) after the
/// SRS review page opened and closed one card video clip player per card, and
/// a `libGLESv2.dll` read AV under `media_kit_video_plugin` -> `libmpv` on the
/// video page; both preceded by steadily growing RSS.
///
/// Root cause (`third_party/media_kit_video/windows/video_output.cc`
/// `~VideoOutput`): upstream destroyed the `ANGLESurfaceManager` (libmpv's
/// EGLContext, and for the last instance the shared EGLDisplay + D3D11 device)
/// and only afterwards *posted* `mpv_render_context_free`, without waiting for
/// it and with no GL context current. The method channel already replied to
/// `VideoOutputManager.Dispose` before any of it ran, so `Player.dispose`
/// raced `mpv_terminate_destroy` (a 5 s timer) against the free — libmpv
/// aborts when its core is destroyed while a render context is alive.
///
/// Native code has no C++ test harness in this repo; this guard pins the
/// order in the source so a re-vendor cannot silently revert it.
void main() {
  // Tests run with CWD = `fushi/`; vendored packages live at the workspace root.
  const String dir = '../third_party/media_kit_video/windows';
  String code(String name) =>
      maskComments(File('$dir/$name').readAsStringSync());

  /// Body of `<qualified>(...) { ... }` (brace-matched).
  String functionBody(String source, String qualified) {
    final int start = source.indexOf('$qualified(');
    expect(start, isNonNegative, reason: 'expected a $qualified definition');
    final int open = source.indexOf('{', start);
    int depth = 0;
    for (int i = open; i < source.length; i++) {
      if (source[i] == '{') depth++;
      if (source[i] == '}' && --depth == 0) {
        return source.substring(open, i + 1);
      }
    }
    fail('unbalanced braces in $qualified');
  }

  group('~VideoOutput', () {
    late String body;
    setUp(() {
      body = functionBody(code('video_output.cc'), 'VideoOutput::~VideoOutput');
    });

    test('stops libmpv update callbacks before queueing the teardown', () {
      final int stop = body.indexOf(
        'mpv_render_context_set_update_callback(render_context_, nullptr, '
        'nullptr)',
      );
      final int post = body.indexOf('thread_pool_ref_->Post(');
      expect(stop, isNonNegative);
      expect(post, greaterThan(stop));
    });

    test('frees the render context with its GL context current, '
        'before the surface manager goes', () {
      final int unregister = body.indexOf('UnregisterTexture(');
      final int current = body.indexOf('surface_manager_->MakeCurrent(true)');
      final int free = body.indexOf('mpv_render_context_free(render_context_)');
      final int release = body.indexOf('surface_manager_->MakeCurrent(false)');
      final int reset = body.indexOf('surface_manager_.reset(');
      expect(unregister, isNonNegative);
      expect(current, greaterThan(unregister));
      expect(free, greaterThan(current));
      expect(release, greaterThan(free));
      expect(reset, greaterThan(release));
    });

    test('returns only after the teardown task ran', () {
      final int free = body.indexOf('mpv_render_context_free(');
      // The render context free is no longer a fire-and-forget post after the
      // wait: the destructor waits on the very task that frees it.
      expect(
        RegExp(r'\}\);\s*\w+\.wait\(\);\s*\}$').hasMatch(body),
        isTrue,
        reason: 'the destructor must wait for its teardown task',
      );
      expect(body.lastIndexOf('thread_pool_ref_->Post('), lessThan(free));
    });
  });

  test('queued Render / CheckAndResize bail out once teardown began', () {
    final String output = code('video_output.cc');
    for (final String name in <String>[
      'VideoOutput::Render',
      'VideoOutput::CheckAndResize',
    ]) {
      final String body = functionBody(output, name);
      expect(
        body.indexOf('if (destroyed_)'),
        allOf(isNonNegative, lessThan(body.indexOf(';'))),
        reason: '$name must check destroyed_ first',
      );
    }
    expect(
      code('video_output.h'),
      contains('std::atomic<bool> destroyed_'),
      reason: 'destroyed_ is written and read on different threads',
    );
  });

  test('Dispose replies only after the VideoOutput is destroyed', () {
    final String manager = functionBody(
      code('video_output_manager.cc'),
      'VideoOutputManager::Dispose',
    );
    final int erase = manager.indexOf('video_outputs_.erase(handle)');
    final int done = manager.indexOf('on_done();');
    expect(erase, isNonNegative);
    expect(done, greaterThan(erase));

    final String plugin = code('media_kit_video_plugin.cc');
    final int branch = plugin.indexOf('"VideoOutputManager.Dispose"');
    final int next = plugin.indexOf('"VideoOutputManager.SetSize"', branch);
    expect(branch, isNonNegative);
    expect(next, greaterThan(branch));
    final String dispose = plugin.substring(branch, next);
    expect(
      RegExp(r'\bresult->Success\(').hasMatch(dispose),
      isFalse,
      reason: 'replying up front lets mpv_terminate_destroy race the free',
    );
    final int call = dispose.indexOf('video_output_manager_->Dispose(');
    final int reply = dispose.indexOf('shared_result->Success(');
    expect(call, isNonNegative);
    expect(reply, greaterThan(call));
  });

  test('the texture bound to each pbuffer is released with it', () {
    final String manager = code('angle_surface_manager.cc');
    final String bind = functionBody(
      manager,
      'ANGLESurfaceManager::CreateAndBindEGLSurface',
    );
    final int gen = bind.indexOf('glGenTextures(1, &bound_texture_)');
    expect(gen, isNonNegative);
    // The name must live in this manager's own context, the one CleanUp
    // deletes it with.
    final int ownContext = bind.lastIndexOf(
      'eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, context_)',
      gen,
    );
    expect(
      ownContext,
      greaterThan(bind.indexOf('FAIL("eglCreatePbufferFromClientBuffer")')),
      reason: 'glGenTextures must run with context_ current',
    );
    final String cleanUp = functionBody(
      manager,
      'ANGLESurfaceManager::CleanUp',
    );
    final int releaseTex = cleanUp.indexOf('eglReleaseTexImage(');
    final int deleteTex = cleanUp.indexOf(
      'glDeleteTextures(1, &bound_texture_)',
    );
    final int notCurrent = cleanUp.indexOf('MakeCurrent(false)');
    final int destroyContext = cleanUp.indexOf('eglDestroyContext(');
    expect(releaseTex, isNonNegative);
    expect(deleteTex, greaterThan(releaseTex));
    expect(notCurrent, greaterThan(deleteTex));
    expect(
      destroyContext,
      greaterThan(notCurrent),
      reason: 'a context still current is only marked for deletion',
    );
  });
}
