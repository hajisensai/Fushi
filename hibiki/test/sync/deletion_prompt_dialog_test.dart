/// 删除传播接收端「其他设备已删除，本地也删？」逐条确认弹窗的 widget 守卫：
/// 默认全选、取消返回 null、删除选中返回勾选候选、取消勾选后不含该条。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/sync/deletion_prompt.dart';
import 'package:hibiki/src/sync/deletion_propagation.dart';

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Widget host(Widget child) =>
      TranslationProvider(child: MaterialApp(home: child));

  List<DeletionCandidateView> twoViews() => <DeletionCandidateView>[
        const DeletionCandidateView(
          candidate: DeletionPropagationCandidate(
            mediaType: 'book',
            itemKey: 'k1',
            direction: DeletionPropagationDirection.deleteLocal,
          ),
          title: 'Book One',
        ),
        const DeletionCandidateView(
          candidate: DeletionPropagationCandidate(
            mediaType: 'video',
            itemKey: 'k2',
            direction: DeletionPropagationDirection.deleteLocal,
          ),
          title: 'Video Two',
        ),
      ];

  testWidgets('默认全选 → 删除选中返回全部候选', (WidgetTester tester) async {
    List<DeletionPropagationCandidate>? result;
    await tester.pumpWidget(host(Builder(builder: (BuildContext ctx) {
      return TextButton(
        onPressed: () async {
          result = await showDialog<List<DeletionPropagationCandidate>>(
            context: ctx,
            builder: (_) => DeletionPromptDialog(views: twoViews()),
          );
        },
        child: const Text('open'),
      );
    })));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Book One'), findsOneWidget);
    expect(find.text('Video Two'), findsOneWidget);

    await tester.tap(find.text(t.delete_prompt_delete_selected));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.length, 2); // 默认全选。
  });

  testWidgets('取消 → 返回 null', (WidgetTester tester) async {
    List<DeletionPropagationCandidate>? result;
    bool ran = false;
    await tester.pumpWidget(host(Builder(builder: (BuildContext ctx) {
      return TextButton(
        onPressed: () async {
          result = await showDialog<List<DeletionPropagationCandidate>>(
            context: ctx,
            builder: (_) => DeletionPromptDialog(views: twoViews()),
          );
          ran = true;
        },
        child: const Text('open'),
      );
    })));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.dialog_cancel));
    await tester.pumpAndSettle();

    expect(ran, isTrue);
    expect(result, isNull);
  });

  testWidgets('取消勾选一条 → 删除选中不含该条', (WidgetTester tester) async {
    List<DeletionPropagationCandidate>? result;
    await tester.pumpWidget(host(Builder(builder: (BuildContext ctx) {
      return TextButton(
        onPressed: () async {
          result = await showDialog<List<DeletionPropagationCandidate>>(
            context: ctx,
            builder: (_) => DeletionPromptDialog(views: twoViews()),
          );
        },
        child: const Text('open'),
      );
    })));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 取消勾选第一条（点其行切换）。
    await tester.tap(find.text('Book One'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.delete_prompt_delete_selected));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.length, 1);
    expect(result!.single.itemKey, 'k2'); // 只剩未取消的视频。
  });
}
