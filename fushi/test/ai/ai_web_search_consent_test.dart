// 「联网搜索抓前 3 页网页交给 AI」的首次确认：只在配了后端且没答过时弹；「允许」/
// 「不允许」落进偏好（持久化、之后不再问），点空白关掉不算回答；说明里写明部分 AI
// 提供商自带联网搜索（有的收费），可以不配置这里。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_web_search_consent.dart';
import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/web_search.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
  });
  tearDown(() => db.close());

  /// 挂一个按钮，点了就走一遍确认流程；返回「流程跑完」的计数器。
  Future<List<int>> pumpHost(WidgetTester tester) async {
    final List<int> done = <int>[0];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () async {
                await ensureAiWebSearchPageFetchDecided(context, prefs);
                done[0]++;
              },
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    return done;
  }

  Future<void> trigger(WidgetTester tester) async {
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  }

  testWidgets('没选后端：不弹框、不写偏好', (WidgetTester tester) async {
    final List<int> done = await pumpHost(tester);
    await trigger(tester);
    expect(find.text(t.ai_web_search_consent_title), findsNothing);
    expect(done.single, 1);
    expect(prefs.aiWebSearchPageFetchDecision, '');
  });

  testWidgets('选了后端：问一次，说明写明提供商自带联网搜索；允许后生效且不再问', (WidgetTester tester) async {
    await prefs.setAiWebSearch(
      const WebSearchConfig(kind: WebSearchKind.brave, apiKey: 'k'),
    );
    await pumpHost(tester);
    await trigger(tester);
    expect(find.text(t.ai_web_search_consent_title), findsOneWidget);
    expect(find.textContaining('built-in web search'), findsOneWidget);
    expect(find.textContaining('top 3'), findsOneWidget);

    // 点空白关掉：不算回答。
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(find.text(t.ai_web_search_consent_title), findsNothing);
    expect(prefs.aiWebSearchPageFetchDecision, '');
    expect(prefs.aiWebSearch, isNull);

    await trigger(tester);
    await tester.tap(find.text(t.ai_web_search_consent_accept));
    await tester.pumpAndSettle();
    expect(prefs.aiWebSearchPageFetchDecision, kAiWebSearchPageFetchAllow);
    expect(prefs.aiWebSearch, isNotNull);

    await trigger(tester);
    expect(find.text(t.ai_web_search_consent_title), findsNothing);
  });

  testWidgets('不允许：记下拒绝、AI 功能读不到联网搜索、之后不再问', (WidgetTester tester) async {
    await prefs.setAiWebSearch(
      const WebSearchConfig(
        kind: WebSearchKind.searxng,
        endpoint: 'https://s.example.org',
      ),
    );
    await pumpHost(tester);
    await trigger(tester);
    await tester.tap(find.text(t.ai_web_search_consent_decline));
    await tester.pumpAndSettle();
    expect(prefs.aiWebSearchPageFetchDecision, kAiWebSearchPageFetchDeny);
    expect(prefs.aiWebSearch, isNull);
    final PreferencesRepository fresh = PreferencesRepository(db);
    await fresh.loadFromDb();
    expect(fresh.aiWebSearchPageFetchDecision, kAiWebSearchPageFetchDeny);

    await trigger(tester);
    expect(find.text(t.ai_web_search_consent_title), findsNothing);
  });
}
