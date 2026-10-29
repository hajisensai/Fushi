import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/download/manga_download_service.dart';
import 'package:fushi/src/media/manga/online/mokuro_moe_catalog_view.dart';
import 'package:fushi/src/media/manga/online/mokuro_moe_client.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

class _FakeClient extends MokuroMoeClient {
  @override
  Future<List<MokuroMoeSeries>> fetchLibrary() async => const <MokuroMoeSeries>[
    MokuroMoeSeries(
      name: 'よつばと!',
      volumes: <MokuroMoeVolume>[MokuroMoeVolume(name: '第01巻')],
    ),
  ];
}

/// 回归：从发现页 / 来源页 push 出来的 mokuro.moe 目录页，在系列阶段按返回
/// （页头箭头与系统返回都走 `Navigator.maybePop`）应先回到系列列表，
/// 而不是直接 pop 整页回到发现页。
void main() {
  testWidgets('系列阶段返回先回到浏览，再返回才离开目录页', (WidgetTester tester) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final MangaDownloadService service = MangaDownloadService(
      database: db,
      serviceFor: (_) => throw UnimplementedError(),
      wait: (_) async {},
    );
    addTearDown(service.dispose);
    await service.start();

    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navKey,
            home: const Scaffold(body: Text('discover')),
          ),
        ),
      ),
    );
    navKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: MokuroMoeCatalogView(
            db: db,
            embedded: true,
            clientOverride: _FakeClient(),
            downloadsOverride: service,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('よつばと!'));
    await tester.pumpAndSettle();
    expect(find.text('第01巻'), findsOneWidget);

    // 第一次返回：留在目录页，回到系列列表。
    await navKey.currentState!.maybePop();
    await tester.pumpAndSettle();
    expect(find.text('discover'), findsNothing);
    expect(find.text('第01巻'), findsNothing);
    expect(find.text('よつばと!'), findsOneWidget);

    // 第二次返回：才真正离开目录页。
    await navKey.currentState!.maybePop();
    await tester.pumpAndSettle();
    expect(find.text('discover'), findsOneWidget);
  });
}
