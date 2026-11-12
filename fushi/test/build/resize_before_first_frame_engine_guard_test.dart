import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Windows 引擎补丁 `engine-resize-before-first-frame.patch` 的源码守卫。
///
/// 原版 `FlutterWindowsView::OnWindowSizeChanged` 每次改尺寸都在平台线程上等下一帧呈现，
/// 最多 100 ms。冷启动时框架压着首帧（`deferFirstFrame`），`applyInitialPlacement` 的
/// `setBounds` / `maximize` 每次都干等满 100 ms。补丁让「从未呈现过帧」时不等。这条链路
/// 退回原样不会编译失败，只会静默变回每次启动多 100～200 ms；改坏了则可能让首帧画在旧尺寸
/// 的 surface 上，或让首帧之后的 resize 不再同步（拖动缩放时拉伸闪烁）。下面把这些点咬住。
void main() {
  final String fushi = _fushiDir();
  final String repo = Directory(fushi).parent.path;
  final String flutterVersion = _fvmFlutterVersion(fushi);
  final String patchDir = '$repo/ci/patches/flutter-engine/$flutterVersion';
  final String patchPath = '$patchDir/engine-resize-before-first-frame.patch';

  test('补丁存在、是 LF，且构建脚本在着色器缓存补丁之后打它', () {
    expect(File(patchPath).existsSync(), isTrue);
    expect(File(patchPath).readAsBytesSync().contains(13), isFalse);
    final String script = _read(
      '$repo/tool/flutter_engine/build_patched_engine.ps1',
    );
    final int cache = script.indexOf("'engine-program-binary-cache.patch'");
    final int resize = script.indexOf(
      "'engine-resize-before-first-frame.patch'",
    );
    expect(cache, greaterThan(0));
    expect(resize, greaterThan(cache));
  });

  test('只改 FlutterWindowsView 与其单测', () {
    final List<String> files = RegExp(
      r'^\+\+\+ b/(.+)$',
      multiLine: true,
    ).allMatches(_read(patchPath)).map((RegExpMatch m) => m.group(1)!).toList();
    expect(files, <String>[
      'engine/src/flutter/shell/platform/windows/flutter_windows_view.cc',
      'engine/src/flutter/shell/platform/windows/flutter_windows_view.h',
      'engine/src/flutter/shell/platform/windows/flutter_windows_view_unittests.cc',
    ]);
  });

  test('「已呈现过帧」在 resize 锁里读写，呈现时无条件置真', () {
    final String patch = _read(patchPath);
    expect(patch, contains('+  bool has_presented_frame_ = false;'));
    // 与 resize_status_ 在同一把锁、同一个临界区里取，不能和置 kResizeStarted 分开。
    final String start = _between(
      patch,
      '     resize_status_ = ResizeState::kResizeStarted;',
      '   SendWindowMetrics(width, height, binding_handler_->GetDpiScale());',
    );
    expect(start, contains('+    has_presented_frame = has_presented_frame_;'));
    // 置真在 switch 之前：kResizeStarted 分支提前 return 的帧也算呈现过。
    final int lock = patch.indexOf(
      '   std::unique_lock<std::mutex> lock(resize_mutex_);\n \n'
      '+  has_presented_frame_ = true;',
    );
    final int sw = patch.indexOf('   switch (resize_status_) {', lock);
    expect(lock, greaterThan(0));
    expect(sw, greaterThan(lock));
  });

  test('首帧前：发完 metrics 再返回，resize 保持挂起；等待循环原样保留', () {
    final String patch = _read(patchPath);
    final int metrics = patch.indexOf(
      '   SendWindowMetrics(width, height, binding_handler_->GetDpiScale());\n'
      ' \n'
      '+  if (!has_presented_frame) {',
    );
    expect(metrics, greaterThan(0), reason: 'metrics 必须先发出去，首帧才按新尺寸出');
    final String early = _between(
      patch,
      '+  if (!has_presented_frame) {',
      '   std::chrono::time_point<std::chrono::steady_clock> start_time =',
    );
    expect(early, contains('+    return false;'));
    // 不许在这条路径上复位状态：挂起的 kResizeStarted 才让旧尺寸帧被拒、首帧重建 surface。
    expect(early, isNot(contains('ResizeState::kDone')));
    expect(early, isNot(contains('ResizeRenderSurface')));
    // 补丁不碰超时常量与等待循环（呈现过帧之后行为与原版一致）。
    expect(patch, isNot(contains('kWindowResizeTimeout{')));
    expect(patch, isNot(contains('PollOnce')));
  });

  test('单测覆盖首帧前不阻塞且按新尺寸落 surface、首帧后仍同步', () {
    final String patch = _read(patchPath);
    expect(
      patch,
      contains(
        '+TEST(FlutterWindowsViewTest, WindowResizeBeforeFirstFrameDoesNotBlock) {',
      ),
    );
    expect(
      patch,
      contains(
        '+TEST(FlutterWindowsViewTest, WindowResizeAfterFirstFrameStillBlocks) {',
      ),
    );
    expect(
      patch,
      contains('+  EXPECT_FALSE(view->OnFrameGenerated(400, 200));'),
    );
    expect(
      patch,
      contains('+  EXPECT_EQ(view->surface(), resized_surface_ptr);'),
    );
    expect(
      patch,
      contains('+  EXPECT_GE(elapsed, std::chrono::milliseconds(100));'),
    );
  });
}

String _between(String text, String start, String end) {
  final int from = text.indexOf(start);
  expect(from, greaterThanOrEqualTo(0), reason: start);
  final int to = text.indexOf(end, from);
  expect(to, greaterThan(from), reason: end);
  return text.substring(from, to);
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
