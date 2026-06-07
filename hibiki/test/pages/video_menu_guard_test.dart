import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：视频页两类「无法纯单测（需真实 libmpv player / 真实手势时序）」的不变式
/// 钉在源码层。
///
/// 1. **底部菜单重入守卫**：剧集/轨道/倍速/设置/字幕源 5 个底部 sheet 必须经
///    `_videoSheetOpen` 守卫——快速重复点击不再叠开两个（用户报「点菜单/字幕点快了
///    弹出两个」）。每个 `showModalBottomSheet` 前置 `_videoSheetOpen=true`，关闭
///    （whenComplete）复位为 false。
/// 2. **音轨恢复轮询**：`_restoreAudioTrack` 必须有界轮询等待 audioTracks 填充，
///    不能单次固定延时后一锤子匹配（列表此刻常仍空 → 音轨「退出重进丢失」）。
void main() {
  final String src = File(
    'lib/src/pages/implementations/video_hibiki_page.dart',
  ).readAsStringSync();

  group('底部菜单重入守卫（双开）', () {
    test('每个 showModalBottomSheet 都有对应的 _videoSheetOpen 守卫', () {
      final int sheets = RegExp(r'showModalBottomSheet<void>\(').allMatches(src).length;
      expect(sheets, greaterThanOrEqualTo(5), reason: '应有 5 个底部 sheet');
      // 进入守卫：开 sheet 前置真。
      final int enter =
          RegExp(r'if \(_videoSheetOpen\) return;').allMatches(src).length;
      final int setTrue =
          RegExp(r'_videoSheetOpen = true;').allMatches(src).length;
      expect(enter, greaterThanOrEqualTo(sheets),
          reason: '每个 sheet 开启前都要 if (_videoSheetOpen) return; 守卫');
      expect(setTrue, greaterThanOrEqualTo(sheets),
          reason: '每个 sheet 开启前都要置 _videoSheetOpen = true');
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
        r"await Future<void>\.delayed\(const Duration\(milliseconds: 300\)\);\s*\n\s*if \(!mounted",
      ).hasMatch(b);
      expect(singleShot300, isFalse,
          reason: '旧的单次 300ms 后一锤子匹配会错过未填充的音轨列表');
    });
  });
}
