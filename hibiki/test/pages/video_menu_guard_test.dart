import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：视频页两类「无法纯单测（需真实 libmpv player / 真实手势时序）」的不变式
/// 钉在源码层。
///
/// 1. **菜单重入守卫**：剧集/轨道/倍速/设置/字幕源 5 个菜单路径必须经
///    `_videoSheetOpen` 守卫——快速重复点击不再叠开两个（用户报「点菜单/字幕点快了
///    弹出两个」）。其中 4 个走 `showModalBottomSheet`，设置走 master-detail
///    `VideoQuickSettingsSheet`（桌面 dialog / 移动 modal sheet）；每个开启前置
///    `_videoSheetOpen=true`，关闭（whenComplete）复位为 false。
/// 2. **音轨恢复轮询**：`_restoreAudioTrack` 必须有界轮询等待 audioTracks 填充，
///    不能单次固定延时后一锤子匹配（列表此刻常仍空 → 音轨「退出重进丢失」）。
void main() {
  final String src = File(
    'lib/src/pages/implementations/video_hibiki_page.dart',
  ).readAsStringSync();

  group('菜单重入守卫（双开）', () {
    test('5 个菜单路径都有对应的 _videoSheetOpen 守卫', () {
      // 4 个底部 sheet（剧集/轨道/倍速/字幕源）+ 1 个设置面板（master-detail
      // VideoQuickSettingsSheet，走 dialog 不再是 bottom sheet）= 5 个菜单路径。
      final int sheets =
          RegExp(r'showModalBottomSheet<void>\(').allMatches(src).length;
      expect(sheets, greaterThanOrEqualTo(4), reason: '应有 4 个底部 sheet');
      expect(src, contains('VideoQuickSettingsSheet('),
          reason: '设置面板走 master-detail VideoQuickSettingsSheet（第 5 个菜单路径）');
      const int menuPaths = 5;
      // 进入守卫：开菜单前置真。
      final int enter =
          RegExp(r'if \(_videoSheetOpen\) return;').allMatches(src).length;
      final int setTrue =
          RegExp(r'_videoSheetOpen = true;').allMatches(src).length;
      expect(enter, greaterThanOrEqualTo(menuPaths),
          reason: '每个菜单开启前都要 if (_videoSheetOpen) return; 守卫');
      expect(setTrue, greaterThanOrEqualTo(menuPaths),
          reason: '每个菜单开启前都要置 _videoSheetOpen = true');
    });

    test('sheet 关闭后复位 _videoSheetOpen=false（whenComplete）', () {
      expect(src, contains('_videoSheetOpen = false;'),
          reason: 'whenComplete / 异步早返回必须复位守卫，否则守卫卡死再也开不了菜单');
      // whenComplete 不再裸调 _refocusVideo（已并入复位回调）。
      expect(src.contains('.whenComplete(_refocusVideo)'), isFalse,
          reason: 'whenComplete 应改为同时复位守卫 + refocus 的回调');
    });
  });

  group('音轨恢复轮询（退出重进保留音轨）', () {
    test('_restoreAudioTrack 用有界轮询而非单次固定延时', () {
      final RegExpMatch? body = RegExp(
        r'Future<void> _restoreAudioTrack\([^)]*\) async \{(.*?)\n  \}',
        dotAll: true,
      ).firstMatch(src);
      expect(body, isNotNull, reason: '找不到 _restoreAudioTrack 方法体');
      final String b = body!.group(1)!;
      expect(b.contains('for ('), isTrue, reason: '应轮询重试等待 audioTracks 填充');
      expect(b.contains('controller.audioTracks'), isTrue);
      expect(b.contains('selectAudioTrack'), isTrue);
      // 不应是「只等一次 300ms 就匹配」的旧单次形态。
      final bool singleShot300 = RegExp(
        r'await Future<void>\.delayed\(const Duration\(milliseconds: 300\)\);\s*\n\s*if \(!mounted',
      ).hasMatch(b);
      expect(singleShot300, isFalse, reason: '旧的单次 300ms 后一锤子匹配会错过未填充的音轨列表');
    });
  });
}
