// AI 操作记录页：列表顶部留白必须让出页头大字（BUG-5456，与 BUG-5171 同一机制）。
// MD3 与 Apple 两套设计系统各跑一遍。
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/ai_agent_history_page.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_masthead_scaffold.dart'
    show FushiMastheadHeader;
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiPageHeader;
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  late FushiDatabase db;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  ThemeData theme({required bool apple}) => buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    designSystem: apple
        ? FushiDesignSystem.cupertino
        : FushiDesignSystem.material,
    glass: FushiGlassMaterial.off,
    glassDesign: apple,
  );

  Future<int> seedAction(String sessionId) => db.insertAiAgentAction(
    AiAgentActionsCompanion.insert(
      sessionId: sessionId,
      opId: 'library.curate.links.infer',
      argsJson: '{}',
      risk: 'write',
      confirmation: 'auto',
      resultCode: 'ok',
      undoPayloadJson: const Value<String?>('{}'),
      beforeText: const Value<String?>(null),
      afterText: const Value<String?>('17 link(s)'),
      createdAt: DateTime(2026, 11, 24, 23, 39).millisecondsSinceEpoch,
    ),
  );

  Future<void> pumpPage(WidgetTester tester, {required bool apple}) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme(apple: apple),
          builder: (BuildContext context, Widget? child) =>
              FushiGlassScope(child: child!),
          home: AiAgentHistoryPage(db: db),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';

    testWidgets('$ds：首个会话头与第一行都排在页头下沿之下', (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 1200);
      addTearDown(tester.view.reset);
      const String sessionId = 's1';
      final int actionId = await seedAction(sessionId);
      await pumpPage(tester, apple: apple);

      // M3E = 页头大字外壳；Apple = iOS 27 / macOS 27 导航栏行（二级页不走
      // 页头大字）。两者都要把正文让到栏下沿之下。
      final double headerBottom = tester
          .getRect(
            find.byType(apple ? FushiPageHeader : FushiMastheadHeader).first,
          )
          .bottom;
      expect(headerBottom, greaterThan(0));
      expect(
        tester
            .getRect(
              find.byKey(
                const ValueKey<String>('ai_agent_history_undo_all_$sessionId'),
              ),
            )
            .top,
        greaterThanOrEqualTo(headerBottom),
        reason: '首个会话头（含「全部撤销」）不能被页头盖住',
      );
      expect(
        tester
            .getRect(
              find.byKey(ValueKey<String>('ai_agent_history_action_$actionId')),
            )
            .top,
        greaterThan(headerBottom),
      );
    });
  }
}
