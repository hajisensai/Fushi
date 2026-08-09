// BUG-1104 源码守卫：查词浮窗两条 WebView2 创建路径的 DPI 处理必须同源。
//
// 背景（BUG-1098 备注里记下的“放大器”）：composition 路径当年钉了
// put_RasterizationScale(dpi/96) + put_ShouldDetectMonitorScaleChanges(FALSE)，
// 而 windowed 回退路径两项都没设、全文也没有 WM_DPICHANGED 处理。于是同一个窗
// 走哪条路径出来的位图缩放真值来源不同（我们钉的 vs WebView2 自己探测的），多屏 /
// 非 100% 缩放时可以差一档。
//
// 这是 Win32 + WebView2 代码，Dart 测试跑不了，故在源码层锁死结构：
//   ① 只有一个 DPI 入口 ApplyDpiScale()，三项都在里面；
//   ② 两条创建路径 + WM_DPICHANGED 都调它，别处不得再出现这些 put_；
//   ③ WM_DPICHANGED 存在且不会把预热隐藏窗弄可见；
//   ④ BUG-693 自愈重建与 BUG-1097 状态栏关闭不得被顺手改掉。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String src =
      File('windows/runner/global_lookup_window.cpp').readAsStringSync();
  final String hdr =
      File('windows/runner/global_lookup_window.h').readAsStringSync();

  test('① DPI 只有一个入口，三项设置都在里面（BUG-1104）', () {
    expect(hdr.contains('void ApplyDpiScale();'), isTrue,
        reason: 'ApplyDpiScale 必须是声明出来的成员，而不是某条路径里的内联代码');
    final int i = src.indexOf('void GlobalLookupWindow::ApplyDpiScale() {');
    expect(i, greaterThan(0));
    final String fn = src.substring(
        i, src.indexOf('void GlobalLookupWindow::ConfigureWebView', i));
    for (final String call in <String>[
      'put_BoundsMode(COREWEBVIEW2_BOUNDS_MODE_USE_RAW_PIXELS)',
      'put_ShouldDetectMonitorScaleChanges(FALSE)',
      'put_RasterizationScale(static_cast<double>(dpi) / 96.0)',
    ]) {
      expect(fn.contains(call), isTrue, reason: '三项必须一起设：只设其中一两项就是半套状态，比不设更难查');
    }
    expect(fn.contains('GetDpiForWindow(hwnd_)'), isTrue,
        reason: '真值来源只有一个——这个 HWND 的 DPI，与窗口坐标 / 卡片矩形同源');
    expect(fn.contains('ICoreWebView2Controller3'), isTrue);
    expect(
      fn.contains('controller3 == nullptr'),
      isTrue,
      reason: '老 runtime 拿不到 Controller3 时必须整体返回，保持它自己的默认行为',
    );
  });

  test('② 三项 put_ 在全文只出现一次（两条路径都从同一个入口走）', () {
    for (final String call in <String>[
      'put_RasterizationScale',
      'put_ShouldDetectMonitorScaleChanges',
    ]) {
      expect(
        call.allMatches(src).length,
        1,
        reason: '$call 出现多于一次 = 又有路径在自己设 DPI，两条路径必然再次漂开',
      );
    }
    // composition 创建、windowed 创建、WM_DPICHANGED 三处调用。
    expect(
      'ApplyDpiScale();'.allMatches(src).length,
      3,
      reason: 'composition 创建路径、windowed 回退路径、WM_DPICHANGED 三处都必须调；'
          '少一处就回到了 BUG-1104 的不一致状态',
    );
  });

  test('③ WM_DPICHANGED 跟随新显示器，且不会弄可见预热中的隐藏窗', () {
    final int i = src.indexOf('case WM_DPICHANGED: {');
    expect(i, greaterThan(0),
        reason: '关掉了自动 monitor-scale 探测，跟随 DPI 变化就是我们自己的责任');
    final String block =
        src.substring(i, src.indexOf('case WM_ENTERSIZEMOVE:', i));
    expect(
      block.contains('reinterpret_cast<const RECT*>(lparam)'),
      isTrue,
      reason: 'lparam 是系统按新 DPI 算好的建议矩形，照单全收是官方契约',
    );
    expect(block.contains('SWP_NOZORDER | SWP_NOACTIVATE'), isTrue,
        reason: '不动 Z 序、不抢焦点');
    expect(
      block.contains('SWP_SHOWWINDOW'),
      isFalse,
      reason: '这个窗开机就预热并长期隐藏；带上 SWP_SHOWWINDOW 会让它凭空出现在桌面',
    );
    expect(block.contains('ApplyDpiScale();'), isTrue);
    expect(block.contains('ApplyRoundedRegion();'), isTrue,
        reason: 'windowed 路径的圆角直径按 DPI 算，换屏必须重算');
  });

  test('④ 既有机制不得被顺手改掉', () {
    expect(src.contains('void GlobalLookupWindow::RecoverDeadWebView'), isTrue,
        reason: 'BUG-693 的死 WebView 自愈重建');
    expect(src.contains('put_IsStatusBarEnabled(FALSE)'), isTrue,
        reason: 'BUG-1097 的 WebView2 状态栏关闭');
    // 自愈重建走 EnsureWebView -> 创建路径 -> ApplyDpiScale，重建后的实例也拿到
    // 一致的 DPI 设置；这里锁死自愈仍旧复用创建路径。
    final int i = src.indexOf('void GlobalLookupWindow::RecoverDeadWebView');
    expect(i, greaterThan(0));
    expect(
      src.substring(i, i + 2000).contains('EnsureWebView'),
      isTrue,
      reason: '自愈必须复用创建路径，否则重建出来的 WebView 又没有 DPI 设置',
    );
  });
}
