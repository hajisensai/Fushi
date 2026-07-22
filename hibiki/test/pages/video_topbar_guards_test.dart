import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_control_customization.dart';

import 'video_hibiki_page_source_corpus.dart';

/// video_topbar 组合并守卫（守卫审计合并产物；断言零丢弃）：
/// - 单顶栏：原 video_single_top_bar_guard_test.dart 并入；
/// - 顶栏自定义槽：原 video_topbar_customization_guard_test.dart 并入。
///
/// ── 单顶栏（BUG-102）──
/// 源码守卫：视频播放页只保留**一条**顶栏（BUG-102）。
///
/// 根因：[_buildScaffold] 既给 Scaffold 配了 `appBar: AppBar(...)`，media_kit 的
/// controls 又自带「视频内顶栏」（topButtonBar）——两条顶栏内容重复、互相挤占，对
/// 用户毫无意义。修复是删掉 Scaffold AppBar，把返回/标题/剧集导航并入视频内顶栏，
/// 与播放控制一起随鼠标/触摸显隐。
///
/// 静态扫描守卫：按平台分流的真实 controls 渲染在 widget 测试里依赖 host 平台、
/// 难稳定复现移动/全屏分支（与 [video_mobile_controls_static_test] 同理）。
///
/// ── 顶栏自定义槽（TODO-388 → TODO-421 phase 1）──
/// 可自定义学习按钮的可放置区域含「顶部」两槽（topLeft / topRight），既在数据模型
/// [VideoControlSlot.editableSlots] 暴露、在拖动编辑器里呈现，也在播放器上真正落地——
/// 所见即所得，避免编辑器给出一个渲染端不存在的「空槽」。
///
/// TODO-421 phase 1：顶部两槽不再渲染成「固定顶栏下方的浮动竖条」（用户嫌名不副实），改为
/// 把这两槽的按钮**注入固定顶栏行本身**（`topButtonBar`，经 `_topBarSlotGroup`），与
/// 返回 / 标题 / 字幕轨同处那条最顶部控制条。本守卫钉住「注入进顶栏行、且旧浮动竖条已删」。
void main() {
  group('单顶栏（BUG-102）', () {
    // TODO-590 batch11：两套 controls 主题已搬到 controls_theme.part.dart，改读合并语料
    // （主壳在前 + 全部 part 追加，端点保序）；顶栏 slot/title 的调用现落在 part 末段。
    late String src;
    setUpAll(() {
      src = readVideoHibikiSource();
    });

    test('Scaffold 不再配 AppBar（删掉外层顶栏）', () {
      expect(
        src.contains('appBar: AppBar('),
        isFalse,
        reason: '播放页不应再有 Scaffold AppBar，否则与视频内顶栏重复成两条顶栏',
      );
    });

    test('返回按钮进入视频内顶栏（桌面+移动两套主题各一）', () {
      // 删了 AppBar 自带的返回箭头后，返回必须改由视频内顶栏提供，且全屏可达。
      expect(
        RegExp(r'_topBarSlotGroup\(\s*VideoControlSlot\.topLeft')
            .allMatches(src)
            .length,
        greaterThanOrEqualTo(2),
        reason: '桌面与移动两套 controls 主题的顶栏都应渲染 topLeft slot',
      );
      expect(
          VideoControlLayout.currentChrome
              .itemsIn(VideoControlSlot.topLeft)
              .contains(VideoControlItem.back),
          isTrue,
          reason: '默认 topLeft slot 应承载返回按钮');
      expect(src.contains('case VideoControlItem.back:'), isTrue,
          reason: '返回按钮应继续接入 item dispatcher');
      expect(src.contains('_handleBackOrExit()'), isTrue,
          reason: 'topLeft 返回按钮应走视频退出 / 返回处理器');
    });

    test('标题进入视频内顶栏（响应式，全屏可刷新）', () {
      // 顶栏左侧显示书名/集名（原 AppBar 的 title 迁移到这里）。标题改用
      // ValueListenableBuilder 监听 _titleNotifier，全屏独立路由不随页面 setState 重建
      // 时也能刷新（BUG-120）；桌面 + 移动两套主题各一处。
      expect(
        '_topBarTitle()'.allMatches(src).length,
        greaterThanOrEqualTo(2),
        reason: '桌面与移动顶栏都应调用同一标题 helper（内部监听 _titleNotifier）',
      );
      expect(src.contains('valueListenable: _titleNotifier'), isTrue,
          reason: '标题 helper 内部仍应监听 _titleNotifier（BUG-120）');
    });

    test('标题用 Flexible(loose) 让宽给按钮，不用 Expanded 抢固定 1/3（TODO-642）', () {
      // 根因：_topBarTitle() 曾用 Expanded（= Flexible(FlexFit.tight)），强迫标题填满
      // 它分到的那段顶栏宽，把左右按钮组挤进窄横向滚动区（右上角按钮被裁 / 要横滑）。
      // 修复改成 Flexible(fit: FlexFit.loose)：标题只占自身需要的宽、剩余空间优先让给
      // 按钮组；标题已有 maxLines:1 + ellipsis，窄窗优雅截断。本守卫钉住该让位语义。
      final int titleStart = src.indexOf('Widget _topBarTitle()');
      expect(titleStart, greaterThanOrEqualTo(0),
          reason: '应存在 _topBarTitle() helper');
      final int titleEnd =
          src.indexOf('Widget _topBarInlineTitle(', titleStart);
      expect(titleEnd, greaterThan(titleStart),
          reason: '_topBarTitle() 方法体应正常闭合在 _topBarInlineTitle 之前');
      final String titleBody = src.substring(titleStart, titleEnd);
      expect(titleBody.contains('fit: FlexFit.loose'), isTrue,
          reason: 'TODO-642：标题须用 Flexible(fit: FlexFit.loose) 把宽让给按钮');
      expect(titleBody.contains('return Expanded('), isFalse,
          reason: 'TODO-642：标题不能再用 Expanded（FlexFit.tight 会抢固定 1/3 顶栏宽）');
      // 标题截断兜底仍在（窄窗让位后靠 ellipsis 优雅收尾）。
      final int textStart = src.indexOf('Widget _topBarTitleText(');
      expect(textStart, greaterThanOrEqualTo(0));
      final int textEnd =
          src.indexOf('Widget _buildBottomSlotButton(', textStart);
      expect(textEnd, greaterThan(textStart));
      final String textBody = src.substring(textStart, textEnd);
      expect(textBody.contains('maxLines: 1'), isTrue, reason: '标题单行');
      expect(textBody.contains('overflow: TextOverflow.ellipsis'), isTrue,
          reason: '标题溢出省略号');
    });

    test('标题使用稳定 helper，不靠右侧空槽占位维持位置（TODO-491）', () {
      expect(src.contains('Widget _topBarTitle('), isTrue,
          reason: '标题应集中到 helper，桌面/移动共用同一稳定布局');
      expect('_topBarTitle()'.allMatches(src).length, greaterThanOrEqualTo(2),
          reason: '桌面与移动顶栏都应使用同一标题 helper');

      final int groupStart = src.indexOf('Widget _topBarSlotGroup(');
      expect(groupStart, greaterThanOrEqualTo(0));
      final int groupEnd =
          src.indexOf('String get _clipExportTooltip', groupStart);
      expect(groupEnd, greaterThan(groupStart));
      final String group = src.substring(groupStart, groupEnd);
      expect(
          group.contains('if (items.isEmpty) return const SizedBox.shrink();'),
          isTrue,
          reason: '清空 topRight 时不能留下右侧空白占位挤歪标题');
    });
  });

  group('顶栏自定义槽（TODO-388 → TODO-421 phase 1）', () {
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

    test('控件拖拽编辑器呈现顶部两槽放置区', () {
      // 阶段B：拖拽编辑器从 video_quick_settings_sheet 原样抽为独立控件
      // video_control_layout_editor.dart（经 schema 投影接入面板），守卫改锁新位置。
      final String editor =
          read('lib/src/media/video/video_control_layout_editor.dart');
      expect(
          editor.contains('_buildSlotRegion(VideoControlSlot.topLeft)'), isTrue,
          reason: '编辑器应有 topLeft 放置区（TODO-388）');
      expect(editor.contains('_buildSlotRegion(VideoControlSlot.topRight)'),
          isTrue,
          reason: '编辑器应有 topRight 放置区（TODO-388）');
      // 顶部两槽有面向用户的标签（i18n）。
      expect(editor.contains('t.video_control_slot_top_left'), isTrue);
      expect(editor.contains('t.video_control_slot_top_right'), isTrue);
    });

    test('播放器把顶部两槽注入固定顶栏行本身（TODO-421 phase 1）', () {
      // TODO-590 batch11：两套 controls 主题已搬到 controls_theme.part.dart，读「合并语料」
      // （主壳 + 全部 part）；下方针对主题体 / _topBarSlotGroup→_clipExportTooltip 的切片相对
      // 顺序在合并语料里仍保持（主题对在 part、helper 与 tooltip 同在主壳）。
      final String page = readVideoHibikiSource();
      // 顶部两槽经 _topBarSlotGroup 注入 topButtonBar（不再是浮动竖条）。
      expect(
        page.contains('Widget _topBarSlotGroup('),
        isTrue,
        reason: '应有把顶部槽渲染进顶栏行的 helper（_topBarSlotGroup）',
      );
      expect(
          '_topBarSlotGroup('.allMatches(page).length, greaterThanOrEqualTo(5),
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
      // UI 巡检 PR-4：OSD 通知卡的 top 现在也从顶栏高推导
      // （`_videoButtonBarHeight + 8 * _videoUiScale`，吃界面缩放）——它是合法几何
      // 联动、不是复活的顶部浮条；本禁令收紧为旧浮条的**不吃缩放**字面形态。
      expect(page.contains('_videoButtonBarHeight + 8)'), isFalse,
          reason: '顶部浮条的「让出顶栏高度」定值内边距应随浮条一并删除');
    });

    test('顶栏右侧按钮来自 topRight slot 的同一横排，不再硬编码第二套', () {
      final String page = readVideoHibikiSource();
      final int desktopStart = page.indexOf(
          'MaterialDesktopVideoControlsThemeData _desktopControlsTheme');
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
      final String page = readVideoHibikiSource();
      final int desktopStart = page.indexOf(
          'MaterialDesktopVideoControlsThemeData _desktopControlsTheme');
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
  });
}
