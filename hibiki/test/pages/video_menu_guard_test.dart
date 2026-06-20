import 'package:flutter_test/flutter_test.dart';

import 'video_hibiki_page_source_corpus.dart';

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
  final String src = readVideoHibikiSource();

  group('菜单重入守卫（双开）', () {
    // TODO-438 / TODO-638 互斥守卫：音轨 / 字幕源 / 设置三菜单走右侧 push-aside side
    // panel（[_showVideoSidePanel]），靠单个 [_videoSidePanel] ValueNotifier 做面板间互斥
    // （一次只一个）。剧集列表 TODO-638 改 push-aside 侧栏（[_episodeListVisible]），视频页
    // 已无任何 modal bottom sheet，旧 [_videoSheetOpen] 重入守卫随之删除。音量/倍速走
    // [_videoControlPopover] 单一轻浮层，同时只用 [_pokeControlsVisible] 续命控制条。
    test('菜单入口分别有 side-panel/push-aside/popover 的互斥门控', () {
      bool opensSidePanel(String kind) =>
          RegExp('_showVideoSidePanel\\(\\s*_VideoSidePanelKind\\.$kind')
              .hasMatch(src);

      // TODO-638：视频页已无 modal bottom sheet（剧集列表是最后一个，改 push-aside），
      // 旧 [_videoSheetOpen] 重入守卫随之删除——不应再有任何残留。
      expect(src.contains('_videoSheetOpen'), isFalse,
          reason: '剧集列表改 push-aside 后 _videoSheetOpen 重入守卫应整体删除');
      expect(
        src.contains('showModalBottomSheet<') ||
            src.contains('showModalBottomSheet('),
        isFalse,
        reason: '视频页已无任何 modal bottom sheet 调用（剧集列表改 push-aside）',
      );
      // 剧集列表改 push-aside：靠 [_episodeListVisible] ValueNotifier 与字幕列表互斥。
      expect(
        src.contains('final ValueNotifier<bool> _episodeListVisible'),
        isTrue,
        reason: '剧集列表 push-aside 可见性应由单个 _episodeListVisible notifier 管',
      );

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
          RegExp(r'_toggleControlPopover\(\s*_VideoControlPopoverKind\.speed')
              .hasMatch(src),
          isTrue,
          reason: '倍速按钮应打开或固定锚点轻浮层');
      expect(src.contains('pinned: true'), isTrue,
          reason: 'click/tap 入口必须以 pinned=true 打开，hover 已打开时点击会固定浮层');
      expect(src.contains('final ValueNotifier<double> _volumeDisplay'), isTrue,
          reason: '音量浮层仍经 _volumeDisplay 同步显示');

      // 3 个 side panel 菜单经统一调度，靠单 ValueNotifier 互斥（一次只一个）。
      // TODO-560/BUG-325：倍速入口签名扩成 `{LayerLink? popoverLink,
      // VideoControlSlot? sourceSlot}`（浮层跟随触发按钮 slot），守卫只锁方法头前缀
      // 含 popoverLink 触发源形参，对未来追加形参鲁棒。
      expect(
          src.contains('void _showSpeedMenu({LayerLink? popoverLink'), isTrue,
          reason: '倍速菜单必须能接收触发源 link');
      expect(src.contains('if (popoverLink == null)'), isTrue,
          reason: '右键菜单等无触发源入口不能打开无锚点浮层');
      expect(opensSidePanel('speed'), isTrue,
          reason: '无触发源入口应回退到可见 side panel');
      expect(opensSidePanel('audioTracks'), isTrue, reason: '音轨菜单走 side panel');
      expect(opensSidePanel('subtitleSources'), isTrue,
          reason: '字幕源菜单走 side panel');
      expect(opensSidePanel('settings'), isTrue,
          reason: '设置面板走 side panel（master-detail VideoQuickSettingsSheet）');
      expect(src, contains('VideoQuickSettingsSheet('),
          reason: '设置面板内容仍是 master-detail VideoQuickSettingsSheet');
    });

    test('剧集列表 push-aside 关闭归还焦点（_closeEpisodeList → _refocusVideo）', () {
      // TODO-638：剧集列表改 push-aside 后，关闭走单一真相源 [_closeEpisodeList]，它必须
      // 隐藏列表 + 唤回控制条 + 归还键盘焦点（与字幕列表 _closeSubtitleJumpList 同纪律）。
      final int start = src.indexOf('void _closeEpisodeList() {');
      expect(start, greaterThan(-1), reason: '应有 _closeEpisodeList 单一真相源');
      final int end = src.indexOf('\n  }', start);
      final String body = src.substring(start, end);
      expect(body.contains('_episodeListVisible.value = false'), isTrue);
      expect(body.contains('_pokeControlsVisible()'), isTrue);
      expect(body.contains('_refocusVideo()'), isTrue,
          reason: '剧集列表关闭后必须归还键盘焦点，否则空格冒泡到全局 DoNothingIntent');
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
