import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_inline_notice.dart';
import 'package:material_ui/material_ui.dart';

/// 反馈 hIEGAdQjkL：同步与历史页横幅里的动作按钮停在横幅正中。旧实现是
/// `Row[Expanded(正文), Flexible(Wrap(动作))]`，两者 flex 相同、Row 对半分宽，
/// 正文被压成一半、按钮紧跟其后，右半边空着。

const String _longMessage =
    'Review data is stored on this device. Sync and backup keep it safe '
    'across devices, and Fushi Link lets a paired host share the same '
    'library without uploading anything to the cloud.';

const Key _noticeKey = ValueKey<String>('notice');
const Key _bodyKey = ValueKey<String>('notice-body');

Widget _host(List<Widget> actions, {double width = 1560}) => MaterialApp(
  theme: ThemeData(useMaterial3: true),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        child: FushiInlineNotice(
          key: _noticeKey,
          message: const Text(_longMessage, key: _bodyKey),
          actions: actions,
        ),
      ),
    ),
  ),
);

List<Widget> _buttons(int count) => <Widget>[
  for (int i = 0; i < count; i++)
    TextButton(
      key: ValueKey<String>('action-$i'),
      onPressed: () {},
      child: Text('Action number $i'),
    ),
];

void _viewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('wide banner: actions hug the right edge, body takes the rest', (
    WidgetTester tester,
  ) async {
    _viewport(tester, const Size(1600, 800));
    await tester.pumpWidget(_host(_buttons(2)));
    await tester.pumpAndSettle();

    final Rect notice = tester.getRect(find.byKey(_noticeKey));
    final Rect body = tester.getRect(find.byKey(_bodyKey));
    final Rect first = tester.getRect(
      find.byKey(const ValueKey<String>('action-0')),
    );
    final Rect last = tester.getRect(
      find.byKey(const ValueKey<String>('action-1')),
    );
    // 同一行，按钮在正文右侧。
    expect((first.center.dy - body.center.dy).abs(), lessThan(24));
    expect(first.left, greaterThan(body.right));
    // 按钮贴横幅右内边距（MD3 水平内边距 16，容差 1）。
    expect(notice.right - last.right, lessThanOrEqualTo(17));
    // 正文吃掉剩余宽度，远超一半。
    expect(body.width, greaterThan(notice.width / 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow banner: actions drop below the body', (
    WidgetTester tester,
  ) async {
    _viewport(tester, const Size(360, 800));
    await tester.pumpWidget(_host(_buttons(2), width: 360));
    await tester.pumpAndSettle();

    final Rect body = tester.getRect(find.byKey(_bodyKey));
    final Rect first = tester.getRect(
      find.byKey(const ValueKey<String>('action-0')),
    );
    expect(first.top, greaterThanOrEqualTo(body.bottom));
    expect((first.left - body.left).abs(), lessThan(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('many actions wrap inside the banner without overflow', (
    WidgetTester tester,
  ) async {
    _viewport(tester, const Size(900, 900));
    await tester.pumpWidget(_host(_buttons(8), width: 900));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final Rect notice = tester.getRect(find.byKey(_noticeKey));
    for (int i = 0; i < 8; i++) {
      final Rect button = tester.getRect(
        find.byKey(ValueKey<String>('action-$i')),
      );
      expect(notice.contains(button.topLeft), isTrue, reason: 'action-$i');
      expect(
        notice.contains(button.bottomRight - const Offset(1, 1)),
        isTrue,
        reason: 'action-$i',
      );
    }
  });

  testWidgets('forced inline (actionsInline: true) never overflows', (
    WidgetTester tester,
  ) async {
    _viewport(tester, const Size(420, 800));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 420,
              child: FushiInlineNotice(
                key: _noticeKey,
                message: const Text(_longMessage, key: _bodyKey),
                actionsInline: true,
                actions: _buttons(3),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final Rect notice = tester.getRect(find.byKey(_noticeKey));
    final Rect last = tester.getRect(
      find.byKey(const ValueKey<String>('action-2')),
    );
    expect(last.right, lessThanOrEqualTo(notice.right));
  });
}
