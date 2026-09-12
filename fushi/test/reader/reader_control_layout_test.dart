import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/controls/control_layout.dart';
import 'package:fushi/src/reader/reader_control_layout.dart';
import 'package:fushi/src/reader/reader_control_layout_editor.dart';

void main() {
  group('ReaderControlLayout 模型', () {
    test('出厂布局 = 原硬编码顶栏：左 5 / 中书名 / 右 3；底栏为空', () {
      final ReaderControlLayout d = ReaderControlLayout.defaults;
      expect(d.itemsIn(ReaderControlSlot.topLeft), <ReaderControlItem>[
        ReaderControlItem.back,
        ReaderControlItem.modeToggle,
        ReaderControlItem.navigation,
        ReaderControlItem.gallery,
        ReaderControlItem.statistics,
      ]);
      expect(d.itemsIn(ReaderControlSlot.topCenter),
          <ReaderControlItem>[ReaderControlItem.title]);
      expect(d.itemsIn(ReaderControlSlot.topRight), <ReaderControlItem>[
        ReaderControlItem.audiobook,
        ReaderControlItem.fullscreen,
        ReaderControlItem.settings,
      ]);
      expect(d.hasBottomItems, isFalse);
      expect(d.showsTitle, isTrue);
      expect(d.core.removedItems, isEmpty);
    });

    test('encode / decode 往返；空 / 坏 JSON 回出厂', () {
      final ReaderControlLayout moved = ReaderControlLayout.fromCore(
        ReaderControlLayout.defaults.core
            .moveItem(ReaderControlItem.gallery, ReaderControlSlot.bottomRight)
            .moveItem(ReaderControlItem.fullscreen, ReaderControlSlot.hidden),
      );
      final String json = moved.encode();
      final Map<String, dynamic> raw = jsonDecode(json) as Map<String, dynamic>;
      expect(raw['version'], 1);
      expect((raw['slots'] as Map)['bottomRight'], <String>['gallery']);
      expect(raw['removed'], <String>['fullscreen']);
      final ReaderControlLayout back = ReaderControlLayout.decode(json);
      expect(back, moved);
      expect(back.hasBottomItems, isTrue);
      expect(back.core.removedItems, contains(ReaderControlItem.fullscreen));

      expect(ReaderControlLayout.decode(''), ReaderControlLayout.defaults);
      expect(
          ReaderControlLayout.decode('not json'), ReaderControlLayout.defaults);
      expect(ReaderControlLayout.decode('{"version":1}'),
          ReaderControlLayout.defaults);
      expect(ReaderControlLayout.decode('{"version":1,"slots":{}}'),
          ReaderControlLayout.defaults,
          reason: '一个可见按钮都没有 → 出厂');
    });

    test('返回 / 设置是必需项：移到 hidden 被驳回并回落原槽', () {
      final ControlLayout<ReaderControlSlot, ReaderControlItem> core =
          ReaderControlLayout.defaults.core;
      expect(ReaderControlItem.back.canMoveToSlot(ReaderControlSlot.hidden),
          isFalse);
      expect(ReaderControlItem.settings.canMoveToSlot(ReaderControlSlot.hidden),
          isFalse);
      final ControlLayout<ReaderControlSlot, ReaderControlItem> after =
          core.moveItem(ReaderControlItem.back, ReaderControlSlot.hidden);
      expect(after.slotOf(ReaderControlItem.back),
          isNot(ReaderControlSlot.hidden));
      // 直接在持久化里把它写进 removed 也不生效。
      final ReaderControlLayout decoded = ReaderControlLayout.decode(
        '{"version":1,"slots":{"topRight":["settings"]},"removed":["back"]}',
      );
      expect(decoded.core.slotOf(ReaderControlItem.back),
          isNot(ReaderControlSlot.hidden));
    });

    test('顶栏中间只收书名；书名只去顶栏中间（后置归一化兜底）', () {
      expect(ReaderControlItem.title.canMoveToSlot(ReaderControlSlot.topCenter),
          isTrue);
      expect(ReaderControlItem.title.canMoveToSlot(ReaderControlSlot.topLeft),
          isFalse);
      expect(ReaderControlItem.title.canMoveToSlot(ReaderControlSlot.hidden),
          isTrue,
          reason: '书名可以移出');
      expect(
          ReaderControlItem.gallery.canMoveToSlot(ReaderControlSlot.topCenter),
          isFalse);
      // 坏持久化：别的按钮写进 topCenter、书名写进 topLeft → 归一化各回其位。
      final ReaderControlLayout decoded = ReaderControlLayout.decode(
        '{"version":1,"slots":{"topCenter":["gallery","title"],'
        '"topLeft":["back","title"],"topRight":["settings"]}}',
      );
      expect(decoded.itemsIn(ReaderControlSlot.topCenter),
          <ReaderControlItem>[ReaderControlItem.title]);
      expect(decoded.itemsIn(ReaderControlSlot.topLeft),
          isNot(contains(ReaderControlItem.title)));
      expect(decoded.core.slotOf(ReaderControlItem.gallery),
          ReaderControlSlot.topLeft,
          reason: '误进中槽的按钮回 recoverySlot');
    });

    test('槽位 / 按钮 storageValue 与枚举名一致（持久化契约）', () {
      for (final ReaderControlSlot s in ReaderControlSlot.values) {
        expect(s.storageValue, s.name);
      }
      for (final ReaderControlItem i in ReaderControlItem.values) {
        expect(i.storageValue, i.name);
        expect(ReaderControlItem.fromStorage(i.name), i);
      }
    });
  });

  group('ReaderControlLayoutEditor', () {
    testWidgets('渲染舞台六槽 + 调色板 + 托盘，宽窄两档不溢出', (WidgetTester tester) async {
      for (final double width in <double>[900, 360]) {
        tester.view.physicalSize = Size(width, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        ReaderControlLayout? changed;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ReaderControlLayoutEditor(
                  layout: ReaderControlLayout.defaults,
                  onLayoutChanged: (ReaderControlLayout l) async => changed = l,
                  isTouchControls: false,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'width=$width');
        expect(
          find.byKey(const ValueKey<String>('reader-control-editor-preview')),
          findsOneWidget,
        );
        for (final ReaderControlSlot slot in ReaderControlSlot.editableSlots) {
          expect(
            find.byKey(
                ValueKey<String>('reader-control-edit-slot-${slot.name}')),
            findsOneWidget,
            reason: 'slot ${slot.name} @ $width',
          );
        }
        expect(changed, isNull);
      }
    });

    test('图标 / 文案表覆盖全部按钮与槽位（switch 穷尽，编译期即钉）', () {
      for (final ReaderControlItem i in ReaderControlItem.values) {
        expect(readerControlItemIcon(i), isA<IconData>());
      }
      expect(ReaderControlSlot.editableSlots, hasLength(6));
    });
  });
}
