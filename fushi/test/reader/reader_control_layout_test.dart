import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/controls/control_layout.dart';
import 'package:fushi/src/reader/reader_control_layout.dart';
import 'package:fushi/src/reader/reader_control_layout_editor.dart';

void main() {
  group('ReaderControlLayout 模型', () {
    test('宽窗出厂布局（2026-10 精简）：左返回 / 中书名 / 右主操作三颗；中频进「更多」', () {
      final ReaderControlLayout d = ReaderControlLayout.defaults;
      expect(d.itemsIn(ReaderControlSlot.topLeft),
          <ReaderControlItem>[ReaderControlItem.back]);
      expect(d.itemsIn(ReaderControlSlot.topCenter),
          <ReaderControlItem>[ReaderControlItem.title]);
      expect(d.itemsIn(ReaderControlSlot.topRight), <ReaderControlItem>[
        ReaderControlItem.navigation,
        ReaderControlItem.audiobook,
        ReaderControlItem.settings,
      ]);
      expect(d.itemsIn(ReaderControlSlot.overflow), <ReaderControlItem>[
        ReaderControlItem.modeToggle,
        ReaderControlItem.statistics,
        ReaderControlItem.gallery,
        ReaderControlItem.fullscreen,
      ]);
      // 常驻按钮数（不含书名）= 4：返回 + 三颗主操作。
      final int pinned = <ReaderControlSlot>[
        ReaderControlSlot.topLeft,
        ReaderControlSlot.topRight,
        ReaderControlSlot.bottomLeft,
        ReaderControlSlot.bottomCenter,
        ReaderControlSlot.bottomRight,
      ].fold<int>(0, (int n, ReaderControlSlot s) => n + d.itemsIn(s).length);
      expect(pinned, 4);
      expect(d.hasBottomItems, isFalse);
      expect(d.showsTitle, isTrue);
      // 计时开关、顶栏 / 底栏开关与有声书传输键出厂全在托盘。
      expect(d.core.removedItems, <ReaderControlItem>{
        ReaderControlItem.studyTimer,
        ReaderControlItem.toolbars,
        ReaderControlItem.audiobookPrev,
        ReaderControlItem.audiobookPlayPause,
        ReaderControlItem.audiobookNext,
        ReaderControlItem.audiobookSeekBack,
        ReaderControlItem.audiobookSeekForward,
        ReaderControlItem.audiobookFollow,
      });
    });

    test('窄窗出厂布局：顶部只留返回 + 书名，主操作下沉底部工具栏（4 颗）', () {
      final ReaderControlLayout c = ReaderControlLayout.compactDefaults;
      expect(c.itemsIn(ReaderControlSlot.topLeft),
          <ReaderControlItem>[ReaderControlItem.back]);
      expect(c.itemsIn(ReaderControlSlot.topRight), isEmpty);
      expect(c.itemsIn(ReaderControlSlot.bottomCenter), <ReaderControlItem>[
        ReaderControlItem.navigation,
        ReaderControlItem.audiobook,
        ReaderControlItem.settings,
        ReaderControlItem.statistics,
      ]);
      expect(c.itemsIn(ReaderControlSlot.overflow), <ReaderControlItem>[
        ReaderControlItem.modeToggle,
        ReaderControlItem.gallery,
        ReaderControlItem.fullscreen,
      ]);
      expect(c.hasBottomItems, isTrue);
    });

    test('存量自定义布局（2026-09 旧出厂形态）解码原样保留，不被新出厂表改写', () {
      // 旧出厂布局被用户存下来的 JSON（每颗按钮都显式在槽或 removed 里）。
      const String legacy = '{"version":1,"slots":{'
          '"topLeft":["back","modeToggle","navigation","gallery","statistics"],'
          '"topCenter":["title"],'
          '"topRight":["audiobook","fullscreen","settings"],'
          '"bottomLeft":[],"bottomCenter":[],"bottomRight":[]},'
          '"removed":["studyTimer","toolbars","audiobookPrev",'
          '"audiobookPlayPause","audiobookNext","audiobookSeekBack",'
          '"audiobookSeekForward","audiobookFollow"]}';
      final ReaderControlLayout d = ReaderControlLayout.decode(legacy);
      expect(d.itemsIn(ReaderControlSlot.topLeft), <ReaderControlItem>[
        ReaderControlItem.back,
        ReaderControlItem.modeToggle,
        ReaderControlItem.navigation,
        ReaderControlItem.gallery,
        ReaderControlItem.statistics,
      ]);
      expect(d.itemsIn(ReaderControlSlot.topRight), <ReaderControlItem>[
        ReaderControlItem.audiobook,
        ReaderControlItem.fullscreen,
        ReaderControlItem.settings,
      ]);
      expect(d.itemsIn(ReaderControlSlot.overflow), isEmpty);
      // 往返不漂。
      expect(ReaderControlLayout.decode(d.encode()), d);
    });

    test('返回不进「更多」；其余按钮可进；书名只在顶栏中间', () {
      expect(ReaderControlItem.back.canMoveToSlot(ReaderControlSlot.overflow),
          isFalse);
      expect(
          ReaderControlItem.gallery.canMoveToSlot(ReaderControlSlot.overflow),
          isTrue);
      expect(
          ReaderControlItem.settings.canMoveToSlot(ReaderControlSlot.overflow),
          isTrue);
      expect(ReaderControlItem.title.canMoveToSlot(ReaderControlSlot.overflow),
          isFalse);
    });

    test('decode 的 fallback：窄窗缺席按钮按窄窗出厂位置回填', () {
      final ReaderControlLayout c = ReaderControlLayout.decode(
        '{"version":1,"slots":{"topLeft":["back"]}}',
        fallback: ReaderControlLayout.compactDefaults,
      );
      expect(c.core.slotOf(ReaderControlItem.navigation),
          ReaderControlSlot.bottomCenter);
      expect(
          ReaderControlLayout.decode('',
              fallback: ReaderControlLayout.compactDefaults),
          ReaderControlLayout.compactDefaults);
    });

    test('专注模式键已删除：存过它的布局解码时丢弃，其余按钮原位', () {
      final ReaderControlLayout stale = ReaderControlLayout.decode(
        '{"version":1,"slots":{"topLeft":["back"],'
        '"topRight":["audiobook","fullscreen","focusMode","settings"]}}',
      );
      // JSON 里缺席的按钮（navigation）按当前出厂位置回填到其后。
      expect(stale.itemsIn(ReaderControlSlot.topRight), <ReaderControlItem>[
        ReaderControlItem.audiobook,
        ReaderControlItem.fullscreen,
        ReaderControlItem.settings,
        ReaderControlItem.navigation,
      ]);
      // 新增的顶栏 / 底栏开关按出厂位置（托盘）补进来，不会冒到顶栏上。
      expect(stale.core.removedItems, contains(ReaderControlItem.toolbars));
    });

    test('栏关掉后悬浮球必带：返回 / 设置（布局必需项）+ 开回栏的键', () {
      expect(kReaderToolbarsTakeoverItems, <ReaderControlItem>[
        ReaderControlItem.back,
        ReaderControlItem.settings,
        ReaderControlItem.toolbars,
      ]);
      for (final ReaderControlItem item in ReaderControlItem.values) {
        if (item.pinnedRequired) {
          expect(kReaderToolbarsTakeoverItems, contains(item),
              reason: '${item.storageValue} 是栏的必需项，栏没了就只能在球上');
        }
      }
    });

    test('传输键可进顶栏 / 底栏；旧布局里的悬浮球槽解码时丢弃，按钮回落出厂位置', () {
      expect(
          ReaderControlItem.audiobookPrev
              .canMoveToSlot(ReaderControlSlot.topLeft),
          isTrue);
      expect(
          ReaderControlItem.audiobookPrev
              .canMoveToSlot(ReaderControlSlot.topCenter),
          isFalse);
      for (final ReaderControlItem i in ReaderControlItem.values) {
        expect(i.isAudiobookTransport,
            i.recoverySlot == ReaderControlSlot.bottomCenter,
            reason: '$i：传输键 ⟺ 回落槽是底栏中间');
      }
      // 悬浮球槽已移出按钮布局（设置 → 悬浮球 是唯一入口）：旧 JSON 里的
      // floatingBall 槽按未知槽丢弃，里面的按钮回到出厂位置。
      final ReaderControlLayout legacy = ReaderControlLayout.decode(
        '{"version":1,"slots":{"topLeft":["back"],"topRight":["settings"],'
        '"floatingBall":["gallery","audiobookPrev"]}}',
      );
      expect(legacy.itemsIn(ReaderControlSlot.overflow),
          contains(ReaderControlItem.gallery));
      expect(
          legacy.core.removedItems, contains(ReaderControlItem.audiobookPrev));
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
      // 出厂就在托盘的三颗传输键也在 removed 里，这里只钉本次移除的那颗。
      expect(raw['removed'], contains('fullscreen'));
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
          ReaderControlLayout.defaults.core.slotOf(ReaderControlItem.gallery),
          reason: '误进中槽的按钮解码时被拒，按出厂位置回填');
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
    testWidgets('渲染舞台七槽（含悬浮球）+ 调色板 + 托盘，宽窄两档不溢出', (WidgetTester tester) async {
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
      expect(ReaderControlSlot.editableSlots, hasLength(7));
      for (final ReaderControlSlot s in ReaderControlSlot.values) {
        expect(readerControlSlotLabel(s), isNotEmpty);
      }
    });
  });
}
