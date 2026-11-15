// 反馈 ML86fiSYBk：待发卡片（703 张全部失败）只能逐张删。页头加「全部删除」与
// 「删除发送失败的卡片」两个批量动作，确认框写明张数。
// 真实 PendingMinesPage + 真实 AppModel + 内存 Drift 库，直接往 pending_mine_queue
// 插行；只验动作露出与确认框（取消不删），删除语义见 pending_mine_relay_test 的
// discardAll 组。
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/anki/pending_mining/pending_mines_page.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

class _InertAnki implements BaseAnkiRepository {
  @override
  bool get switchesAppPerNote => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const ValueKey<String> _deleteAllKey = ValueKey<String>(
  'pending-mines-delete-all',
);
const ValueKey<String> _deleteFailedKey = ValueKey<String>(
  'pending-mines-delete-failed',
);

Future<FushiDatabase> _pumpPage(
  WidgetTester tester, {
  required List<String> statuses,
}) async {
  LocaleSettings.setLocale(AppLocale.en);
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  for (int i = 0; i < statuses.length; i++) {
    await db
        .into(db.pendingMineQueue)
        .insert(
          PendingMineQueueCompanion.insert(
            id: 'card$i',
            createdAt: i,
            expression: '語$i',
            status: Value<String>(statuses[i]),
            lastError: Value<String?>(
              statuses[i] == PendingMineStatus.failed ? 'Unknown URL' : null,
            ),
          ),
        );
  }
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
  return db;
}

Future<void> _disposePage(WidgetTester tester) async {
  // 内存库关闭前先卸载页面（队列订阅随之取消）。
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('空队列：不露批量删除', (WidgetTester tester) async {
    await _pumpPage(tester, statuses: const <String>[]);
    expect(find.text(t.anki_pending_mines_empty), findsOneWidget);
    expect(find.byKey(_deleteAllKey), findsNothing);
    expect(find.byKey(_deleteFailedKey), findsNothing);
    await _disposePage(tester);
  });

  testWidgets('全是失败卡：只露「全部删除」（两个按钮会删同一批）', (WidgetTester tester) async {
    await _pumpPage(
      tester,
      statuses: const <String>[
        PendingMineStatus.failed,
        PendingMineStatus.failed,
        PendingMineStatus.failed,
      ],
    );
    expect(find.byKey(_deleteAllKey), findsOneWidget);
    expect(find.byKey(_deleteFailedKey), findsNothing);

    await tester.tap(find.byKey(_deleteAllKey));
    await tester.pumpAndSettle();
    expect(
      find.text(t.anki_pending_mines_delete_all_confirm(n: 3)),
      findsOneWidget,
      reason: '确认框写明要删的张数',
    );
    await tester.tap(find.text(t.cancel));
    await tester.pumpAndSettle();
    expect(find.text('語0'), findsOneWidget, reason: '取消不删');
    await _disposePage(tester);
  });

  testWidgets('失败与待发混在一起：两个批量动作都露，「删除发送失败的」只数失败卡', (WidgetTester tester) async {
    final FushiDatabase db = await _pumpPage(
      tester,
      statuses: const <String>[
        PendingMineStatus.failed,
        PendingMineStatus.pending,
        PendingMineStatus.failed,
      ],
    );
    expect(find.byKey(_deleteAllKey), findsOneWidget);
    expect(find.byKey(_deleteFailedKey), findsOneWidget);

    await tester.tap(find.byKey(_deleteFailedKey));
    await tester.pumpAndSettle();
    expect(
      find.text(t.anki_pending_mines_delete_failed_confirm(n: 2)),
      findsOneWidget,
    );
    await tester.tap(find.text(t.cancel));
    await tester.pumpAndSettle();
    expect(await db.select(db.pendingMineQueue).get(), hasLength(3));
    await _disposePage(tester);
  });
}
