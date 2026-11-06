import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/legacy_design_compat.dart';
import 'package:fushi/src/utils/misc/update_checker.dart';

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
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(420, 640);
      addTearDown(tester.view.reset);

      final GlobalKey<NavigatorState> navigatorKey =
          GlobalKey<NavigatorState>();
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

      // 与生产装配同一个取法：根 Navigator 的 Overlay。
      final OverlayState overlay = navigatorKey.currentState!.overlay!;
      final ({UpdateDownloadCancellation cancellation, void Function() dispose})
      session = showUpdateDownloadSessionForTest(overlay);
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
}
