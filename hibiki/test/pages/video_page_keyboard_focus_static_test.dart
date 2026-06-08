import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：确保视频页修复「导入着色器后空格失灵」的接线不被回退。
///
/// 根因：media_kit 的 `Video` 自带 FocusNode + 内置快捷键（空格=播放/暂停）。覆盖层
/// （对话框 / bottom sheet / FilePicker 系统对话框）会夺走窗口键盘焦点，关闭后 Flutter
/// 不会自动把焦点还给 Video → 空格失灵。修复是把焦点节点提到 State 持有、传给 Video，
/// 并在每个覆盖层关闭后 [requestFocus]（_refocusVideo）。本测试静态扫描这些不变式，
/// 因为焦点行为在 widget 测试里难稳定复现（依赖真实焦点遍历 / 平台文件选择器）。
void main() {
  final File page =
      File('lib/src/pages/implementations/video_hibiki_page.dart');

  late String src;
  setUpAll(() {
    expect(page.existsSync(), isTrue, reason: '视频页源文件应存在');
    src = page.readAsStringSync();
  });

  test('State 持有专用 FocusNode 并在 dispose 释放', () {
    expect(src, contains('FocusNode _videoFocusNode'),
        reason: '应有 State 级别的 _videoFocusNode 供覆盖层关闭后归还焦点');
    expect(src, contains('_videoFocusNode.dispose()'),
        reason: 'FocusNode 必须在 dispose 释放，避免泄漏');
  });

  test('Video widget 接上 _videoFocusNode（替换内置匿名节点）', () {
    expect(src, contains('focusNode: _videoFocusNode'),
        reason: 'Video 必须用本页持有的 FocusNode，否则覆盖层关闭后无法归还焦点');
  });

  test('存在 _refocusVideo 归还焦点的 helper', () {
    expect(src, contains('void _refocusVideo()'),
        reason: '应有统一的 _refocusVideo() 在覆盖层关闭后归还焦点');
    expect(src, contains('_videoFocusNode.requestFocus()'),
        reason: '_refocusVideo 必须 requestFocus');
  });

  test('每个会夺焦的覆盖层关闭后都归还焦点', () {
    // bottom sheet 们的 whenComplete 现为闭包 `() { _videoSheetOpen = false;
    // _refocusVideo(); }`（兼做重入守卫复位，见 video_menu_guard_test）；
    // showDialog/picker 仍直接调用。统计所有 _refocusVideo() 调用点覆盖 5 个 sheet +
    // 着色器/Jimaku 对话框。
    final int refocusCalls = '_refocusVideo();'.allMatches(src).length;
    expect(refocusCalls, greaterThanOrEqualTo(6),
        reason: '所有夺焦覆盖层（5 个 sheet + 着色器/Jimaku 对话框）关闭后都应 _refocusVideo()');
    // sheet 关闭回调里必须同时复位重入守卫，否则守卫卡死再也开不了菜单。
    final int guardReset = '_videoSheetOpen = false;'.allMatches(src).length;
    expect(guardReset, greaterThanOrEqualTo(5),
        reason: '每个 sheet 的 whenComplete 必须复位 _videoSheetOpen');
  });
}
