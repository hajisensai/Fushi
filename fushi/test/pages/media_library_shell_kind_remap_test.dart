// 媒体库壳按 kind（而不是下标）记住选中的视图：「媒体服务器」标签随增删服务器出现在
// 视图列表中间时，已选中的视图不能被下标错位顶掉，保活的访问记录也要跟着重新定位。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/media_library_shell.dart';
import 'package:fushi/utils.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  late ValueNotifier<List<MediaLibraryViewKind>> kinds;
  late Map<MediaLibraryViewKind, int> builds;

  MediaLibraryViewSpec spec(MediaLibraryViewKind kind) => MediaLibraryViewSpec(
    kind: kind,
    label: kind.name,
    builder: (BuildContext context, Widget navigation) {
      builds[kind] = (builds[kind] ?? 0) + 1;
      return Center(child: Text('view:${kind.name}'));
    },
  );

  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 1200);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<List<MediaLibraryViewKind>>(
              valueListenable: kinds,
              builder:
                  (BuildContext context, List<MediaLibraryViewKind> value, _) =>
                      MediaLibraryShell(
                        focusIdPrefix: 'remap-shell',
                        views: <MediaLibraryViewSpec>[
                          for (final MediaLibraryViewKind kind in value)
                            spec(kind),
                        ],
                      ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> select(WidgetTester tester, MediaLibraryViewKind kind) async {
    tester
        .widget<FushiSectionTabBar<MediaLibraryViewKind>>(
          find.byType(FushiSectionTabBar<MediaLibraryViewKind>),
        )
        .onChanged!(kind);
    await tester.pumpAndSettle();
  }

  setUp(() {
    builds = <MediaLibraryViewKind, int>{};
    kinds = ValueNotifier<List<MediaLibraryViewKind>>(<MediaLibraryViewKind>[
      MediaLibraryViewKind.library,
      MediaLibraryViewKind.sources,
    ]);
  });
  tearDown(() => kinds.dispose());

  testWidgets('选中「导入」后，「媒体服务器」出现在中间：仍停在「导入」', (WidgetTester tester) async {
    await pumpShell(tester);
    await select(tester, MediaLibraryViewKind.sources);
    expect(find.text('view:sources'), findsOneWidget);

    kinds.value = <MediaLibraryViewKind>[
      MediaLibraryViewKind.library,
      MediaLibraryViewKind.mediaServers,
      MediaLibraryViewKind.sources,
    ];
    await tester.pumpAndSettle();

    expect(
      find.text('view:sources'),
      findsOneWidget,
      reason: '下标 1 变成了「媒体服务器」，选中项必须跟着 kind 走到下标 2',
    );
    expect(find.text('view:mediaServers'), findsNothing);
    expect(
      builds.containsKey(MediaLibraryViewKind.mediaServers),
      isFalse,
      reason: '没访问过的新标签不提前构建',
    );
  });

  testWidgets('访问过的保活视图跟着 kind 重新定位，不重复构建', (WidgetTester tester) async {
    await pumpShell(tester);
    await select(tester, MediaLibraryViewKind.sources);
    final int sourcesBuilds = builds[MediaLibraryViewKind.sources]!;

    kinds.value = <MediaLibraryViewKind>[
      MediaLibraryViewKind.library,
      MediaLibraryViewKind.mediaServers,
      MediaLibraryViewKind.sources,
    ];
    await tester.pumpAndSettle();
    // 切到新出现的标签，再切回「导入」：「导入」应仍被保活（没被当成没访问过）。
    await select(tester, MediaLibraryViewKind.mediaServers);
    expect(find.text('view:mediaServers'), findsOneWidget);
    await select(tester, MediaLibraryViewKind.sources);
    expect(find.text('view:sources'), findsOneWidget);
    expect(find.text('view:library', skipOffstage: false), findsOneWidget);
    expect(
      builds[MediaLibraryViewKind.sources]! - sourcesBuilds,
      lessThanOrEqualTo(3),
      reason: '只是随外层重建被 builder 重新取了几次，没有丢状态重来',
    );
  });

  testWidgets('正在看的「媒体服务器」标签消失（删掉最后一台）：回到第一个视图', (WidgetTester tester) async {
    kinds.value = <MediaLibraryViewKind>[
      MediaLibraryViewKind.library,
      MediaLibraryViewKind.mediaServers,
      MediaLibraryViewKind.sources,
    ];
    await pumpShell(tester);
    await select(tester, MediaLibraryViewKind.mediaServers);
    expect(find.text('view:mediaServers'), findsOneWidget);

    kinds.value = <MediaLibraryViewKind>[
      MediaLibraryViewKind.library,
      MediaLibraryViewKind.sources,
    ];
    await tester.pumpAndSettle();

    expect(find.text('view:library'), findsOneWidget);
    expect(find.text('view:sources'), findsNothing);
  });

  testWidgets('视图集合没变：选中项原样不动', (WidgetTester tester) async {
    await pumpShell(tester);
    await select(tester, MediaLibraryViewKind.sources);
    kinds.value = List<MediaLibraryViewKind>.of(kinds.value);
    await tester.pumpAndSettle();
    expect(find.text('view:sources'), findsOneWidget);
  });
}
