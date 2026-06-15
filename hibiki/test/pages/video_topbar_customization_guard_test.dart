import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫（TODO-388）：可自定义学习按钮的可放置区域扩展到「顶部」两槽（topLeft /
/// topRight），既在数据模型 [VideoControlSlot.editableSlots] 暴露、在拖动编辑器里呈现，
/// 也在播放器上经同一学习按钮渲染路径（顶部浮动 rail）落地——所见即所得，避免编辑器给出
/// 一个渲染端不存在的「空槽」。
void main() {
  String read(String rel) => File(rel).readAsStringSync();

  test('数据模型把 topLeft / topRight 纳入 editableSlots', () {
    final String model =
        read('lib/src/media/video/video_control_customization.dart');
    final int start = model.indexOf('editableSlots = <VideoControlSlot>[');
    expect(start, greaterThan(0));
    final int end = model.indexOf('];', start);
    expect(end, greaterThan(start));
    final String block = model.substring(start, end);
    expect(block.contains('VideoControlSlot.topLeft'), isTrue,
        reason: 'editableSlots 应含 topLeft（TODO-388）');
    expect(block.contains('VideoControlSlot.topRight'), isTrue,
        reason: 'editableSlots 应含 topRight（TODO-388）');
    // topCenter 仍是固定标题 chrome 区，不开放为可拖动槽。
    expect(block.contains('VideoControlSlot.topCenter'), isFalse,
        reason: 'topCenter（标题固定 chrome）不应纳入可编辑槽');
  });

  test('拖动编辑器呈现顶部两槽放置区', () {
    final String settings =
        read('lib/src/media/video/video_quick_settings_sheet.dart');
    expect(
        settings.contains('_buildSlotRegion(VideoControlSlot.topLeft)'), isTrue,
        reason: '编辑器应有 topLeft 放置区（TODO-388）');
    expect(settings.contains('_buildSlotRegion(VideoControlSlot.topRight)'),
        isTrue,
        reason: '编辑器应有 topRight 放置区（TODO-388）');
    // 顶部两槽有面向用户的标签（i18n）。
    expect(settings.contains('t.video_control_slot_top_left'), isTrue);
    expect(settings.contains('t.video_control_slot_top_right'), isTrue);
  });

  test('播放器渲染顶部浮动 rail（topLeft / topRight 学习按钮落地）', () {
    final String page =
        read('lib/src/pages/implementations/video_hibiki_page.dart');
    expect(page.contains('VideoControlSlot.topRight'), isTrue);
    expect(page.contains('VideoControlSlot.topLeft'), isTrue);
    expect(page.contains('Alignment.topRight'), isTrue, reason: '顶部右浮条贴右上沿');
    expect(page.contains('Alignment.topLeft'), isTrue, reason: '顶部左浮条贴左上沿');
    // 顶部浮条留出固定顶栏高度避免压住返回 / 标题等 chrome。
    expect(page.contains('_videoButtonBarHeight + 8'), isTrue,
        reason: '顶部浮条应留出顶栏高度内边距（避开固定 chrome）');
  });

  test('i18n 顶部槽标签 key 完整（17 语言）', () {
    final String g = read('lib/i18n/strings.g.dart');
    expect(g.contains('video_control_slot_top_left'), isTrue);
    expect(g.contains('video_control_slot_top_right'), isTrue);
  });
}
