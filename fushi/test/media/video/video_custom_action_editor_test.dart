import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/video_control_customization.dart';
import 'package:fushi/src/media/video/video_control_layout_editor.dart';
import 'package:fushi/src/media/video/video_custom_action_bindings.dart';
import 'package:fushi/src/media/video/video_custom_action_picker.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_labels.dart';

/// 「快捷键 N」chip 的配置入口行为测试。
///
/// 守卫测试只能核对「表和表对得上」，测不出这里真正易碎的一点：chip 同时挂着
/// [Draggable]（改位置）和 `onTap`（改绑动作），两者在手势竞技场里竞争。tap 一旦被
/// 拖拽识别器吃掉，这个功能就**完全没有配置入口**——而静态分析、类型检查、一致性
/// 守卫全都照样绿。所以这条链路必须用真手势跑一遍。
/// 测试视口。默认的 800×600 装不下这个编辑器（九宫格 + 调色板 + 隐藏托盘），
/// 溢出后 chip 会被挤出可点区域，测出来的「点不到」是测试壳的假象而不是产品问题。
/// 用一块够大的画布，让手势测的是真实的手势竞争，不是布局裁剪。
void _useLargeSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Future<void> _pumpEditor(
  WidgetTester tester, {
  required VideoCustomActionBindings bindings,
  required Future<void> Function(VideoCustomActionBindings) onChanged,
  VideoControlLayout? layout,
}) async {
  _useLargeSurface(tester);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(
        body: SizedBox.expand(
          child: VideoControlLayoutEditor(
            layout: layout ?? VideoControlLayout.defaults,
            onLayoutChanged: (VideoControlLayout _) async {},
            isTouchControls: true,
            customActionBindings: bindings,
            onCustomActionBindingsChanged: onChanged,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// 按拖拽载荷精确定位「快捷键 N」chip。
///
/// 刻意**不按 tooltip 文字找**：控制条里本来就有同名标签（`VideoControlItem.nextCue`
/// 的标签就是「下一句字幕」，与绑了该动作的槽位 chip 一模一样），按文字找会静默命中
/// 那个传输按钮，点下去什么都不弹——测出来的红是 finder 的错，不是产品的错。载荷里的
/// [VideoControlItem] 才是唯一无歧义的身份。
Finder _slotChip(VideoControlItem item) => find
    .byWidgetPredicate(
      (Widget w) =>
          w is Draggable<VideoControlDragData> && w.data?.item == item,
    )
    .first;

void main() {
  testWidgets('点未绑定的「快捷键1」chip 能弹出动作选择器并改绑', (WidgetTester tester) async {
    VideoCustomActionBindings? saved;
    await _pumpEditor(
      tester,
      bindings: VideoCustomActionBindings.empty,
      onChanged: (VideoCustomActionBindings b) async => saved = b,
    );

    // 未绑定的槽位以「快捷键 N」这个槽位名出现（播放器上同样显示，点它就地弹本
    // 选择器；编辑器里则是摆位置顺手配）。
    final String slotLabel = t.video_control_custom_action(index: 1);
    expect(find.byTooltip(slotLabel), findsWidgets);

    // 关键：tap 必须能穿过 Draggable 打开选择器。
    await tester.tap(_slotChip(VideoControlItem.customAction1));
    await tester.pumpAndSettle();
    expect(
      find.text(ShortcutAction.videoNextSubtitle.label),
      findsOneWidget,
      reason: '动作选择器没弹出来（tap 很可能被 Draggable 吃掉了）',
    );

    await tester
        .ensureVisible(find.text(ShortcutAction.videoNextSubtitle.label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(ShortcutAction.videoNextSubtitle.label));
    await tester.pumpAndSettle();

    expect(saved, isNotNull, reason: '选完动作没有回调落盘');
    expect(saved!.actionAt(0), ShortcutAction.videoNextSubtitle);
    // 只改动了被点的那个槽位，其余保持未绑定。
    expect(saved!.actionAt(1), isNull);
    expect(saved!.actionAt(2), isNull);
    expect(saved!.actionAt(3), isNull);
  });

  testWidgets('已绑定的 chip 显示动作名，可改绑成「不绑定」清空槽位', (WidgetTester tester) async {
    VideoCustomActionBindings? saved;
    final VideoCustomActionBindings bound = VideoCustomActionBindings.empty
        .withAction(0, ShortcutAction.videoNextSubtitle);
    await _pumpEditor(
      tester,
      bindings: bound,
      onChanged: (VideoCustomActionBindings b) async => saved = b,
    );

    // 绑定后 chip 以动作名示人（用户拍板：按钮显示动作，不用记住 1 是什么）。
    final String actionLabel = ShortcutAction.videoNextSubtitle.label;
    expect(find.byTooltip(actionLabel), findsWidgets);

    await tester.tap(_slotChip(VideoControlItem.customAction1));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(t.video_control_custom_action_none));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.video_control_custom_action_none));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.actionAt(0), isNull, reason: '「不绑定」必须真的清空槽位');
  });

  testWidgets('取消选择器（点外部）保持原绑定不变', (WidgetTester tester) async {
    // 这条钉的是 [VideoCustomActionPick] 存在的理由：取消与「显式选不绑定」都是 null
    // 动作，若不区分，点外部关弹窗会把用户配好的按钮清掉。
    bool called = false;
    final VideoCustomActionBindings bound = VideoCustomActionBindings.empty
        .withAction(0, ShortcutAction.videoNextSubtitle);
    await _pumpEditor(
      tester,
      bindings: bound,
      onChanged: (VideoCustomActionBindings _) async => called = true,
    );

    await tester.tap(_slotChip(VideoControlItem.customAction1));
    await tester.pumpAndSettle();
    expect(find.text(t.video_control_custom_action_none), findsOneWidget);

    // 点弹窗外部（barrier）关闭。
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(
      called,
      isFalse,
      reason: '取消不该触发改绑回调（否则点外部就把绑定清空了）',
    );
  });

  testWidgets('共享选择器：取消返回 null，选动作/选「不绑定」返回可区分的结果',
      (WidgetTester tester) async {
    // 播放器控制条点空按钮走的就是这个函数（与编辑器同一个）。它是「未绑定也显示」
    // 得以成立的前提——空按钮不是死按钮，而是就地的配置入口，所以这里单独钉住它的
    // 三种返回，尤其是「取消 ≠ 不绑定」（两者都不带动作，混淆就会让点外部清空绑定）。
    VideoCustomActionPick? result;
    bool opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () async {
                opened = true;
                result = await showVideoCustomActionPicker(
                  context: context,
                  slotNumber: 1,
                  current: null,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    // ① 取消（点外部）→ null
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(opened, isTrue);
    expect(find.text(t.video_control_custom_action_none), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(result, isNull, reason: '取消必须返回 null，不能被当成「不绑定」');

    // ② 选一个动作 → 带动作的结果
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester
        .ensureVisible(find.text(ShortcutAction.videoNextSubtitle.label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(ShortcutAction.videoNextSubtitle.label));
    await tester.pumpAndSettle();
    expect(result?.action, ShortcutAction.videoNextSubtitle);

    // ③ 选「不绑定」→ 非 null 但 action 为 null（与取消区分开）
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.video_control_custom_action_none));
    await tester.pumpAndSettle();
    expect(result, isNotNull, reason: '「不绑定」是一次显式选择，不是取消');
    expect(result!.action, isNull);
  });

  testWidgets('选择器列出全部可绑动作，且不含未接线的动作', (WidgetTester tester) async {
    await _pumpEditor(
      tester,
      bindings: VideoCustomActionBindings.empty,
      onChanged: (VideoCustomActionBindings _) async {},
    );

    await tester.tap(_slotChip(VideoControlItem.customAction1));
    await tester.pumpAndSettle();

    // 抽查几个必须在列表里的动作（含本轮新加按钮的那对对齐动作）。
    for (final ShortcutAction action in <ShortcutAction>[
      ShortcutAction.videoTogglePlayPause,
      ShortcutAction.videoNextSubtitle,
      ShortcutAction.videoToggleSubtitleBlur,
      ShortcutAction.videoAlignSubtitleToNext,
    ]) {
      expect(
        find.text(action.label),
        findsWidgets,
        reason: '${action.key} 应出现在可绑动作列表里',
      );
    }

    // 阅读器动作永远绑不到视频按钮上（视频页没有它的执行体）。
    expect(
      find.text(ShortcutAction.readerPageForward.label),
      findsNothing,
      reason: '非视频动作不该出现在列表里（选了会没反应）',
    );
  });
}
