import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Windows HDR 直通宿主窗（`docs/plans/2026-08-30-video-hdr-passthrough.md` §4.1）
/// 的源码守卫。Phase 0 实测（`.codex-test/hdr-passthrough/RESULTS.md`）证明只有
/// 「独立顶层窗口钉在主窗正后方 + 主窗 blur-behind 空区域」这一条路能让 Flutter
/// 的透明洞透出 HDR 画面；这些断言咬住那几个一改就静默失效的点。
void main() {
  final String runnerDir = _runnerDir();
  final String host = _read('$runnerDir/hdr_video_host_window.cpp');
  final String window = _read('$runnerDir/flutter_window.cpp');
  final String cmake = _read('$runnerDir/CMakeLists.txt');

  test('宿主窗编进 runner', () {
    expect(cmake, contains('"hdr_video_host_window.cpp"'));
  });

  test('主窗透明 = blur-behind 空区域，且 enable / disable 成对（同一函数按参数切换）', () {
    expect(host, contains('DwmEnableBlurBehindWindow(main_, &bb)'));
    expect(host, contains('CreateRectRgn(0, 0, -1, -1)'));
    expect(host, contains('bb.dwFlags = DWM_BB_ENABLE | DWM_BB_BLURREGION'));
    // Create 开、Destroy 关：两处调用都必须在。
    expect(RegExp(r'SetMainTransparency\(true\)').allMatches(host).length, 1);
    expect(RegExp(r'SetMainTransparency\(false\)').allMatches(host).length, 1);
    // Destroy 里先拆窗再还原主窗（顺序：DestroyWindow → SetMainTransparency(false)）。
    final int destroyAt = host.indexOf('DestroyWindow(hwnd_)');
    final int restoreAt = host.indexOf('SetMainTransparency(false)');
    expect(destroyAt, greaterThan(0));
    expect(restoreAt, greaterThan(destroyAt));
  });

  test('ExtendFrame 不在宿主窗路径上（Win11 只透出边框材质，Phase 0 变体 1/13）', () {
    expect(host, isNot(contains('DwmExtendFrameIntoClientArea')));
  });

  test('z-order 只以主窗为锚插到其后，绝不对主窗设 TOPMOST', () {
    expect(host, contains('SetWindowPos(hwnd_, main_,'));
    expect(host, isNot(contains('HWND_TOPMOST')));
    expect(host, isNot(contains('SetWindowPos(main_')));
  });

  test('宿主窗 = 非激活工具窗 popup，不被主窗拥有（owned 窗永远在 owner 之上）', () {
    expect(host, contains('WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW'));
    expect(host, contains('WS_POPUP'));
    expect(host, contains('return MA_NOACTIVATE'));
    final RegExp create = RegExp(r'CreateWindowExW\([^;]*?\);', dotAll: true);
    final String call = create.firstMatch(host)!.group(0)!;
    // hWndParent 参数必须是 nullptr（第 8 个实参）。
    expect(call, contains('nullptr, nullptr,'));
  });

  test('主窗消息把移动 / 缩放 / 激活 / 显隐 / 销毁同步给宿主窗，且不消费消息', () {
    final int start = window.indexOf('hdr_video_host_->IsCreated()');
    expect(start, greaterThan(0));
    final String block = window.substring(start, start + 700);
    for (final String msg in <String>[
      'WM_WINDOWPOSCHANGED',
      'WM_ACTIVATE',
      'WM_SIZE',
      'WM_MOVE',
      'WM_SHOWWINDOW',
      'WM_DESTROY',
    ]) {
      expect(block, contains('case $msg:'), reason: msg);
    }
    expect(block, contains('SyncPlacement()'));
    expect(block, contains('Destroy()'));
    expect(block, isNot(contains('return')));
    expect(window, contains('WM_DISPLAYCHANGE'));
    expect(window, contains('"onDisplayChanged"'));
  });

  test('Windows 标题栏外壳：内容区底色听 hdrHostActiveGlobal，标题行自带底色', () {
    // 真机复现：外壳的 ColoredBox(surface) 包着整个 Navigator，视频洞下面就是它；
    // 一旦让整层透明，标题行也透了（能看到别的窗口）。两条都要咬住。
    final String bar = _read(
      '${_fushiDir()}/lib/src/utils/components/fushi_windows_title_bar.dart',
    );
    expect(bar, contains('valueListenable: hdrHostActiveGlobal'));
    expect(bar, contains('hdrHost ? Colors.transparent : colors.surface'));
    final int caption = bar.indexOf('height: FushiWindowsTitleBar.height,');
    expect(caption, greaterThan(0));
    final String captionBlock = bar.substring(caption, caption + 400);
    expect(captionBlock, contains('color: colors.surface,'));
  });

  test('通道名与 Dart 侧一致', () {
    final String dart = _read(
      '${_fushiDir()}/lib/src/media/video/video_hdr_output.dart',
    );
    expect(dart, contains("'app.fushi/hdr_video_host'"));
    expect(window, contains('"app.fushi/hdr_video_host"'));
    for (final String method in <String>[
      'create',
      'setRect',
      'destroy',
      'displayInfo',
    ]) {
      expect(window, contains('method == "$method"'), reason: method);
      expect(dart, contains("'$method'"), reason: method);
    }
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
