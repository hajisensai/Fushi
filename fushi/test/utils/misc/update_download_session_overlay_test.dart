import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/legacy_design_compat.dart';
import 'package:fushi/src/utils/misc/update_checker.dart';

typedef _TestSession = ({
  UpdateDownloadCancellation cancellation,
  void Function(double progress) onProgress,
  void Function() dispose,
});

/// 起一个带根 Navigator 的最小 app，返回根 Navigator 的 Overlay（与生产装配同一个取法）。
Future<OverlayState> _pumpHost(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(420, 640);
  addTearDown(tester.view.reset);

  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        navigatorKey: navigatorKey,
        builder: (BuildContext context, Widget? navigator) =>
            LegacyDesignCompatibility(child: navigator!),
        home: const Scaffold(body: SizedBox.expand()),
      ),
    ),
  );
  return navigatorKey.currentState!.overlay!;
}

/// PR #2100 审查（反馈 Pp8XPyve0N）：互联远程触发的更新在 host 上必须看得见、能取消，
/// 而且用的是与本机「检查更新」**同一个**下载会话（浮层 + 取消令牌），不是另一套。
/// 本测试直接驱动生产的 `_UpdateDownloadSession`（经测试缝）：浮层进 Overlay、「取消」
/// 真的置位取消令牌、收尾后浮层消失。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  testWidgets(
    'shared download session shows the overlay and cancels for real',
    (WidgetTester tester) async {
      final OverlayState overlay = await _pumpHost(tester);
      final _TestSession session = showUpdateDownloadSessionForTest(overlay);
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text(t.update_connecting), findsOneWidget);
      expect(find.text(t.update_cancel), findsOneWidget);
      expect(session.cancellation.isCancelled, isFalse);

      await tester.tap(find.text(t.update_cancel));
      await tester.pump();
      expect(
        session.cancellation.isCancelled,
        isTrue,
        reason: '「取消」必须置位下载引擎看的那个令牌',
      );
      expect(find.text(t.update_cancelling), findsOneWidget);

      session.dispose();
      await tester.pump();
      expect(find.text(t.update_cancel), findsNothing, reason: '会话收尾即撤掉浮层');
    },
  );

  // BUG-5168（应用内反馈 t0mmZroouh）：下载浮层点「隐藏」后，再「检查更新」只回一句
  // 「正在下载」，浮层与进度再也回不来。
  testWidgets(
    'hidden download overlay comes back on a repeat update check for the same '
    'version, progress intact',
    (WidgetTester tester) async {
      const String version = '9.9.9-bug5168';
      final OverlayState overlay = await _pumpHost(tester);
      final _TestSession session = showUpdateDownloadSessionForTest(
        overlay,
        version: version,
      );
      addTearDown(session.dispose);
      session.onProgress(0.42);
      await tester.pump();
      expect(find.text('42%'), findsOneWidget);

      await tester.tap(find.text(t.update_hide));
      await tester.pump();
      expect(find.text(t.update_cancel), findsNothing, reason: '「隐藏」收起浮层');

      // 同版本更新流在途（与生产同一把版本级互斥锁、同一个 key）。
      final Completer<void> flowDone = Completer<void>();
      final Future<void> flow = UpdateChecker.runExclusiveUpdateFlowForTest(
        'update|$version',
        () => flowDone.future,
      );

      final BuildContext context = tester.element(find.byType(Scaffold));
      expect(
        UpdateChecker.notifyIfUpdateFlowActiveForTest(context, version),
        isTrue,
      );
      await tester.pump();
      expect(
        find.text(t.update_cancel),
        findsOneWidget,
        reason: '再次检查同版本必须把隐藏的下载浮层拉回来',
      );
      expect(find.text('42%'), findsOneWidget, reason: '进度留在会话里，不归零');
      expect(find.byType(SnackBar), findsNothing, reason: '浮层能拉回就不再只弹一句「正在下载」');

      flowDone.complete();
      await flow;
    },
  );

  testWidgets(
    'manual check entry reveals any hidden in-flight download; nothing to '
    'reveal once the session is gone',
    (WidgetTester tester) async {
      final OverlayState overlay = await _pumpHost(tester);
      final _TestSession session = showUpdateDownloadSessionForTest(
        overlay,
        version: '9.9.10-bug5168',
      );
      await tester.pump();
      await tester.tap(find.text(t.update_hide));
      await tester.pump();
      expect(find.text(t.update_cancel), findsNothing);

      expect(UpdateChecker.revealActiveDownload(), isTrue);
      await tester.pump();
      expect(find.text(t.update_cancel), findsOneWidget);

      session.dispose();
      await tester.pump();
      expect(
        UpdateChecker.revealActiveDownload(),
        isFalse,
        reason: '会话收尾即从登记表注销，不留悬空引用',
      );
    },
  );
}
