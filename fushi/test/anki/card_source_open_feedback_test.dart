import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/card_source_open_feedback.dart';

/// 反馈 7gkdbfCXQ0：点卡片底部来源跳互联 host 上的视频时，要先拉 host 清单（含候选
/// 地址选路）才跳，等待期间界面毫无反馈。点下去的同一帧就得出现进度对话框，等完关掉
/// 再跳；用户取消则放弃这次跳转。
void main() {
  Future<NavigatorState> pumpHost(WidgetTester tester) async {
    final GlobalKey<NavigatorState> key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: key,
        theme: ThemeData(useMaterial3: true),
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );
    return key.currentState!;
  }

  testWidgets('等清单期间立刻显示进度对话框，完成后关掉并返回结果', (WidgetTester tester) async {
    final NavigatorState navigator = await pumpHost(tester);
    final Completer<List<String>> listing = Completer<List<String>>();
    CardSourceAwaited<List<String>>? result;
    unawaited(
      awaitWithCardSourceOpeningFeedback<List<String>>(
        navigator: navigator,
        work: listing.future,
      ).then((CardSourceAwaited<List<String>> r) => result = r),
    );
    await tester.pump();
    expect(find.text(t.card_source_remote_loading_title), findsOneWidget);
    expect(find.text(t.card_source_remote_loading_hint), findsOneWidget);

    listing.complete(<String>['uid-a']);
    // 不定态加载指示一直在转，对话框开着时不会 settle：按退场动效泵帧。
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(t.card_source_remote_loading_title), findsNothing);
    expect(result, isNotNull);
    expect(result!.cancelled, isFalse);
    expect(result!.value, <String>['uid-a']);
  });

  testWidgets('取消：放弃这次跳转，迟到的清单被丢弃', (WidgetTester tester) async {
    final NavigatorState navigator = await pumpHost(tester);
    final Completer<List<String>> listing = Completer<List<String>>();
    CardSourceAwaited<List<String>>? result;
    unawaited(
      awaitWithCardSourceOpeningFeedback<List<String>>(
        navigator: navigator,
        work: listing.future,
      ).then((CardSourceAwaited<List<String>> r) => result = r),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text(t.dialog_cancel));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(t.card_source_remote_loading_title), findsNothing);
    expect(result, isNotNull);
    expect(result!.cancelled, isTrue);
    expect(result!.value, isNull);

    listing.complete(<String>['late']);
    await tester.pump();
    expect(result!.cancelled, isTrue);
  });

  testWidgets('系统返回键等同取消', (WidgetTester tester) async {
    final NavigatorState navigator = await pumpHost(tester);
    CardSourceAwaited<int>? result;
    unawaited(
      awaitWithCardSourceOpeningFeedback<int>(
        navigator: navigator,
        work: Completer<int>().future,
      ).then((CardSourceAwaited<int> r) => result = r),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(result?.cancelled, isTrue);
  });

  testWidgets('取消前清单失败：原样抛给调用方，对话框照样关掉', (WidgetTester tester) async {
    final NavigatorState navigator = await pumpHost(tester);
    final Completer<int> listing = Completer<int>();
    Object? error;
    unawaited(
      awaitWithCardSourceOpeningFeedback<int>(
        navigator: navigator,
        work: listing.future,
      ).then<void>((_) {}, onError: (Object e) => error = e),
    );
    await tester.pump();
    listing.completeError(StateError('host down'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(error, isA<StateError>());
    expect(find.text(t.card_source_remote_loading_title), findsNothing);
  });

  test('接线：来源跳转的远端解析经进度反馈等清单，取消即放弃跳转', () {
    final String router = File(
      'lib/src/anki/card_source_router.dart',
    ).readAsStringSync();
    expect(router, contains('awaitWithCardSourceOpeningFeedback<'));
    // 「立即可得」必须与 read 同一判据（在途请求也要挂反馈），不能用 peek 模拟。
    expect(router, contains('cache.wouldReadImmediately('));
    expect(router, isNot(contains('cache.peek<')));
    // 取消由 decideCardSourceVideoAction 判成 cancelled、调用方直接 return；等完
    // 回来 navigator 已卸载同样放弃。
    expect(
      router,
      contains(
        'if (lookup?.cancelled ?? false) return CardSourceVideoAction.cancelled;',
      ),
    );
    expect(
      router,
      contains('if (lookup != null && !navigator.mounted) return;'),
    );
    expect(
      router,
      contains('case CardSourceVideoAction.cancelled:\n        return;'),
    );
  });
}
