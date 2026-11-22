// 制卡结果队列（用户 2026-11-22 重设计）：处理中原地变结果、连续结果叠放 + 计数徽标、
// 悬停停表、失败卡展开详情不自动收起。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_mine_notice_card.dart';
import 'package:fushi/src/utils/components/fushi_mine_notice_stack.dart';
import 'package:fushi/src/utils/misc/toast_severity.dart';
import 'package:material_ui/material_ui.dart';

MineNotice _n(MineToastStatus s, {String? term, String msg = 'm'}) =>
    MineNotice(status: s, message: msg, term: term);

void main() {
  group('MineNoticeController', () {
    test('结果替换同词的处理中卡（id 不变），否则替换最近的处理中卡', () {
      final MineNoticeController c = MineNoticeController();
      addTearDown(c.dispose);
      final int a = c.show(_n(MineToastStatus.pending, term: '雪'));
      final int b = c.show(_n(MineToastStatus.pending, term: '雨'));
      expect(c.show(_n(MineToastStatus.added, term: '雪')), a);
      expect(c.entries.length, 2);
      expect(c.show(_n(MineToastStatus.failed)), b, reason: '没带词：替换最近那张');
      expect(c.entries.firstWhere((e) => e.id == b).notice.term, '雨');
    });

    test('超出上限丢最旧的非失败卡', () {
      final MineNoticeController c = MineNoticeController(maxEntries: 2);
      addTearDown(c.dispose);
      final int failed = c.show(_n(MineToastStatus.failed));
      c.show(_n(MineToastStatus.added));
      final int newest = c.show(_n(MineToastStatus.added));
      expect(c.entries.map((e) => e.id), <int>[newest, failed]);
    });

    testWidgets('到期自动收；停表 / 展开期间不收', (WidgetTester tester) async {
      final MineNoticeController c = MineNoticeController();
      addTearDown(c.dispose);
      c.show(_n(MineToastStatus.added));
      await tester.pump(const Duration(seconds: 3));
      expect(c.isEmpty, isTrue, reason: '成功 2.4 秒');

      final int f = c.show(_n(MineToastStatus.failed));
      c.setExpanded(f, true);
      await tester.pump(const Duration(seconds: 20));
      expect(c.entries.single.id, f, reason: '展开详情不自动收');
      c.setExpanded(f, false);

      c.paused = true;
      await tester.pump(const Duration(seconds: 20));
      expect(c.isEmpty, isFalse, reason: '悬停停表');
      c.paused = false;
      await tester.pump(const Duration(seconds: 9));
      expect(c.isEmpty, isTrue);
    });
  });

  group('FushiMineNoticeStack', () {
    Future<MineNoticeController> pumpStack(WidgetTester tester) async {
      final MineNoticeController c = MineNoticeController();
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: FushiMineNoticeStack(
                controller: c,
                anchor: MineNoticeStackAnchor.bottom,
              ),
            ),
          ),
        ),
      );
      return c;
    }

    testWidgets('连续结果叠成一张 + 计数徽标；点徽标展开成列表、能收回', (WidgetTester tester) async {
      final MineNoticeController c = await pumpStack(tester);
      c.show(_n(MineToastStatus.failed, term: '雪'));
      c.show(_n(MineToastStatus.failed, term: '雨'));
      c.show(_n(MineToastStatus.failed, term: '風'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.byType(FushiMineNoticeCard),
        findsOneWidget,
        reason: '收起时只画最新一张',
      );
      final Finder badge = find.byKey(
        const ValueKey<String>('mine-notice-stack-badge'),
      );
      expect(badge, findsOneWidget);
      // 点徽标伸出卡角外的那一侧也要中（伸出父盒的部分 Flutter 不做命中测试）。
      await tester.tapAt(tester.getRect(badge).topRight + const Offset(-4, 4));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(FushiMineNoticeCard), findsNWidgets(3));

      await tester.tap(
        find.byKey(const ValueKey<String>('mine-notice-stack-collapse')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(FushiMineNoticeCard), findsOneWidget);
      c.clear();
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('动作按钮：先收卡再执行', (WidgetTester tester) async {
      final MineNoticeController c = await pumpStack(tester);
      bool? emptyWhenPressed;
      c.show(
        MineNotice(
          status: MineToastStatus.queued,
          message: '已加入待发队列',
          action: MineNoticeAction(
            label: '查看队列',
            onPressed: () => emptyWhenPressed = c.isEmpty,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(
        find.byKey(const ValueKey<String>('mine-notice-action')),
      );
      await tester.pump();
      expect(emptyWhenPressed, isTrue);
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('失败卡消息放不下时出「详情」，展开后可复制、不自动收', (WidgetTester tester) async {
      final MineNoticeController c = await pumpStack(tester);
      c.show(
        _n(
          MineToastStatus.failed,
          term: '雪',
          msg: List<String>.filled(40, 'AnkiConnect timed out').join(' '),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final Finder details = find.byKey(
        const ValueKey<String>('mine-notice-details'),
      );
      expect(details, findsOneWidget);
      await tester.tap(details);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const ValueKey<String>('mine-notice-copy')),
        findsOneWidget,
      );
      expect(c.entries.single.expanded, isTrue);
      await tester.pump(const Duration(seconds: 20));
      expect(c.isEmpty, isFalse, reason: '展开的失败卡等用户关');
      c.clear();
      await tester.pump(const Duration(milliseconds: 400));
    });
  });
}
