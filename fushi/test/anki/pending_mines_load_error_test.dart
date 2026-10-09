// BUG-2996（HBK-AUDIT-044）：待发卡片页首次 store.all() 抛异常时，_loaded 永远
// 不置 true，骨架屏常驻、异常未处理、没有错误说明也没有重试入口。
// 真实 PendingMinesPage + 真实 AppModel + 新建内存 Drift 库，只经 Drift 拦截器
// 给 pending_mine_queue 的 SELECT 注入失败；不碰用户库与 Anki。
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/anki/pending_mining/pending_mines_page.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/utils.dart'
    show FushiPlaceholderMessage, FushiPlaceholderTone;
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

class _QueueReadFault extends QueryInterceptor {
  bool fail = false;
  int failures = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (fail && statement.toLowerCase().contains('pending_mine_queue')) {
      failures++;
      throw StateError('injected pending queue read failure');
    }
    return executor.runSelect(statement, args);
  }
}

class _InertAnki implements BaseAnkiRepository {
  @override
  bool get switchesAppPerNote => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<_QueueReadFault> _pumpPage(
  WidgetTester tester, {
  required bool fail,
}) async {
  LocaleSettings.setLocale(AppLocale.en);
  final _QueueReadFault fault = _QueueReadFault();
  final FushiDatabase db = FushiDatabase.forTesting(
    NativeDatabase.memory().interceptWith(fault),
  );
  addTearDown(db.close);
  // 先成功打开并迁移，再武装故障：只让读队列失败。
  await db.customSelect('SELECT 1').get();
  fault.fail = fail;
  final AppModel app = AppModel(testPlatformServices())
    ..wireDatabaseForTesting(db);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appProvider.overrideWith((Ref ref) => app),
        ankiRepositoryProvider.overrideWithValue(_InertAnki()),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: const PendingMinesPage(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fault;
}

Future<void> _disposePage(WidgetTester tester) async {
  // 内存库关闭前先卸载页面（队列订阅随之取消）。
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('对照：空队列读表成功 → 结束骨架、显示空态', (WidgetTester tester) async {
    final _QueueReadFault fault = await _pumpPage(tester, fail: false);
    expect(tester.takeException(), isNull);
    expect(fault.failures, 0);
    expect(find.byType(FushiSkeletonShimmer), findsNothing);
    expect(find.text(t.anki_pending_mines_empty), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('pending-mines-load-retry')),
      findsNothing,
    );
    await _disposePage(tester);
  });

  testWidgets('首次读表失败 → 结束骨架、错误态 + 重试；恢复后重试回到空态', (WidgetTester tester) async {
    final _QueueReadFault fault = await _pumpPage(tester, fail: true);
    expect(tester.takeException(), isNull, reason: '读表异常必须被页面接住');
    expect(fault.failures, greaterThan(0));
    expect(find.byType(FushiSkeletonShimmer), findsNothing);
    expect(find.text(t.error_load_failed), findsOneWidget);
    final Finder retry = find.byKey(
      const ValueKey<String>('pending-mines-load-retry'),
    );
    expect(retry, findsOneWidget);
    final Finder placeholder = find.ancestor(
      of: retry,
      matching: find.byType(FushiPlaceholderMessage),
    );
    expect(placeholder, findsOneWidget);
    expect(
      tester.widget<FushiPlaceholderMessage>(placeholder).tone,
      FushiPlaceholderTone.error,
      reason: '错误态走共享 FushiPlaceholderMessage 的 error 色调',
    );

    fault.fail = false;
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(FushiSkeletonShimmer), findsNothing);
    expect(find.text(t.error_load_failed), findsNothing);
    expect(find.text(t.anki_pending_mines_empty), findsOneWidget);
    await _disposePage(tester);
  });
}
