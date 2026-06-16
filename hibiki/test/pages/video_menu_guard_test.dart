import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：视频页两类「无法纯单测（需真实 libmpv player / 真实手势时序）」的不变式
/// 钉在源码层。
///
/// 1. **菜单重入守卫**：剧集/轨道/设置/字幕源 菜单路径必须经 `_videoSheetOpen`
///    守卫——快速重复点击不再叠开两个（用户报「点菜单/字幕点快了弹出两个」）。剧集仍走
///    `showModalBottomSheet`，音轨/字幕源/设置迁到右侧 push-aside side panel
///    （`_showVideoSidePanel`，靠单个 `_videoSidePanel` ValueNotifier 互斥），其调度入口也过
///    `_videoSheetOpen` 门控。音量/倍速改为底栏紧凑锚点浮层（TODO-438），靠单个
///    `_videoControlPopover` ValueNotifier 互斥，不走 modal sheet / `_videoSheetOpen`，
///    也不允许 hover 改宽或布局位移。
/// 2. **音轨恢复轮询**：`_restoreAudioTrack` 必须有界轮询等待 audioTracks 填充，
///    不能单次固定延时后一锤子匹配（列表此刻常仍空 → 音轨「退出重进丢失」）。
void main() {
  final String src = File(
    'lib/src/pages/implementations/video_hibiki_page.dart',
  ).readAsStringSync();

  group('菜单重入守卫（双开）', () {
    // TODO-274 / TODO-438 重入守卫：剧集仍走 [showModalBottomSheet] + [_videoSheetOpen]
    // （开置 true、whenComplete 复位 false）；音轨 / 字幕源 / 设置三菜单迁到右侧
    // push-aside side panel（[_showVideoSidePanel]），靠单个 [_videoSidePanel] ValueNotifier
    // 做面板间互斥（一次只一个），且 [_showVideoSidePanel] 顶部也有 `if (_videoSheetOpen) return;`
    // 门控，不会与 modal sheet 叠开。音量/倍速走 [_videoControlPopover] 单一轻浮层，
    // 同时只用 [_pokeControlsVisible] 续命控制条。
    test('菜单入口分别有 modal/side-panel/popover 的互斥门控', () {
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

      // 音量 / 倍速改为同一套轻浮层：互斥、锚定、无 OverlayEntry 全局漂浮状态。
      expect(src.contains('_volumeOverlayEntry'), isFalse,
          reason: '不要恢复旧音量 OverlayEntry 残留状态；TODO-438 用 controls Stack 内锚点层');
      expect(
          src.contains(
              'ValueNotifier<_VideoControlPopoverKind?> _videoControlPopover'),
          isTrue,
          reason: '音量/倍速轻浮层应由单个 notifier 互斥，避免双开');
      expect(
          RegExp(
            r'_toggleControlPopover\(\s*_VideoControlPopoverKind\.volume',
          ).hasMatch(src),
          isTrue,
          reason: '音量按钮应打开或固定锚点轻浮层');
      expect(
          src.contains('_toggleControlPopover(_VideoControlPopoverKind.speed'),
          isTrue,
          reason: '倍速按钮应打开或固定锚点轻浮层');
      expect(src.contains('_showControlPopover(kind, pinned: true)'), isTrue,
          reason: 'click/tap 入口必须以 pinned=true 打开，hover 已打开时点击会固定浮层');
      expect(src.contains('final ValueNotifier<double> _volumeDisplay'), isTrue,
          reason: '音量浮层仍经 _volumeDisplay 同步显示');

      // 3 个 side panel 菜单经统一调度，靠单 ValueNotifier 互斥（一次只一个）。
      expect(src,
          isNot(contains('_showVideoSidePanel(_VideoSidePanelKind.speed)')),
          reason: '倍速不再走 side panel，避免打开大面板打断底栏微调');
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
