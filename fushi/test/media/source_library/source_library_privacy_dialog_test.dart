import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/source_library/source_library_privacy.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

/// 来源库隐私开关对话框（反馈 kEAgATi1LF）：拨开 → 落库 + 后台调撤下回调；拨关 →
/// 只落库、不调撤下；落库失败时开关保持原状态。撤下是一次网络同步，不许把对话框
/// 卡住：落库成功后控件立即放开，撤下结果在后台用 toast 报告。MD3 与 Apple 两套都验。
void main() {
  late FushiDatabase db;
  late int sourceId;
  late int withdrawCalls;
  late Future<bool> Function() withdrawBehaviour;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    withdrawCalls = 0;
    withdrawBehaviour = () async => true;
  });
  tearDown(() => db.close());

  Future<void> seedSource(WidgetTester tester) async {
    await tester.runAsync(() async {
      sourceId = await db.insertMediaSource(
        MediaSourcesCompanion.insert(
          label: 'nsfw',
          mediaKind: 'video',
          rootPath: '/videos/nsfw',
          createdAt: 0,
        ),
      );
    });
  }

  Future<void> pumpDialog(WidgetTester tester, {required bool apple}) async {
    final MediaSourceRow source = (await tester.runAsync<MediaSourceRow?>(
      () => db.getMediaSourceById(sourceId),
    ))!;
    final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
    // toast 画进 app 的 overlay，测试才看得到后台撤下的结果报告。
    FushiToast.navigatorKey = navigatorKey;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        theme: buildFushiThemeData(
          scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
          textTheme: Typography.material2021().black,
          glass: FushiGlassMaterial.off,
          glassDesign: apple,
        ),
        home: FushiGlassScope(
          child: Scaffold(
            body: SourceLibraryPrivacyDialog(
              db: db,
              source: source,
              withdrawFromLeaderboard: () {
                withdrawCalls++;
                return withdrawBehaviour();
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  FushiSwitchListTile switchTile(WidgetTester tester) =>
      tester.widget<FushiSwitchListTile>(
        find.byKey(const ValueKey<String>('media-source-privacy-switch')),
      );

  Future<void> flip(WidgetTester tester, bool value) async {
    switchTile(tester).onChanged!(value);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  }

  /// toast 停留 2 秒后自己退场；推过去，免得测试结束时还挂着计时器。
  Future<void> drainToasts(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  }

  for (final bool apple in <bool>[false, true]) {
    final String system = apple ? 'Apple' : 'MD3';

    testWidgets('$system：拨开落库并撤下，拨关只落库', (WidgetTester tester) async {
      await seedSource(tester);
      await pumpDialog(tester, apple: apple);
      expect(switchTile(tester).value, isFalse);
      expect(find.text(t.media_source_privacy_hint), findsOneWidget);

      await flip(tester, true);
      expect(switchTile(tester).value, isTrue);
      expect(withdrawCalls, 1);
      expect(
        (await tester.runAsync(
          () => db.getMediaSourceById(sourceId),
        ))!.isPrivate,
        isTrue,
      );
      expect(find.text(t.media_source_privacy_withdrawn_toast), findsOneWidget);
      await drainToasts(tester);

      await flip(tester, false);
      expect(switchTile(tester).value, isFalse);
      expect(withdrawCalls, 1, reason: '取消私密不需要撤下');
      expect(
        (await tester.runAsync(
          () => db.getMediaSourceById(sourceId),
        ))!.isPrivate,
        isFalse,
      );
      await drainToasts(tester);
    });

    testWidgets('$system：撤下同步进行中，落库成功后对话框立即可操作 / 可关', (
      WidgetTester tester,
    ) async {
      final Completer<bool> sync = Completer<bool>();
      withdrawBehaviour = () => sync.future;
      await seedSource(tester);
      await pumpDialog(tester, apple: apple);

      await flip(tester, true);
      expect(withdrawCalls, 1);
      expect(
        (await tester.runAsync(
          () => db.getMediaSourceById(sourceId),
        ))!.isPrivate,
        isTrue,
      );
      // 同步还挂着：开关、关闭按钮都已放开，进度条已收起。
      expect(switchTile(tester).value, isTrue);
      expect(switchTile(tester).onChanged, isNotNull);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('media-source-privacy-busy')),
        findsNothing,
      );
      expect(find.text(t.media_source_privacy_withdrawn_toast), findsNothing);

      // 关掉对话框（整棵换出树）后同步才失败：结果仍然报出来，不吞。
      final GlobalKey<NavigatorState> hostKey = GlobalKey<NavigatorState>();
      FushiToast.navigatorKey = hostKey;
      await tester.pumpWidget(
        MaterialApp(navigatorKey: hostKey, home: const Scaffold()),
      );
      sync.completeError(StateError('offline'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(
        find.text(
          t.media_source_privacy_withdraw_failed(
            reason: StateError('offline').toString(),
          ),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await drainToasts(tester);
    });
  }

  test('withdrawSourceLibraryFromLeaderboard：三种结果', () async {
    expect(
      (await withdrawSourceLibraryFromLeaderboard(() async => true)).outcome,
      SourceLibraryWithdrawOutcome.withdrawn,
    );
    expect(
      (await withdrawSourceLibraryFromLeaderboard(() async => false)).outcome,
      SourceLibraryWithdrawOutcome.notUploading,
    );
    final SourceLibraryWithdrawResult failed =
        await withdrawSourceLibraryFromLeaderboard(
          () async => throw StateError('boom'),
        );
    expect(failed.outcome, SourceLibraryWithdrawOutcome.failed);
    expect(failed.error, isA<StateError>());
  });
}
