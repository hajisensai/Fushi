import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/dictionary_download_controller.dart';
import 'package:fushi/src/pages/implementations/dictionary_dialog_page.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget child) {
    return TranslationProvider(
      child: MaterialApp(home: Scaffold(body: Center(child: child))),
    );
  }

  testWidgets('dictionary download selection dialog fits a compact window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 480);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        DictionaryDownloadSelectionDialogFrame(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text('Language'),
              for (int index = 0; index < 12; index++)
                Text('Recommended dictionary with a long label $index'),
            ],
          ),
          actions: const <Widget>[
            TextButton(onPressed: null, child: Text('Cancel')),
            FilledButton(onPressed: null, child: Text('Download 12')),
          ],
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Download 12'), findsOneWidget);
  });

  testWidgets('dictionary download progress dialog fits a compact window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 480);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        DictionaryDownloadProgressDialog(
          message:
              'Downloading a recommended dictionary with a long visible name',
          progressListenable: ValueNotifier<double>(0.42),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  group('BUG-1499 进度框：取消与后台化', () {
    testWidgets('下载阶段：取消按钮可点，不显示「停不下来」的说明', (WidgetTester tester) async {
      int cancelled = 0;
      await tester.pumpWidget(
        buildApp(
          DictionaryDownloadProgressDialog(
            message: 'Downloading JMdict',
            progressListenable: ValueNotifier<double>(0.42),
            onCancel: () => cancelled++,
            cancelDisabledHint: t.dict_download_import_uncancellable,
            onHide: () {},
          ),
        ),
      );

      expect(find.text(t.dict_download_import_uncancellable), findsNothing);
      await tester.tap(find.text(t.dialog_cancel));
      await tester.pump();
      expect(cancelled, 1);
    });

    testWidgets('导入阶段：取消按钮点不动，并如实说明这一步无法中断', (WidgetTester tester) async {
      await tester.pumpWidget(
        buildApp(
          DictionaryDownloadProgressDialog(
            message: 'Importing JMdict',
            progressListenable: ValueNotifier<double>(0),
            // onCancel == null 就是「这一阶段停不下来」的唯一表达。
            cancelDisabledHint: t.dict_download_import_uncancellable,
            onHide: () {},
          ),
        ),
      );

      expect(find.text(t.dict_download_import_uncancellable), findsOneWidget);
      await tester.tap(find.text(t.dialog_cancel));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: '按钮 disabled，点了什么都不该发生');
    });

    testWidgets('收起进度框后任务照跑，结果仍然送达', (WidgetTester tester) async {
      final List<DictionaryDownloadOutcome> outcomes =
          <DictionaryDownloadOutcome>[];
      final DictionaryDownloadController controller =
          DictionaryDownloadController(showOutcome: outcomes.add);
      addTearDown(controller.dispose);
      final Completer<void> hold = Completer<void>();

      late BuildContext pageContext;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Builder(
              builder: (BuildContext ctx) {
                pageContext = ctx;
                return const Scaffold(body: Text('dictionary page'));
              },
            ),
          ),
        ),
      );

      final Future<bool> running = controller.run(
        initialMessage: 'start',
        body: (DictionaryDownloadJob job) async {
          job.markDownloadPhase();
          // 给一个确定的比例：留 0 会让 LinearProgressIndicator 退化成不定态动画，
          // pumpAndSettle 永远等不到静止（那是测试脚手架的事，不是产品行为）。
          job.progress.value = 0.5;
          await hold.future;
          return const DictionaryDownloadOutcome(message: 'finished');
        },
      );
      await tester.pump();

      unawaited(showAppDialog<void>(
        context: pageContext,
        barrierDismissible: false,
        builder: (BuildContext ctx) => DictionaryDownloadProgressAutoCloser(
          phase: controller.phase,
          child: DictionaryDownloadProgressDialog(
            message: 'start',
            progressListenable: controller.progress,
            onHide: () => Navigator.of(ctx).pop(),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text(t.dict_download_hide), findsOneWidget);

      await tester.tap(find.text(t.dict_download_hide));
      await tester.pumpAndSettle();

      expect(find.text(t.dict_download_hide), findsNothing, reason: '进度框收起来了');
      expect(find.text('dictionary page'), findsOneWidget,
          reason: '收起进度框绝不能连带弹掉词典页本身');
      expect(controller.isBusy, isTrue, reason: '任务不属于对话框，收起来只是不看');

      hold.complete();
      expect(await running, isTrue);
      await tester.pumpAndSettle();

      expect(outcomes.single.message, 'finished',
          reason: '结果由 controller 送出，与页面/对话框是否还在无关');
      expect(tester.takeException(), isNull);
    });

    testWidgets('任务结束时进度框自己关闭，只弹掉自己', (WidgetTester tester) async {
      final DictionaryDownloadController controller =
          DictionaryDownloadController(showOutcome: (_) {});
      addTearDown(controller.dispose);
      final Completer<void> hold = Completer<void>();

      late BuildContext pageContext;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Builder(
              builder: (BuildContext ctx) {
                pageContext = ctx;
                return const Scaffold(body: Text('dictionary page'));
              },
            ),
          ),
        ),
      );

      final Future<bool> running = controller.run(
        initialMessage: 'start',
        body: (DictionaryDownloadJob job) async {
          job.markDownloadPhase();
          job.progress.value = 0.5;
          await hold.future;
          return null;
        },
      );
      await tester.pump();

      unawaited(showAppDialog<void>(
        context: pageContext,
        barrierDismissible: false,
        builder: (BuildContext ctx) => DictionaryDownloadProgressAutoCloser(
          phase: controller.phase,
          child: DictionaryDownloadProgressDialog(
            message: 'start',
            progressListenable: controller.progress,
            onHide: () => Navigator.of(ctx).pop(),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text(t.dict_download_hide), findsOneWidget);

      hold.complete();
      expect(await running, isTrue);
      await tester.pumpAndSettle();

      expect(find.text(t.dict_download_hide), findsNothing,
          reason: '任务结束进度框应自己消失');
      expect(find.text('dictionary page'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
