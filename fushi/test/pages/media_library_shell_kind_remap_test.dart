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
  late Map<MediaLibraryViewKind, int> inits;

  MediaLibraryViewSpec spec(MediaLibraryViewKind kind) => MediaLibraryViewSpec(
    kind: kind,
    label: kind.name,
    builder: (BuildContext context, Widget navigation) {
      builds[kind] = (builds[kind] ?? 0) + 1;
      return Center(
        child: _InitProbe(
          onInit: () => inits[kind] = (inits[kind] ?? 0) + 1,
          child: Text('view:${kind.name}'),
        ),
      );
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

  /// 走壳自己的 UI 入口切视图：「导入」是工具栏右端的切换型圆钮（不是页签）；
  /// 其余视图走页签（「我的」组只剩一组时一级不画，组内二级胶囊只在停在组内时
  /// 出现，所以从导入页先点导入钮回到组内再切）。
  Future<void> select(WidgetTester tester, MediaLibraryViewKind kind) async {
    final Finder importFinder = find.byKey(
      const ValueKey<String>('remap-shell-import'),
    );
    FushiIconButton importButton() => tester.widget(importFinder);
    if (kind == MediaLibraryViewKind.sources) {
      if (importButton().selected != true) importButton().onTap!();
      await tester.pumpAndSettle();
      return;
    }
    if (importButton().selected == true) {
      importButton().onTap!();
      await tester.pumpAndSettle();
    }
    final Finder strips = find.byType(FushiSectionTabBar<MediaLibraryViewKind>);
    if (strips.evaluate().isNotEmpty) {
      tester
          .widget<FushiSectionTabBar<MediaLibraryViewKind>>(strips.first)
          .onChanged!(kind);
    }
    await tester.pumpAndSettle();
  }

  setUp(() {
    builds = <MediaLibraryViewKind, int>{};
    inits = <MediaLibraryViewKind, int>{};
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
    // 「导入」经工具栏圆钮进出（不再是页签）：从导入页去媒体服务器要先点导入钮
    // 回到书架、再切二级胶囊，比旧路径多一步壳切换，builder 随外层重建多取一次。
    expect(
      builds[MediaLibraryViewKind.sources]! - sourcesBuilds,
      lessThanOrEqualTo(4),
      reason: '只是随外层重建被 builder 重新取了几次，没有丢状态重来',
    );
    expect(
      inits[MediaLibraryViewKind.library],
      1,
      reason: '下标没动的书架视图 State 一直保活',
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

/// 视图内容：`initState` 只在首次构造时跑，用来验保活（切走再切回不重建）。
class _InitProbe extends StatefulWidget {
  const _InitProbe({required this.onInit, required this.child});

  final VoidCallback onInit;
  final Widget child;

  @override
  State<_InitProbe> createState() => _InitProbeState();
}

class _InitProbeState extends State<_InitProbe> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
