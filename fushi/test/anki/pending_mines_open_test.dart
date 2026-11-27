// 应用内反馈 OElRvCndxk：「打开待发卡片」的唯一落点 openPendingMinesPage（Anki 设置页入口、
// 「已加入待发队列」提示上的「查看队列」、全局快捷键共用）。连按快捷键不能越推越深：列表已在
// 栈顶时不再叠一份。真实 PendingMinesPage + 真实 AppModel + 内存 Drift 库，不碰用户库与 Anki。
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('推一次待发卡片列表；已在栈顶时再开不叠第二份；navigator 没起来时不认领', (
    WidgetTester tester,
  ) async {
    LocaleSettings.setLocale(AppLocale.en);
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final AppModel app = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db);
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appProvider.overrideWith((Ref ref) => app),
          ankiRepositoryProvider.overrideWithValue(_InertAnki()),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navKey,
            theme: ThemeData(useMaterial3: true),
            builder: (BuildContext context, Widget? child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
            home: const Scaffold(body: Text('player')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(openPendingMinesPage(null), isFalse);

    expect(openPendingMinesPage(navKey.currentState), isTrue);
    await tester.pumpAndSettle();
    expect(find.byType(PendingMinesPage), findsOneWidget);
    expect(find.text(t.anki_pending_mines_empty), findsOneWidget);

    expect(openPendingMinesPage(navKey.currentState), isTrue);
    await tester.pumpAndSettle();
    expect(
      find.byType(PendingMinesPage, skipOffstage: false),
      findsOneWidget,
      reason: '已在栈顶：不再叠一份',
    );

    // 退回去只要一步就回到原来的页面。
    navKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byType(PendingMinesPage, skipOffstage: false), findsNothing);
    expect(find.text('player'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
