import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/online/online_work_detail.dart';

/// 三域共用作品页头部的版式契约（PR #1707 审查）：窄屏时封面右边只剩一百多
/// 像素，主操作区放在那里每个按钮都独占一行、竖着堆成一长条——窄宽时操作区要
/// 挪到封面行下方、占满整宽横排；宽屏仍在封面右侧。
void main() {
  Future<void> pumpHeader(WidgetTester tester, double width) async {
    await tester.binding.setSurfaceSize(Size(width, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          // 与生产同形：头部是 M3E MediaDetailHero，作为 MediaDetailLayout 的
          // header 通栏铺开、自带页边距（spacing.page）；外面再套一层 16 的列表
          // 内边距是旧版（头部不自带边距）的宿主形状，会把窄屏可用宽度多吃掉
          // 32，测的就不是真实版式了。
          body: ListView(
            padding: EdgeInsets.zero,
            children: <Widget>[
              OnlineWorkHeader(
                cover: const ColoredBox(
                  key: ValueKey<String>('cover'),
                  color: Colors.grey,
                ),
                title: 'Work title',
                actions: <Widget>[
                  FilledButton(
                    key: const ValueKey<String>('a'),
                    onPressed: () {},
                    child: const Text('Read'),
                  ),
                  OutlinedButton(
                    key: const ValueKey<String>('b'),
                    onPressed: () {},
                    child: const Text('Add'),
                  ),
                  OutlinedButton(
                    key: const ValueKey<String>('c'),
                    onPressed: () {},
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Rect rectOf(WidgetTester tester, String key) =>
      tester.getRect(find.byKey(ValueKey<String>(key)));

  testWidgets('窄屏：主操作区在封面下方横排，不竖堆', (WidgetTester tester) async {
    await pumpHeader(tester, 360);
    final Rect cover = rectOf(tester, 'cover');
    final Rect a = rectOf(tester, 'a');
    final Rect b = rectOf(tester, 'b');
    final Rect c = rectOf(tester, 'c');
    expect(a.top, greaterThanOrEqualTo(cover.bottom));
    expect(a.left, lessThan(cover.right), reason: '占满整宽，从左边起排');
    expect(b.top, a.top, reason: '同一行横排');
    expect(c.top, a.top, reason: '同一行横排');
  });

  testWidgets('宽屏：主操作区仍在封面右侧', (WidgetTester tester) async {
    await pumpHeader(tester, 1000);
    final Rect cover = rectOf(tester, 'cover');
    final Rect a = rectOf(tester, 'a');
    expect(a.left, greaterThan(cover.right));
    expect(a.top, lessThan(cover.bottom));
  });
}
