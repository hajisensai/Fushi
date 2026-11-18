import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/section_deferred_build.dart';
import 'package:fushi/src/utils/components/section_visibility.dart';

/// BUG-4848：保活分区里的页面藏着时不重建，切回可见时有欠账才补一次。
///
/// 起因是实测：首页切回时失效书列表 provider，藏着的书架与漫画书架各跟着整页
/// 重建四次（每次 7～30 ms），用户看到「回首页卡一下」。这里钉死
/// [SectionDeferredBuild] 的契约——用的是真 provider、真 InheritedWidget、真
/// `setState`，数的是页面 State 真正被调 `build` 的次数。
final StateProvider<int> _counter = StateProvider<int>((Ref ref) => 0);

class _Page extends ConsumerStatefulWidget with SectionDeferredBuild {
  const _Page({required this.label});

  final String label;

  @override
  ConsumerState<_Page> createState() => _PageState();
}

class _PageState extends ConsumerState<_Page> {
  int builds = 0;
  int dependencyChanges = 0;
  int local = 0;
  final List<int> listened = <int>[];

  void bump() => setState(() => local++);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    dependencyChanges++;
  }

  @override
  Widget build(BuildContext context) {
    builds++;
    ref.listen<int>(_counter, (int? _, int next) => listened.add(next));
    final int value = ref.watch(_counter);
    // 依赖一个与可见性无关的 InheritedWidget：它变了要记欠账。
    final TextDirection direction = Directionality.of(context);
    return Text(
      '${widget.label}:$value:$local:${direction.name}',
      textDirection: TextDirection.ltr,
    );
  }
}

/// 普通页面（没混 [SectionDeferredBuild]）：对照「修之前」的行为。
class _PlainPage extends ConsumerStatefulWidget {
  const _PlainPage();

  @override
  ConsumerState<_PlainPage> createState() => _PlainPageState();
}

class _PlainPageState extends ConsumerState<_PlainPage> {
  int builds = 0;

  @override
  Widget build(BuildContext context) {
    builds++;
    return Text('${ref.watch(_counter)}', textDirection: TextDirection.ltr);
  }
}

Widget _host({
  required bool visible,
  required Widget page,
  TextDirection direction = TextDirection.ltr,
}) => Directionality(
  textDirection: direction,
  child: Offstage(
    offstage: !visible,
    child: TickerMode(
      enabled: visible,
      child: SectionVisibilityScope(visible: visible, child: page),
    ),
  ),
);

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  Future<void> pump(
    WidgetTester tester, {
    required bool visible,
    Widget page = const _Page(label: 'a'),
    TextDirection direction = TextDirection.ltr,
  }) => tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: _host(visible: visible, page: page, direction: direction),
    ),
  );

  _PageState stateOf(WidgetTester tester) =>
      tester.state<_PageState>(find.byType(_Page, skipOffstage: false));

  testWidgets('对照：没混 SectionDeferredBuild 的页面藏着时照样跟着 provider 重建', (
    WidgetTester tester,
  ) async {
    await pump(tester, visible: true, page: const _PlainPage());
    await pump(tester, visible: false, page: const _PlainPage());
    final _PlainPageState state = tester.state<_PlainPageState>(
      find.byType(_PlainPage, skipOffstage: false),
    );
    final int before = state.builds;

    container.read(_counter.notifier).state = 1;
    await tester.pump();

    expect(state.builds, before + 1, reason: '这就是要修掉的行为：藏着的页面白白重建。');
  });

  testWidgets('藏着时 provider 变了不重建；ref.listen 照常触发；切回只补一次', (
    WidgetTester tester,
  ) async {
    await pump(tester, visible: true);
    final _PageState state = stateOf(tester);
    expect(state.builds, 1);

    await pump(tester, visible: false);
    expect(state.builds, 1, reason: '只是被藏起来，不构成重建理由。');

    container.read(_counter.notifier).state = 1;
    await tester.pump();
    container.read(_counter.notifier).state = 2;
    await tester.pump();
    container.read(_counter.notifier).state = 3;
    await tester.pump();
    expect(state.builds, 1, reason: '藏着的页面不跟着 provider 重建。');
    expect(state.listened, <int>[
      1,
      2,
      3,
    ], reason: '订阅不能断：ref.listen 的回调在藏着时也要逐次收到。');
    expect(find.text('a:0:0:ltr', skipOffstage: false), findsOneWidget);

    await pump(tester, visible: true);
    expect(state.builds, 2, reason: '切回可见时把欠着的那次补上，且只补一次。');
    expect(find.text('a:3:0:ltr'), findsOneWidget);

    // 补完之后订阅仍然有效。
    container.read(_counter.notifier).state = 4;
    await tester.pump();
    expect(state.builds, 3);
    expect(find.text('a:4:0:ltr'), findsOneWidget);
  });

  testWidgets('没欠账时来回藏 / 显不重建', (WidgetTester tester) async {
    await pump(tester, visible: true);
    final _PageState state = stateOf(tester);

    for (int i = 0; i < 3; i++) {
      await pump(tester, visible: false);
      await pump(tester, visible: true);
    }

    expect(state.builds, 1, reason: '只因可见性翻转被叫起来不算构建理由——切 tab 的那一帧不该多一次整页构建。');
  });

  testWidgets('藏着时的 setState、父级换 widget、其它依赖变化都记欠账，切回补一次', (
    WidgetTester tester,
  ) async {
    await pump(tester, visible: true);
    final _PageState state = stateOf(tester);
    await pump(tester, visible: false);

    state.bump();
    await tester.pump();
    expect(state.builds, 1);

    await pump(tester, visible: false, page: const _Page(label: 'b'));
    expect(state.builds, 1);
    expect(state.widget.label, 'b', reason: 'State 照常拿到新 widget，只是不构建。');

    final int dependencyChangesBefore = state.dependencyChanges;
    await pump(
      tester,
      visible: false,
      page: const _Page(label: 'b'),
      direction: TextDirection.rtl,
    );
    expect(state.builds, 1);
    expect(
      state.dependencyChanges,
      dependencyChangesBefore + 1,
      reason: 'State.didChangeDependencies 在藏着时也要照常被调用。',
    );

    await pump(
      tester,
      visible: true,
      page: const _Page(label: 'b'),
      direction: TextDirection.rtl,
    );
    expect(state.builds, 2, reason: '三笔欠账合成一次构建。');
    expect(find.text('b:0:1:rtl'), findsOneWidget);
  });

  testWidgets('可见性翻转与别的依赖在同一帧一起变：切回那一帧照样重建', (WidgetTester tester) async {
    await pump(tester, visible: true);
    final _PageState state = stateOf(tester);
    await pump(tester, visible: false);
    expect(state.builds, 1);

    await pump(tester, visible: true, direction: TextDirection.rtl);

    expect(state.builds, 2, reason: '不能把「另一个依赖变了」当成可见性翻转吞掉，否则切回来是旧内容。');
    expect(find.text('a:0:0:rtl'), findsOneWidget);
  });

  testWidgets('可见时与普通页面一样：每个构建请求都当帧兑现', (WidgetTester tester) async {
    await pump(tester, visible: true);
    final _PageState state = stateOf(tester);

    container.read(_counter.notifier).state = 1;
    await tester.pump();
    state.bump();
    await tester.pump();

    expect(state.builds, 3);
    expect(find.text('a:1:1:ltr'), findsOneWidget);
  });

  testWidgets('不在任何分区里（独立路由 / 组件测试）时行为不变', (WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: _Page(label: 'a'),
        ),
      ),
    );
    final _PageState state = stateOf(tester);

    container.read(_counter.notifier).state = 1;
    await tester.pump();

    expect(state.builds, 2);
    expect(find.text('a:1:0:ltr'), findsOneWidget);
  });

  testWidgets('外层分区藏着、内层分区是当前视图：同样不重建', (WidgetTester tester) async {
    Widget nested({required bool outer}) => UncontrolledProviderScope(
      container: container,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: SectionVisibilityScope(
          visible: outer,
          child: const SectionVisibilityScope(
            visible: true,
            child: _Page(label: 'a'),
          ),
        ),
      ),
    );
    await tester.pumpWidget(nested(outer: true));
    final _PageState state = stateOf(tester);
    await tester.pumpWidget(nested(outer: false));

    container.read(_counter.notifier).state = 1;
    await tester.pump();
    expect(state.builds, 1);

    await tester.pumpWidget(nested(outer: true));
    expect(state.builds, 2);
    expect(find.text('a:1:0:ltr'), findsOneWidget);
  });
}
