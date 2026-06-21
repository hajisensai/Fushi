import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'video_hibiki_page_source_corpus.dart';

/// 源码守卫：视频底栏 play 钉在几何中心 + seek 按钮带可见标注（TODO-315 / BUG-257）。
///
/// 根因：旧底栏 `[时间] Spacer [seek 簇] Spacer [尾部按钮…]` 用两个 Spacer 在「时间」与
/// 「尾部按钮」间均分，尾部按钮越多 seek 簇离整条几何中心越远 → play 偏左；±10s/上下一句
/// 只有 tooltip、无可见标注，用户看不懂图标。
///
/// 修复：共享 [_centeredBottomControlBar] 用三区 Stack（左时间 / 右尾部 / Center 居中 seek
/// 簇）把 play 钉在几何中心；±10s 经 [_seekLabelButton] 带可见标注；上/下一句仍走动态
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
    src = readVideoHibikiSource();
    final int start = src.indexOf('Widget _centeredBottomControlBar(');
    expect(start, greaterThanOrEqualTo(0),
        reason: '需有共享底栏构造器 _centeredBottomControlBar');
    final int end = src.indexOf('Widget _seekLabelButton(', start);
    expect(end, greaterThan(start));
    helper = src.substring(start, end);
    final int slotStart = src.indexOf('Widget _buildBottomSlotButton(');
    expect(slotStart, greaterThanOrEqualTo(0),
        reason: '底栏 slot button builder 应承载具体 seek/cue 控件');
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

  test('play 钉几何中心：三区 Stack（左时间 / 右尾部 / Center 居中 seek 簇）', () {
    // Center 包 seek 传输簇，play 恒处整条几何中心。
    expect(helper.contains('Center(child: transport)'), isTrue,
        reason: 'seek 传输簇应绝对居中（play 钉几何中心）');
    // 左区时间 / 右区尾部按钮各自绝对对齐，不靠 Spacer 均分挤偏 play。
    expect(helper.contains('alignment: Alignment.centerLeft'), isTrue,
        reason: '时间指示器应左对齐绝对定位');
    expect(helper.contains('alignment: Alignment.centerRight'), isTrue,
        reason: '尾部按钮应右对齐绝对定位');
    // 旧的 Spacer 平铺布局已从共享 helper 移除（不再用 Spacer 定位 seek 簇）。
    expect(helper.contains('Spacer()'), isFalse,
        reason: '居中布局不再依赖 Spacer 均分（那会随尾部按钮数量挤偏 play）');
  });

  test('seek 按钮带可见标注（±10s），不只有 tooltip', () {
    // ±10s 经 _seekLabelButton 带可见 label。
    expect(helper.contains('VideoControlSlot.bottomCenter'), isTrue,
        reason: '居中 transport 应从 bottomCenter slot 渲染');
    expect(slotButtonBuilder.contains('label: t.video_bottom_seek_back_label'),
        isTrue,
        reason: '−10s 按钮应带可见标注');
    expect(
        slotButtonBuilder.contains('label: t.video_bottom_seek_forward_label'),
        isTrue,
        reason: '+10s 按钮应带可见标注');
    expect(src.contains('Widget _seekLabelButton('), isTrue,
        reason: '应有带可见标注的 seek 按钮构造器');
    // i18n label key 已存在于生成文件。
    final String gen = File('lib/i18n/strings.g.dart').readAsStringSync();
    expect(gen.contains('String get video_bottom_seek_back_label'), isTrue);
    expect(gen.contains('String get video_bottom_seek_forward_label'), isTrue);
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
    expect(src.contains('seekSeconds: _asbConfig.seekSeconds'), isTrue,
        reason: 'cue navigation 应读取动态 ASB seekSeconds');
    // 不在 skip 键上写死任何固定秒数（如 3000 / seekSeconds: 3）。
    expect(helper.contains('seekSeconds: 3'), isFalse,
        reason: '上/下一句不应写死 ±3s，必须跟随 _asbConfig.seekSeconds');
  });
}
