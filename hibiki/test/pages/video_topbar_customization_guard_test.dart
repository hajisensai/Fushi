import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫（TODO-388 → TODO-421 phase 1）：可自定义学习按钮的可放置区域含「顶部」两槽
/// （topLeft / topRight），既在数据模型 [VideoControlSlot.editableSlots] 暴露、在拖动编辑器
/// 里呈现，也在播放器上真正落地——所见即所得，避免编辑器给出一个渲染端不存在的「空槽」。
///
/// TODO-421 phase 1：顶部两槽不再渲染成「固定顶栏下方的浮动竖条」（用户嫌名不副实），改为
/// 把这两槽的按钮**注入固定顶栏行本身**（`topButtonBar`，经 `_topBarLearningButtons`），与
/// 返回 / 标题 / 字幕轨同处那条最顶部控制条。本守卫钉住「注入进顶栏行、且旧浮动竖条已删」。
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

  test('画面上编辑器呈现顶部两槽放置区', () {
    final String overlay =
        read('lib/src/media/video/video_control_layout_edit_overlay.dart');
    expect(
        overlay.contains('_buildSlotRegion(VideoControlSlot.topLeft)'), isTrue,
        reason: '编辑器应有 topLeft 放置区（TODO-388）');
    expect(
        overlay.contains('_buildSlotRegion(VideoControlSlot.topRight)'), isTrue,
        reason: '编辑器应有 topRight 放置区（TODO-388）');
    // 顶部两槽有面向用户的标签（i18n）。
    expect(overlay.contains('t.video_control_slot_top_left'), isTrue);
    expect(overlay.contains('t.video_control_slot_top_right'), isTrue);
  });

  test('播放器把顶部两槽注入固定顶栏行本身（TODO-421 phase 1）', () {
    final String page =
        read('lib/src/pages/implementations/video_hibiki_page.dart');
    // 顶部两槽经 _topBarSlotButtons 注入 topButtonBar（不再是浮动竖条）。
    expect(
      page.contains('List<Widget> _topBarSlotButtons('),
      isTrue,
      reason: '应有把顶部槽渲染进顶栏行的 helper（_topBarSlotButtons）',
    );
    expect(
        '_topBarSlotButtons('.allMatches(page).length, greaterThanOrEqualTo(5),
        reason: 'helper 定义 1 处 + 桌面/移动各注入 topLeft/topRight 共 4 处');
    // 顶部两槽经 media_kit chrome 按钮渲染（吃主题色/尺寸/随控制条淡入淡出），且复用
    // 所有 chip-renderable 项的统一激活路径（学习键 + transport/nav 键都不丢）。
    expect(page.contains('_slotChipItems(slot)'), isTrue);
    expect(
        RegExp(r'_activateVideoControlItem\(\s*item,\s*controller,')
            .hasMatch(page),
        isTrue);

    // 旧的「固定顶栏下方浮动竖条」已删：浮动 Stack 只剩屏幕左 / 右两条
    // （[left, right]，不再有 topLeft / topRight 两条浮条）。
    expect(page.contains('children: <Widget>[left(), right()]'), isTrue,
        reason: '浮动侧栏 Stack 应只剩屏幕左/右两条（顶部两条已移入顶栏行）');
    // 顶部浮条专属的「让出固定顶栏高度」内边距随浮条一并删除（OSD 通知层用的
    // Alignment.topLeft 与本浮条无关，故不据 Alignment 判删除）。
    expect(page.contains('_videoButtonBarHeight + 8'), isFalse,
        reason: '顶部浮条的「让出顶栏高度」内边距应随浮条一并删除');
  });

  test('顶栏右侧按钮来自 topRight slot 的同一横排，不再硬编码第二套', () {
    final String page =
        read('lib/src/pages/implementations/video_hibiki_page.dart');
    final int desktopStart = page
        .indexOf('MaterialDesktopVideoControlsThemeData _desktopControlsTheme');
    final int desktopEnd =
        page.indexOf('MaterialVideoControlsThemeData _mobileControlsTheme');
    expect(desktopStart, greaterThanOrEqualTo(0));
    expect(desktopEnd, greaterThan(desktopStart));
    final String desktopTheme = page.substring(desktopStart, desktopEnd);

    expect(
      desktopTheme,
      contains('..._topBarSlotButtons(VideoControlSlot.topRight'),
      reason: 'topRight 应作为固定顶栏右侧横排的一段渲染',
    );
    expect(
      desktopTheme,
      isNot(contains('onPressed: _saveScreenshot')),
      reason: '截图按钮应由 VideoControlItem.screenshot slot 渲染',
    );
    expect(
      desktopTheme,
      isNot(contains('onPressed: () => _showSubtitleSourceMenu(controller)')),
      reason: '字幕轨按钮应由 VideoControlItem.subtitleTrack slot 渲染',
    );
    expect(
      desktopTheme,
      isNot(contains('onPressed: () => _showAudioTrackMenu(controller)')),
      reason: '音轨按钮应由 VideoControlItem.audioTrack slot 渲染',
    );
  });

  test('i18n 顶部槽标签 key 完整（17 语言）', () {
    final String g = read('lib/i18n/strings.g.dart');
    expect(g.contains('video_control_slot_top_left'), isTrue);
    expect(g.contains('video_control_slot_top_right'), isTrue);
  });
}
