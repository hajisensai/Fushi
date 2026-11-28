import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'video_fushi_page_source_corpus.dart';

/// 源码守卫：视频底栏 play 钉在几何中心 + seek 按钮带可见标注（TODO-315 / BUG-257）。
///
/// 根因：旧底栏 `[时间] Spacer [seek 簇] Spacer [尾部按钮…]` 用两个 Spacer 在「时间」与
/// 「尾部按钮」间均分，尾部按钮越多 seek 簇离整条几何中心越远 → play 偏左；±10s/上下一句
/// 只有 tooltip、无可见标注，用户看不懂图标。
///
/// 修复：共享 [_centeredBottomControlBar] 用三区布局（左时间 / 右尾部 / 居中 seek 簇，
/// BUG-2832 起由一条 VideoControlBar 排布）把 play 钉在几何中心；±10s 经 [_seekLabelButton] 带可见标注；上/下一句仍走动态
/// _asbConfig.seekSeconds 不写死 ±3s。桌面/移动共用同一 helper。
///
/// media_kit controls 跑不了 headless，故锁源码结构不变量。
void main() {
  late String src;
  late String helper;
  late String slotButtonBuilder;
  setUpAll(() {
    // TODO-590 batch11：两套 controls 主题已搬到 controls_theme.part.dart，改读合并语料
    // （主壳 + 全部 part）。`_centeredBottomControlBar(controller, desktop: true/false)`
    // 两个委托点现在分别落在桌面/移动主题（part 文件），单读主壳已找不到，故必须读合并语料。
    // `_centeredBottomControlBar` / `_buildBottomSlotButton` 等切片仍在主壳，落在语料开头不受影响。
    src = readVideoFushiSource();
    final int start = src.indexOf('Widget _centeredBottomControlBar(');
    expect(
      start,
      greaterThanOrEqualTo(0),
      reason: '需有共享底栏构造器 _centeredBottomControlBar',
    );
    final int end = src.indexOf('Widget _seekLabelButton(', start);
    expect(end, greaterThan(start));
    helper = src.substring(start, end);
    final int slotStart = src.indexOf('Widget _buildBottomSlotButton(');
    expect(
      slotStart,
      greaterThanOrEqualTo(0),
      reason: '底栏 slot button builder 应承载具体 seek/cue 控件',
    );
    final int slotEnd = src.indexOf('Widget _plainSlotButton(', slotStart);
    expect(slotEnd, greaterThan(slotStart));
    slotButtonBuilder = src.substring(slotStart, slotEnd);
  });

  test('桌面 + 移动底栏共用同一居中 helper（不再各自 Spacer 平铺 5 键）', () {
    expect(
      src.contains('_centeredBottomControlBar(controller, desktop: true)'),
      isTrue,
      reason: '桌面底栏应走共享居中 helper',
    );
    expect(
      src.contains('_centeredBottomControlBar(controller, desktop: false)'),
      isTrue,
      reason: '移动底栏应走共享居中 helper',
    );
  });

  test('play 钉几何中心：三区布局（左时间 / 右尾部 / 居中 seek 簇）', () {
    // BUG-2792：三区不再 Stack 叠放——Stack 三区互不知道对方宽度，窄了就叠画。
    // BUG-2832：三区合成一条 VideoControlBar（左 start / 传输簇 center / 右 end），
    // 放不下时退紧凑形态、再收进「⋯」，不再 FittedBox 等比缩小。几何行为由
    // test/media/video/video_control_bar_test.dart 真布局钉住。
    expect(
      helper.contains('return VideoControlBar('),
      isTrue,
      reason: '底栏三区应交 VideoControlBar 排布',
    );
    expect(
      RegExp(
        r'VideoControlSlot\.bottomCenter,[^)]*cluster: VideoBarCluster\.center',
      ).hasMatch(helper),
      isTrue,
      reason: 'seek 传输簇应作为居中簇（play 钉几何中心）',
    );
    expect(
      helper.contains('FittedBox'),
      isFalse,
      reason: '放不下时不得把按钮等比缩小（BUG-2832）',
    );
    expect(
      helper.contains('Stack('),
      isFalse,
      reason: 'Stack 叠放会在底栏变窄时让传输簇与右簇重叠（BUG-2792）',
    );
    // 旧的 Spacer 平铺布局已从共享 helper 移除（不再用 Spacer 定位 seek 簇）。
    expect(
      helper.contains('Spacer()'),
      isFalse,
      reason: '居中布局不再依赖 Spacer 均分（那会随尾部按钮数量挤偏 play）',
    );
  });

  test('seek 按钮带可见标注（±N 秒，N 跟设置走），不只有 tooltip', () {
    // 短 / 长步进经 _seekLabelButton 带可见 label，秒数取 asbplayer 配置。
    expect(
      helper.contains('VideoControlSlot.bottomCenter'),
      isTrue,
      reason: '居中 transport 应从 bottomCenter slot 渲染',
    );
    final String flat = slotButtonBuilder.replaceAll(RegExp(r'\s+'), '');
    for (final String expected in <String>[
      // 短 / 长四键共用一个分支：秒数与毫秒步长按 long 取对应配置。
      'finalintseconds=long?_asbConfig.longSeekSeconds:_asbConfig.seekSeconds;',
      'finalintstepMs=long?_asbLongSeekMs:_asbSeekMs;',
      't.video_bottom_seek_forward_seconds_label(seconds:seconds)',
      't.video_bottom_seek_back_seconds_label(seconds:seconds)',
      'onPressed:()=>_seekRelative(forward?stepMs:-stepMs)',
    ]) {
      expect(flat.contains(expected), isTrue, reason: 'missing $expected');
    }
    // 控制条短步进不再写死 ±10 秒。
    expect(slotButtonBuilder.contains('_seekRelative(-10000)'), isFalse);
    expect(slotButtonBuilder.contains('_seekRelative(10000)'), isFalse);
    expect(
      src.contains('Widget _seekLabelButton('),
      isTrue,
      reason: '应有带可见标注的 seek 按钮构造器',
    );
    // i18n label key 已存在于生成文件。
    final String gen = File('lib/i18n/strings.g.dart').readAsStringSync();
    expect(
      gen.contains('String video_bottom_seek_back_seconds_label('),
      isTrue,
    );
    expect(
      gen.contains('String video_bottom_seek_forward_seconds_label('),
      isTrue,
    );
  });

  test('上/下一句走动态 cue 导航（_asbConfig.seekSeconds），不写死 ±3s', () {
    // skip 键走 _skipCueAndPokeControls（内部用 _asbConfig.seekSeconds 对称回退/前进）。
    expect(
      slotButtonBuilder.contains('_skipCueAndPokeControls(forward: false)'),
      isTrue,
      reason: '上一句应走 _skipCueAndPokeControls（动态 seekSeconds）',
    );
    expect(
      slotButtonBuilder.contains('_skipCueAndPokeControls(forward: true)'),
      isTrue,
      reason: '下一句应走 _skipCueAndPokeControls（动态 seekSeconds）',
    );
    expect(
      src.contains('seekSeconds: _asbConfig.seekSeconds'),
      isTrue,
      reason: 'cue navigation 应读取动态 ASB seekSeconds',
    );
    // 不在 skip 键上写死任何固定秒数（如 3000 / seekSeconds: 3）。
    expect(
      helper.contains('seekSeconds: 3'),
      isFalse,
      reason: '上/下一句不应写死 ±3s，必须跟随 _asbConfig.seekSeconds',
    );
  });

  test('「⋯」溢出菜单收短 / 长步进，文案与执行都跟设置走', () {
    final int start = src.indexOf('_kVideoBottomFoldedItems =');
    expect(start, greaterThanOrEqualTo(0));
    final String folded = src.substring(start, src.indexOf('};', start));
    for (final String item in <String>[
      'VideoControlItem.seekBackward',
      'VideoControlItem.seekForward',
      'VideoControlItem.longSeekBackward',
      'VideoControlItem.longSeekForward',
    ]) {
      expect(folded.contains(item), isTrue, reason: '右下「⋯」应收 $item');
    }
    final int fStart = src.indexOf('List<VideoBarEntry> _foldedBarEntries(');
    final String foldedEntries = src.substring(
      fStart,
      src.indexOf('Widget _bottomPositionIndicator(', fStart),
    );
    expect(
      foldedEntries.contains('VideoControlItem.longSeek'),
      isFalse,
      reason: '长步进不再被排除在「⋯」之外',
    );
    // 菜单项文案取 _videoControlItemTooltip：短步进 seekSeconds、长步进 longSeekSeconds。
    final String flat = src.replaceAll(RegExp(r'\s+'), '');
    expect(
      flat.contains(
        'caseVideoControlItem.seekBackward:returnt.video_control_seek_backward_seconds(seconds:_asbConfig.seekSeconds',
      ),
      isTrue,
    );
    expect(
      flat.contains(
        'caseVideoControlItem.longSeekForward:returnt.video_control_seek_forward_seconds(seconds:_asbConfig.longSeekSeconds',
      ),
      isTrue,
    );
    expect(
      flat.contains(
        'caseVideoControlItem.seekBackward:unawaited(_seekRelative(-_asbSeekMs))',
      ),
      isTrue,
    );
    expect(
      flat.contains(
        'caseVideoControlItem.longSeekBackward:unawaited(_seekRelative(-_asbLongSeekMs))',
      ),
      isTrue,
    );
  });
}
