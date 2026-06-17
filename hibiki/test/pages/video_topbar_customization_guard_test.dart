import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫（TODO-388 → TODO-421 phase 1）：可自定义学习按钮的可放置区域含「顶部」两槽
/// （topLeft / topRight），既在数据模型 [VideoControlSlot.editableSlots] 暴露、在拖动编辑器
/// 里呈现，也在播放器上真正落地——所见即所得，避免编辑器给出一个渲染端不存在的「空槽」。
///
/// TODO-421 phase 1：顶部两槽不再渲染成「固定顶栏下方的浮动竖条」（用户嫌名不副实），改为
/// 把这两槽的按钮**注入固定顶栏行本身**（`topButtonBar`，经 `_topBarSlotGroup`），与
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

  test('quick settings 编辑器呈现顶部两槽放置区', () {
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

  test('播放器把顶部两槽注入固定顶栏行本身（TODO-421 phase 1）', () {
    final String page =
        read('lib/src/pages/implementations/video_hibiki_page.dart');
    // 顶部两槽经 _topBarSlotGroup 注入 topButtonBar（不再是浮动竖条）。
    expect(
      page.contains('Widget _topBarSlotGroup('),
      isTrue,
      reason: '应有把顶部槽渲染进顶栏行的 helper（_topBarSlotGroup）',
    );
    expect('_topBarSlotGroup('.allMatches(page).length, greaterThanOrEqualTo(5),
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
      RegExp(r'_topBarSlotGroup\(\s*VideoControlSlot\.topRight')
          .hasMatch(desktopTheme),
      isTrue,
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

  test('topRight 作为整体右侧按钮组对齐，不让按钮逐个参与顶栏 flex 分配', () {
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
      RegExp(r'_topBarSlotGroup\(\s*VideoControlSlot\.topRight')
          .hasMatch(desktopTheme),
      isTrue,
      reason: 'topRight 必须作为一个右侧按钮组注入顶栏',
    );
    expect(
      desktopTheme,
      isNot(contains('..._topBarSlotButtons(VideoControlSlot.topRight')),
      reason: '不能再把 topRight 的每个按钮摊成顶栏 Row 的独立 flex child',
    );

    final int groupStart = page.indexOf('Widget _topBarSlotGroup(');
    expect(groupStart, greaterThanOrEqualTo(0));
    final int groupEnd =
        page.indexOf('String get _clipExportTooltip', groupStart);
    expect(groupEnd, greaterThan(groupStart));
    final String groupHelper = page.substring(groupStart, groupEnd);

    expect(
      groupHelper,
      contains('alignment: slot == VideoControlSlot.topRight'),
      reason: '同一个 slot group 内部应按 topRight 选择右对齐',
    );
    expect(
      groupHelper,
      contains('MainAxisAlignment.end'),
      reason: 'topRight 组内按钮应靠右聚拢',
    );
    expect(
      groupHelper,
      isNot(contains(
          'for (final VideoControlItem item in _slotChipItems(slot))\n        Flexible(')),
      reason: '按钮不能逐个 Flexible，否则会被整条 Row 分散到中间',
    );
  });

  test('i18n 顶部槽标签 key 完整（17 语言）', () {
    final String g = read('lib/i18n/strings.g.dart');
    expect(g.contains('video_control_slot_top_left'), isTrue);
    expect(g.contains('video_control_slot_top_right'), isTrue);
  });
}
