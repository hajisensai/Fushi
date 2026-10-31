// AI 助手会话列表（反馈 uILXKiYRhl「随意切换会话、看历史会话」）：列出当前 Profile
// 的会话并高亮当前这场、点行切换、行尾菜单重命名 / 删除（删除先确认，取消不删），
// 一轮在跑时不让切换 / 新建。MD3 与 Apple 两套设计系统各跑一遍。
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ai/agent/ai_agent_conversation_controller.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/ai_agent_sessions.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart' show AiAgentSessionSummary;
import 'package:material_ui/material_ui.dart';

/// 内存里的会话库：行为与 `AiAgentController` 的会话库约定一致（改动后加一
/// [sessionsRevision]，删当前这场后变成未落库的新对话）。
class _FakeLibrary extends ChangeNotifier implements AiAgentSessionLibrary {
  _FakeLibrary(this.sessions, {this.currentSessionId});

  final List<AiAgentSessionSummary> sessions;
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);
  final List<String> calls = <String>[];

  @override
  String? currentSessionId;

  bool _running = false;

  @override
  bool get running => _running;
  set running(bool value) {
    _running = value;
    notifyListeners();
  }

  @override
  bool get currentSessionUnsaved => currentSessionId == null;

  @override
  ValueListenable<int> get sessionsRevision => _revision;

  @override
  Future<List<AiAgentSessionSummary>> listSessions() async =>
      List<AiAgentSessionSummary>.of(sessions);

  @override
  Future<bool> switchToSession(String sessionId) async {
    calls.add('switch:$sessionId');
    if (!sessions.any((AiAgentSessionSummary s) => s.id == sessionId)) {
      return false;
    }
    currentSessionId = sessionId;
    notifyListeners();
    _revision.value++;
    return true;
  }

  @override
  Future<void> newSession() async {
    calls.add('new');
    currentSessionId = null;
    notifyListeners();
    _revision.value++;
  }

  @override
  Future<void> renameSession(String sessionId, String title) async {
    calls.add('rename:$sessionId:$title');
    final int i = sessions.indexWhere(
      (AiAgentSessionSummary s) => s.id == sessionId,
    );
    final AiAgentSessionSummary old = sessions[i];
    sessions[i] = AiAgentSessionSummary(
      id: old.id,
      title: title.trim(),
      scene: old.scene,
      profileUid: old.profileUid,
      totalTokens: old.totalTokens,
      createdAt: old.createdAt,
      updatedAt: old.updatedAt,
    );
    _revision.value++;
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    calls.add('delete:$sessionId');
    sessions.removeWhere((AiAgentSessionSummary s) => s.id == sessionId);
    if (currentSessionId == sessionId) {
      currentSessionId = null;
      notifyListeners();
    }
    _revision.value++;
  }

  /// 外部改了存档（另一处界面 / 存档写入）：通知列表重读。
  void bump() {
    notifyListeners();
    _revision.value++;
  }

  @override
  void dispose() {
    _revision.dispose();
    super.dispose();
  }
}

AiAgentSessionSummary _summary(String id, String title, int updatedAt) =>
    AiAgentSessionSummary(
      id: id,
      title: title,
      scene: 'general',
      profileUid: 'uid-a',
      totalTokens: 0,
      createdAt: updatedAt,
      updatedAt: updatedAt,
    );

void main() {
  ThemeData theme({required bool apple}) => buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    designSystem: apple
        ? FushiDesignSystem.cupertino
        : FushiDesignSystem.material,
    glass: FushiGlassMaterial.off,
    glassDesign: apple,
  );

  Future<void> pumpList(
    WidgetTester tester,
    _FakeLibrary library, {
    required bool apple,
    VoidCallback? onChosen,
  }) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme(apple: apple),
          builder: (BuildContext context, Widget? child) =>
              FushiGlassScope(child: child!),
          home: Scaffold(
            body: AiAgentSessionList(
              library: library,
              onSessionChosen: onChosen,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';

    testWidgets('$ds：列出会话、当前这场有标记；点另一场切过去', (WidgetTester tester) async {
      final DateTime today = DateTime.now();
      final _FakeLibrary library = _FakeLibrary(<AiAgentSessionSummary>[
        _summary('s2', '整理书架', today.millisecondsSinceEpoch),
        _summary('s1', '', today.millisecondsSinceEpoch - 1000),
      ], currentSessionId: 's2');
      addTearDown(library.dispose);
      int chosen = 0;
      await pumpList(tester, library, apple: apple, onChosen: () => chosen++);

      expect(find.text(t.ai_agent_sessions_title), findsOneWidget);
      expect(find.byKey(kAiAgentSessionsDraftKey), findsNothing);
      expect(find.text('整理书架'), findsOneWidget);
      // 空标题显示成「新对话」；当前这场带「当前」。
      expect(
        find.descendant(
          of: find.byKey(aiAgentSessionRowKey('s1')),
          matching: find.text(t.ai_agent_new_session),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(aiAgentSessionRowKey('s2')),
          matching: find.textContaining(t.ai_agent_session_current),
        ),
        findsOneWidget,
      );
      expect(find.text(t.ai_agent_sessions_retention_hint), findsOneWidget);

      await tester.tap(find.text(t.ai_agent_new_session).last);
      await tester.pumpAndSettle();
      expect(library.calls, <String>['switch:s1']);
      expect(library.currentSessionId, 's1');
      expect(chosen, 1);
    });

    testWidgets('$ds：行尾菜单重命名 / 删除（删除先确认，取消不删）', (WidgetTester tester) async {
      final _FakeLibrary library = _FakeLibrary(<AiAgentSessionSummary>[
        _summary('s2', '整理书架', 2000),
        _summary('s1', '调字幕', 1000),
      ], currentSessionId: 's2');
      addTearDown(library.dispose);
      await pumpList(tester, library, apple: apple);

      // 重命名：菜单 → 对话框预填旧标题 → 改名确认。
      await tester.tap(find.byKey(aiAgentSessionMenuKey('s1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.ai_agent_session_rename).last);
      await tester.pumpAndSettle();
      expect(find.text(t.ai_agent_session_rename_title), findsOneWidget);
      expect(find.widgetWithText(EditableText, '调字幕'), findsOneWidget);
      await tester.enterText(find.byType(EditableText), '字幕设置');
      await tester.tap(find.text(t.ai_agent_session_rename).last);
      await tester.pumpAndSettle();
      expect(library.calls, <String>['rename:s1:字幕设置']);
      expect(find.text('字幕设置'), findsOneWidget);

      // 删除：确认框里点取消 → 不删。
      await tester.tap(find.byKey(aiAgentSessionMenuKey('s2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.ai_agent_session_delete).last);
      await tester.pumpAndSettle();
      expect(find.text(t.ai_agent_session_delete_title), findsOneWidget);
      expect(
        find.text(t.ai_agent_session_delete_message(title: '整理书架')),
        findsOneWidget,
      );
      await tester.tap(find.text(t.cancel));
      await tester.pumpAndSettle();
      expect(library.calls, <String>['rename:s1:字幕设置']);
      expect(find.byKey(aiAgentSessionRowKey('s2')), findsOneWidget);

      // 再来一次点删除：当前这场被删，列表里只剩另一场，置顶「新对话 · 当前」。
      await tester.tap(find.byKey(aiAgentSessionMenuKey('s2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.ai_agent_session_delete).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.ai_agent_session_delete).last);
      await tester.pumpAndSettle();
      expect(library.calls.last, 'delete:s2');
      expect(find.byKey(aiAgentSessionRowKey('s2')), findsNothing);
      expect(find.byKey(aiAgentSessionRowKey('s1')), findsOneWidget);
      expect(find.byKey(kAiAgentSessionsDraftKey), findsOneWidget);
    });

    testWidgets('$ds：一轮在跑时不切换 / 不新建；没有会话时显示空态', (WidgetTester tester) async {
      final _FakeLibrary library = _FakeLibrary(<AiAgentSessionSummary>[
        _summary('s1', '调字幕', 1000),
      ], currentSessionId: null);
      addTearDown(library.dispose);
      await pumpList(tester, library, apple: apple);
      expect(find.byKey(kAiAgentSessionsDraftKey), findsOneWidget);

      library.running = true;
      await tester.pumpAndSettle();
      await tester.tap(find.text('调字幕'), warnIfMissed: false);
      await tester.tap(find.byKey(kAiAgentSessionsNewKey), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(library.calls, isEmpty);

      library.running = false;
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAiAgentSessionsNewKey));
      await tester.pumpAndSettle();
      expect(library.calls, <String>['new']);

      // 存档全没了、当前这场也已落库（不画「新对话」行）：显示空态。
      library.sessions.clear();
      library.currentSessionId = 'gone';
      library.bump();
      await tester.pumpAndSettle();
      expect(find.text(t.ai_agent_sessions_empty), findsOneWidget);
      expect(find.byKey(aiAgentSessionRowKey('s1')), findsNothing);
    });
  }
}
