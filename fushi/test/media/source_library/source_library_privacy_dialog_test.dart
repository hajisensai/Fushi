import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/source_library/source_library_privacy.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

/// 来源库隐私开关对话框（反馈 kEAgATi1LF）：拨开 → 落库 + 调撤下回调；拨关 → 只落库、
/// 不调撤下；落库失败时开关保持原状态。MD3 与 Apple 两套都验。
void main() {
  late FushiDatabase db;
  late int sourceId;
  late int withdrawCalls;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    withdrawCalls = 0;
  });
  tearDown(() => db.close());

  Future<void> pumpDialog(WidgetTester tester, {required bool apple}) async {
    final MediaSourceRow source = (await tester.runAsync<MediaSourceRow?>(
      () => db.getMediaSourceById(sourceId),
    ))!;
    await tester.pumpWidget(
      MaterialApp(
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
              withdrawFromLeaderboard: () async {
                withdrawCalls++;
                return true;
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
    await tester.pumpAndSettle();
  }

  for (final bool apple in <bool>[false, true]) {
    final String system = apple ? 'Apple' : 'MD3';

    testWidgets('$system：拨开落库并撤下，拨关只落库', (WidgetTester tester) async {
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

      await flip(tester, false);
      expect(switchTile(tester).value, isFalse);
      expect(withdrawCalls, 1, reason: '取消私密不需要撤下');
      expect(
        (await tester.runAsync(
          () => db.getMediaSourceById(sourceId),
        ))!.isPrivate,
        isFalse,
      );
    });
  }
}
