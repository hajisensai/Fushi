import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：视频页两类「无法纯单测（需真实 libmpv player / 真实手势时序）」的不变式
/// 钉在源码层。
///
/// 1. **菜单重入守卫**：剧集/轨道/倍速/设置/字幕源 菜单路径必须经 `_videoSheetOpen`
///    守卫——快速重复点击不再叠开两个（用户报「点菜单/字幕点快了弹出两个」）。剧集仍走
///    `showModalBottomSheet`，倍速/音轨/字幕源/设置迁到右侧 push-aside side panel
///    （`_showVideoSidePanel`，靠单个 `_videoSidePanel` ValueNotifier 互斥），其调度入口也过
///    `_videoSheetOpen` 门控。音量改为锚定按钮的 popover（TODO-337，非 modal、toggle 语义、
///    自带 OverlayEntry 单实例），不再走 modal sheet 与 `_videoSheetOpen`。
/// 2. **音轨恢复轮询**：`_restoreAudioTrack` 必须有界轮询等待 audioTracks 填充，
///    不能单次固定延时后一锤子匹配（列表此刻常仍空 → 音轨「退出重进丢失」）。
void main() {
  final String src = File(
    'lib/src/pages/implementations/video_hibiki_page.dart',
  ).readAsStringSync();

  group('菜单重入守卫（双开）', () {
    // TODO-274 / TODO-337 重入守卫：剧集仍走 [showModalBottomSheet] + [_videoSheetOpen]
    // （开置 true、whenComplete 复位 false）；倍速 / 音轨 / 字幕源 / 设置四菜单迁到右侧
    // push-aside side panel（[_showVideoSidePanel]），靠单个 [_videoSidePanel] ValueNotifier
    // 做面板间互斥（一次只一个），且 [_showVideoSidePanel] 顶部也有 `if (_videoSheetOpen) return;`
    // 门控，不会与 modal sheet 叠开。音量改为锚定按钮的 popover（OverlayEntry 单实例 + toggle
    // 语义），不叠开靠 [_volumeOverlayEntry] != null 复用同一 entry，不再用 modal / _videoSheetOpen。
    test('所有菜单入口都有 _videoSheetOpen 重入门控（modal + side panel）', () {
      // 剧集 modal sheet + side panel 调度入口 [_showVideoSidePanel] + 字幕源入口
      // [_showSubtitleSourceMenu] 都要先过 `if (_videoSheetOpen) return;`。
      final int enter =
          RegExp(r'if \(_videoSheetOpen\) return;').allMatches(src).length;
      expect(enter, greaterThanOrEqualTo(3),
          reason: '剧集 / side panel 调度 / 字幕源入口都要 _videoSheetOpen 门控');

      // 剧集 modal sheet 仍在（音量已改 popover、其余菜单迁 side panel），且置 true。
      final int sheets =
          RegExp(r'showModalBottomSheet<void>\(').allMatches(src).length;
      expect(sheets, greaterThanOrEqualTo(1),
          reason: '剧集仍走 modal bottom sheet');
      final int setTrue =
          RegExp(r'_videoSheetOpen = true;').allMatches(src).length;
      expect(setTrue, greaterThanOrEqualTo(1),
          reason: 'modal sheet 开启前要置 _videoSheetOpen = true');

      // 音量 popover 不叠开：复用同一 OverlayEntry（已开则 markNeedsBuild、不再 insert 第二个）。
      expect(
          src.contains('OverlayEntry? _volumeOverlayEntry') &&
              src.contains('if (_volumeOverlayEntry != null)'),
          isTrue,
          reason: '音量 popover 靠 _volumeOverlayEntry 单实例复用避免叠开');

      // 4 个 side panel 菜单经统一调度，靠单 ValueNotifier 互斥（一次只一个）。
      expect(src, contains('_showVideoSidePanel(_VideoSidePanelKind.speed)'),
          reason: '倍速菜单走 side panel');
      expect(
          src.contains('_showVideoSidePanel(_VideoSidePanelKind.audioTracks)'),
          isTrue,
          reason: '音轨菜单走 side panel');
      expect(
          src.contains(
              '_showVideoSidePanel(_VideoSidePanelKind.subtitleSources)'),
          isTrue,
          reason: '字幕源菜单走 side panel');
      expect(src, contains('_showVideoSidePanel(_VideoSidePanelKind.settings)'),
          reason: '设置面板走 side panel（master-detail VideoQuickSettingsSheet）');
      expect(src, contains('VideoQuickSettingsSheet('),
          reason: '设置面板内容仍是 master-detail VideoQuickSettingsSheet');
    });

    test('modal sheet 关闭后复位 _videoSheetOpen=false（whenComplete）', () {
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
