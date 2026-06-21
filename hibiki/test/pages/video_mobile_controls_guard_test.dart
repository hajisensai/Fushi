import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_control_customization.dart';

import 'video_hibiki_page_source_corpus.dart';

/// BUG-134/147 follow-up source guard（随 TODO-274 + BUG-248B + BUG-257 刷新）。
///
/// 不变式：
/// - 移动视频 controls 顶栏直接暴露动作（字幕/音轨/截图），不依赖右上角「⋮」溢出菜单；
///   设置（tune）已移出顶栏（BUG-248B），改由可配置右侧 rail 承载（与桌面一致）。
/// - 底栏 ±10s seek 按钮按可用宽度门控（窄屏收起），桌面/移动**共用**同一个
///   [_centeredBottomControlBar]（BUG-257：底栏从两套主题各写一遍合并为单一 helper，
///   按 `desktop:` 参数择按钮组件），故进度/播放/seek 各图标只出现一次。
void main() {
  final String src = readVideoHibikiSource();

  String region(String startSig, String endSig) {
    final int start = src.indexOf(startSig);
    expect(start, greaterThanOrEqualTo(0), reason: 'missing $startSig');
    final int end = src.indexOf(endSig, start + startSig.length);
    expect(end, greaterThan(start), reason: 'missing $endSig after $startSig');
    return src.substring(start, end);
  }

  test('mobile top bar exposes actions directly without a more menu', () {
    final String body = region(
      'MaterialVideoControlsThemeData _mobileControlsTheme(',
      'List<VideoControlItem> _slotChipItems(',
    );
    final String topBar = topButtonBarRegion(body);
    expect(topBar.contains('Icons.more_vert'), isFalse,
        reason: 'mobile top bar should not depend on an overflow menu');
    expect(topBar.contains('_showMobileMoreMenu('), isFalse,
        reason: 'mobile more menu entry should stay removed');
    expect(topBar.contains('MediaQuery.of(context).size.width >= 600'), isFalse,
        reason:
            'top bar should not branch into narrow more menu / wide inline');
    expect(
        RegExp(r'_topBarSlotGroup\(\s*VideoControlSlot\.topRight')
            .hasMatch(topBar),
        isTrue,
        reason:
            'top-right actions should be rendered by the real top-bar slot group');
    final String group = region(
      'Widget _topBarSlotGroup(',
      'String get _clipExportTooltip',
    );
    expect(group.contains('Alignment.centerRight'), isTrue,
        reason: 'topRight must stay aligned as one group at the right edge');
    expect(group.contains('SingleChildScrollView('), isTrue,
        reason:
            'topRight group must scroll horizontally instead of overflowing');
    expect(group.contains('reverse: slot == VideoControlSlot.topRight'), isTrue,
        reason: 'topRight scroll origin should keep the end buttons reachable');
    expect(group.contains('MainAxisAlignment.end'), isTrue,
        reason:
            'topRight buttons should align to the group end, not spread as individual flex children');
    final List<VideoControlItem> topRightItems =
        VideoControlLayout.currentChrome.itemsIn(VideoControlSlot.topRight);
    expect(topRightItems.contains(VideoControlItem.subtitleTrack), isTrue,
        reason: 'subtitle source must default into the real top-right slot');
    expect(topRightItems.contains(VideoControlItem.audioTrack), isTrue,
        reason: 'audio track must default into the real top-right slot');
    expect(topRightItems.contains(VideoControlItem.screenshot), isTrue,
        reason: 'screenshot action must default into the real top-right slot');
    expect(src.contains('_showSubtitleSourceMenu(controller)'), isTrue);
    expect(src.contains('_showAudioTrackMenu(controller)'), isTrue);
    expect(src.contains('_saveScreenshot()'), isTrue);
    // BUG-248B：设置（tune）已从顶栏移出，改由可配置右侧 rail 承载（与桌面一致），
    // 故顶栏不再硬编码 tune 按钮；设置仍经数据化按钮模型可达。
    expect(topBar.contains('Icons.tune'), isFalse,
        reason:
            'settings moved off the top bar to the configurable right rail');
    expect(src.contains('case VideoControlButton.settings:'), isTrue,
        reason:
            'settings reachable via configurable VideoControlButton.settings');
    expect(topBar.contains('Icons.speed'), isFalse,
        reason:
            'speed remains reachable from settings without crowding top bar');
  });

  test('video bottom bar is one shared width-gated helper (BUG-257)', () {
    // BUG-257：桌面 + 移动底栏合并为单一 [_centeredBottomControlBar]（按 desktop: 参数
    // 择 Material*/MaterialDesktop* 组件），故各按钮只出现一次，不再 per-theme 重复。
    expect(
      src.contains('bool _hasRoomyVideoBottomBar() =>'),
      isTrue,
      reason: 'bottom bar width check should be shared, not mobile-only',
    );
    expect(src.contains('MediaQuery.of(context).size.width >= 600'), isTrue,
        reason: 'bottom bar should branch by available width');
    // 两套 controls 主题 bottomButtonBar 都委托同一个共享 helper。
    expect(
      'child: _centeredBottomControlBar('.allMatches(src).length,
      2,
      reason:
          'both desktop and mobile bottomButtonBar delegate the shared helper',
    );

    final String bar = region(
      'Widget _centeredBottomControlBar(',
      'Widget _seekLabelButton(',
    );
    expect(
      bar.contains('final bool roomyBottomBar = _hasRoomyVideoBottomBar();'),
      isTrue,
      reason: 'shared bottom bar should use the shared width predicate',
    );
    expect(src.contains('if (roomyBottomBar)'), isTrue,
        reason:
            'shared bottom bar should hide 10s buttons only on narrow widths');
    expect(bar.contains('PositionIndicator'), isTrue);
    expect(src.contains('PlayOrPauseButton'), isTrue);
    expect(src.contains('_buildVolumeButton(controller'), isTrue,
        reason: 'bottom bar should expose a volume adjustment entry');
    expect(src.contains('_buildFullscreenButton('), isTrue,
        reason: 'bottom bar should use Hibiki neutralized fullscreen');
    // TODO-067: ±10s 按钮用左右对称的 fast_rewind/forward（取代显歪的 replay_10/forward_10），
    // 守卫意图仍是「宽屏保留 ±N 秒 seek 按钮」。BUG-257 合并后各只出现一次。
    expect(src.contains('Icons.fast_rewind_rounded'), isTrue,
        reason: 'shared bottom bar keeps -10s when width allows');
    expect(src.contains('Icons.fast_forward_rounded'), isTrue,
        reason: 'shared bottom bar keeps +10s when width allows');
    expect(src.contains('Icons.replay_10'), isFalse,
        reason: 'lopsided replay_10 must stay replaced (TODO-067)');
    expect(src.contains('Icons.forward_10'), isFalse,
        reason: 'lopsided forward_10 must stay replaced (TODO-067)');
    expect(src.contains('Icons.skip_previous'), isTrue,
        reason: 'shared bottom bar keeps previous subtitle cue');
    expect(src.contains('Icons.skip_next'), isTrue,
        reason: 'shared bottom bar keeps next subtitle cue');
  });
}

String topButtonBarRegion(String methodBody) {
  final int top = methodBody.indexOf('topButtonBar:');
  final int bottom = methodBody.indexOf('bottomButtonBar:');
  expect(top, greaterThanOrEqualTo(0), reason: 'missing topButtonBar');
  expect(bottom, greaterThan(top), reason: 'missing bottomButtonBar');
  return methodBody.substring(top, bottom);
}
