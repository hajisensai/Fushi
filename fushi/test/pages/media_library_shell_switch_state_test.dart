import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/pages/implementations/media_library_shell.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show
        FushiFloatingChromeController,
        FushiFloatingChromeInset,
        FushiFloatingChromeScope;

/// BUG-4897：库页「书架 / 在线」切换时页头与内容状态错位、点下去要等。
///
/// 录屏现象：从「在线」切回滚到中段的「书架」，第一帧是展开的大号页头压在按旧
/// 滚动位置画的书架内容上，下一帧页头才缩回小号。根因是浮动工具栏状态（显隐 /
/// 页头大字折叠进度 / 遮罩）全壳共用一份，切视图时被 `resetToTop()` 重置成「顶部」，
/// 而保活视图的滚动位置并没有回顶。修法：每个视图各自持有一份工具栏状态，切换即
/// 换成该视图自己的那份。另一半（点下去约 0.5 秒才切）是每次切换都把所有保活
/// 视图重新 build 一遍；现在视图内容按种类缓存，切换不重建。
///
/// 全程焦点驱动：分区导航的焦点停靠点 + 方向键左右切视图（禁 tester.tap）。
void main() {
  const FushiFocusId sectionsId = FushiFocusId('switch-state-test-sections');

  late ScrollController libraryScroll;
  late Map<MediaLibraryViewKind, int> buildCount;

  Widget scrollingView(
    BuildContext context,
    String label, {
    ScrollController? controller,
  }) {
    return CustomScrollView(
      controller: controller,
      slivers: <Widget>[
        // 视图自己让出浮动工具区高度（handlesChromeInset）。
        SliverToBoxAdapter(
          child: SizedBox(height: FushiFloatingChromeInset.of(context)),
        ),
        SliverList.builder(
          itemCount: 60,
          itemBuilder: (BuildContext context, int i) => SizedBox(
            key: ValueKey<String>('$label-$i'),
            height: 80,
            child: Text('$label $i'),
          ),
        ),
      ],
    );
  }

  MediaLibraryViewSpec spec(MediaLibraryViewKind kind, String label) =>
      MediaLibraryViewSpec(
        kind: kind,
        label: label,
        handlesChromeInset: true,
        builder: (BuildContext context, Widget navigation) {
          buildCount[kind] = (buildCount[kind] ?? 0) + 1;
          return Builder(
            builder: (BuildContext context) => scrollingView(
              context,
              label,
              controller: kind == MediaLibraryViewKind.library
                  ? libraryScroll
                  : null,
            ),
          );
        },
      );

  Widget harness() => MaterialApp(
    home: Scaffold(
      body: FushiFocusRoot(
        child: MediaLibraryShell(
          focusIdPrefix: 'switch-state-test',
          views: <MediaLibraryViewSpec>[
            spec(MediaLibraryViewKind.library, 'shelf'),
            spec(MediaLibraryViewKind.discover, 'online'),
          ],
        ),
      ),
    ),
  );

  setUp(() {
    libraryScroll = ScrollController();
    buildCount = <MediaLibraryViewKind, int>{};
  });

  tearDown(() => libraryScroll.dispose());

  /// 书架的主滚动视图（隐藏时也在树上）。
  Finder shelfScrollView() => find.byWidgetPredicate(
    (Widget w) => w is CustomScrollView && w.controller == libraryScroll,
    skipOffstage: false,
  );

  /// 此刻壳作用域里挂着的工具栏 controller。
  FushiFloatingChromeController scopeChrome(WidgetTester tester) =>
      FushiFloatingChromeScope.peek(tester.element(shelfScrollView()))!;

  /// 书架内容所在 [FadeTransition]（壳切视图的淡入）此刻的不透明度。
  double shelfOpacity(WidgetTester tester) => tester
      .widget<FadeTransition>(
        find
            .ancestor(
              of: shelfScrollView(),
              matching: find.byType(FadeTransition, skipOffstage: false),
            )
            .first,
      )
      .opacity
      .value;

  /// 在线视图第一行所在 [FadeTransition]（离开时的淡出）此刻的不透明度。
  double onlineOpacity(WidgetTester tester) => tester
      .widget<FadeTransition>(
        find
            .ancestor(
              of: find.text('online 0', skipOffstage: false),
              matching: find.byType(FadeTransition, skipOffstage: false),
            )
            .first,
      )
      .opacity
      .value;

  /// 在线视图是否被壳挡掉指针（非当前视图一律挡掉）。
  bool onlineIgnoresPointer(WidgetTester tester) => tester
      .widget<IgnorePointer>(
        find
            .ancestor(
              of: find.text('online 0', skipOffstage: false),
              // 壳包在视图外的那一层（Scrollable 自己也有 IgnorePointer）。
              matching: find.byWidgetPredicate(
                (Widget w) => w is IgnorePointer && w.child is ExcludeSemantics,
                skipOffstage: false,
              ),
            )
            .first,
      )
      .ignoring;

  Future<void> focusSections(WidgetTester tester) async {
    // 不建立依赖（listen: false）：`controllerOf` 会让壳的 Element 订阅焦点
    // controller，之后每次焦点移动都触发壳的 didChangeDependencies、作废视图缓存
    // ——那是测试自己挂上去的依赖（壳本身不订阅焦点），会把「切视图不重建」数成 2。
    final FushiFocusController focus = FushiFocusRoot.maybeControllerOf(
      tester.element(find.byType(MediaLibraryShell)),
      listen: false,
    )!;
    expect(focus.requestById(sectionsId), isTrue);
    await tester.pump();
  }

  testWidgets('从在线切回滚到中段的书架：首帧页头折叠状态就是书架自己的，内容不动', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    await focusSections(tester);

    // 书架往下滚一段：页头大字随之折叠，内容滚到工具区底下。
    libraryScroll.jumpTo(400);
    await tester.pumpAndSettle();
    final FushiFloatingChromeController shelfChrome = scopeChrome(tester);
    final double shelfMasthead = shelfChrome.mastheadScrollOffset.value;
    expect(shelfMasthead, greaterThan(0), reason: '书架滚离顶部，页头应已开始折叠');
    expect(shelfChrome.contentUnderTop, isTrue);

    // 切到「在线」：在线视图从没滚过，页头是它自己的展开态。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    final FushiFloatingChromeController onlineChrome = scopeChrome(tester);
    expect(onlineChrome, isNot(same(shelfChrome)), reason: '每个视图各自一份工具栏状态');
    expect(onlineChrome.mastheadScrollOffset.value, 0);
    expect(onlineChrome.contentUnderTop, isFalse);

    // 切回「书架」，只推一帧：这一帧就必须是书架自己的折叠进度，不能先按「顶部」
    // 画一个展开的大号页头压在中段内容上、下一帧再纠正。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    final FushiFloatingChromeController back = scopeChrome(tester);
    expect(back, same(shelfChrome));
    expect(
      back.mastheadScrollOffset.value,
      shelfMasthead,
      reason: '切回首帧页头折叠进度 = 书架停下时的进度（与它保留的滚动位置一致）',
    );
    expect(back.contentUnderTop, isTrue);
    expect(back.visible, isTrue, reason: '用户刚在工具栏上切换，工具栏要亮着');
    expect(libraryScroll.offset, 400, reason: '书架内容保留自己的滚动位置，不跳回顶部');
    // 切换是交叉淡入，不硬切：首帧新视图还没完全显出来，刚离开的在线视图还在台上
    // 淡出，但已不收指针。
    expect(shelfOpacity(tester), lessThan(1));
    expect(find.text('online 0'), findsOneWidget, reason: '离开的视图在台上画淡出');
    expect(onlineOpacity(tester), greaterThan(0));
    expect(onlineIgnoresPointer(tester), isTrue);

    await tester.pumpAndSettle();
    expect(shelfOpacity(tester), 1);
    expect(find.text('online 0'), findsNothing, reason: '淡出结束后回到 Offstage 保活');
    expect(back.mastheadScrollOffset.value, shelfMasthead);
    expect(libraryScroll.offset, 400);
    expect(tester.takeException(), isNull);
  });

  testWidgets('切视图不重建保活视图（切换那一帧不再整页重建书架 / 在线页）', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    await focusSections(tester);
    expect(buildCount[MediaLibraryViewKind.library], 1);

    for (int round = 0; round < 3; round++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
    }

    expect(
      buildCount[MediaLibraryViewKind.library],
      1,
      reason: '书架 builder 只在首次访问时调一次，切换复用同一份 widget',
    );
    expect(buildCount[MediaLibraryViewKind.discover], 1);
    expect(tester.takeException(), isNull);
  });
}
