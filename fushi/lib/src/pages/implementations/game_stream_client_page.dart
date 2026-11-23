import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/texthooker_page.dart';
import 'package:fushi/src/pages/shared/library_section_tabs.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_scroll_chrome.dart'
    show fushiNotificationDrivesPageChrome;
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart'
    show FushiShellActionsSlot, FushiShellTitleScope;
import 'package:fushi/src/utils/components/library_section_tab.dart';
import 'package:material_ui/material_ui.dart';

/// 非 Windows 桌面 games 模块的两个视图。
enum GameStreamClientSection { stream, texthooker }

typedef GameStreamClientSectionBuilder =
    Widget Function(BuildContext context, Widget navigation);

/// 非 Windows（macOS / Linux / Android / iOS）的 games 模块：串流接收端的库页壳。
///
/// 顶部与书架 / 漫画 / 视频 / Windows 游戏库同一套 M3E 浮动工具栏
/// （[FushiFloatingChromeOverlay] + [FushiFloatingChromeBar]，重设计外壳下画成
/// 页头大字）：页面名来自外壳下发的 [FushiShellTitleScope]，视图页头里的动作
/// 登记进本壳的动作槽、由工具栏右侧动作组画出。此前这里只是一个视图切换器，
/// 页头由串流库页自己画、页面名靠外壳另叠一枚标题胶囊——宽屏下就成了唯一一个
/// 还是「悬浮标题胶囊」的模块（BUG：非 Windows 游戏页宽屏形态与其它模块不一致）。
///
/// 桌面（[offersTexthooker]）另挂外部 texthooker 台词视图：这些平台没有 galgame
/// hook，但外部 WebSocket texthooker（LunaTranslator / Textractor / mpv）照样能把
/// 台词推进 `TexthookerService`。台词页是 [TexthookerPage] 的嵌入模式，hook 注入 /
/// 捕获 / 窗口绑定控件由 `GamesModuleForm.supportsHookCapture` 在页内隐藏；首次
/// 进入才创建，之后用 [IndexedStack] 保活。手机 / 平板只有串流库，一级页签位改放
/// 页面名（[FushiFloatingChromeSoloTitle]）。
class GameStreamClientPage extends StatefulWidget {
  const GameStreamClientPage({
    required this.streamBuilder,
    this.offersTexthooker = true,
    this.texthookerBuilder,
    super.key,
  });

  /// 串流库视图；测试可注入桩。`navigation` 恒为零尺寸占位：页签由本壳的浮动
  /// 工具栏画，视图页头那一行收起。
  final GameStreamClientSectionBuilder streamBuilder;

  /// 是否挂外部 texthooker 台词视图（`AppModel.gamesOffersExternalTexthooker`）。
  final bool offersTexthooker;

  /// 台词视图；缺省为嵌入模式的 [TexthookerPage]。
  final GameStreamClientSectionBuilder? texthookerBuilder;

  static const Key sectionTabsKey = ValueKey<String>(
    'game-stream-client-sections',
  );
  static const Key streamKey = ValueKey<String>('game-stream-client-stream');
  static const Key texthookerKey = ValueKey<String>(
    'game-stream-client-texthooker',
  );

  @override
  State<GameStreamClientPage> createState() => _GameStreamClientPageState();
}

class _GameStreamClientPageState extends State<GameStreamClientPage> {
  GameStreamClientSection _section = GameStreamClientSection.stream;
  bool _texthookerVisited = false;

  /// 浮动工具栏的显隐（滚动驱动，与其它库页壳同构）。
  final FushiFloatingChromeController _chrome = FushiFloatingChromeController();

  /// 视图页头登记动作的槽：由浮动工具栏右侧的动作组画出。
  final FushiShellActionsSlot _actionsSlot = FushiShellActionsSlot();

  @override
  void dispose() {
    _chrome.dispose();
    _actionsSlot.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification notification) {
    if (!fushiNotificationDrivesPageChrome(notification)) return false;
    return _chrome.handleScrollNotification(notification);
  }

  void _select(GameStreamClientSection section) {
    if (section == _section) return;
    // 换了视图，新视图从顶部开始：工具栏回来。
    _chrome.resetToTop();
    setState(() {
      _section = section;
      if (section == GameStreamClientSection.texthooker) {
        _texthookerVisited = true;
      }
    });
  }

  /// 一级页签：桌面是「串流 / 台词」切换；只有串流库时放页面名。
  Widget _buildNavigation(BuildContext context) {
    if (!widget.offersTexthooker) {
      final String? pageName = FushiShellTitleScope.maybeTitleOf(context);
      return FushiFloatingChromeSoloTitle(
        key: GameStreamClientPage.sectionTabsKey,
        title: pageName != null && pageName.isNotEmpty ? pageName : t.nav_game,
      );
    }
    return KeyedSubtree(
      key: GameStreamClientPage.sectionTabsKey,
      child: LibrarySectionTabs<GameStreamClientSection>(
        tabs: <LibrarySectionTab<GameStreamClientSection>>[
          LibrarySectionTab<GameStreamClientSection>(
            value: GameStreamClientSection.stream,
            label: t.game_stream_tab,
          ),
          LibrarySectionTab<GameStreamClientSection>(
            value: GameStreamClientSection.texthooker,
            label: t.texthooker,
          ),
        ],
        selected: _section,
        onChanged: _select,
        focusIdPrefix: 'game-stream-client-tab',
        floating: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 视图页头的主位：零尺寸占位让页头那一行（连同内边距）收起，动作进槽。
    const Widget slotNavigation = SizedBox.shrink();
    final GameStreamClientSectionBuilder texthooker =
        widget.texthookerBuilder ??
        (BuildContext context, Widget navigation) =>
            TexthookerPage(embedded: true, navigation: navigation);
    final GameStreamClientSection shown = widget.offersTexthooker
        ? _section
        : GameStreamClientSection.stream;
    final Widget body = IndexedStack(
      index: shown.index,
      children: <Widget>[
        KeyedSubtree(
          key: GameStreamClientPage.streamKey,
          // 串流库页自己按工具区可见下沿让位（[FushiFloatingChromeVisiblePadding]）。
          child: widget.streamBuilder(context, slotNavigation),
        ),
        KeyedSubtree(
          key: GameStreamClientPage.texthookerKey,
          child: widget.offersTexthooker && _texthookerVisited
              // 台词工作台是定高版面，没有整页滚动视图可吃让位：按工具区此刻的
              // 可见下沿让位，收起后不留空白（与 Windows 捕获工作台同口径）。
              ? FushiFloatingChromeVisiblePadding(
                  child: texthooker(context, slotNavigation),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
    return Material(
      type: MaterialType.transparency,
      // 保留外壳给本 tab 的页面名（页头大字据它画页名行），只把动作槽换成
      // 壳自己的。
      child: FushiShellTitleScope(
        title: FushiShellTitleScope.maybeTitleOf(context) ?? '',
        actionsSlot: _actionsSlot,
        child: FushiFloatingChromeScope(
          controller: _chrome,
          child: FushiFloatingChromeOverlay(
            // 重设计外壳下画成页头大字（`fushi_page_masthead.dart`）。
            masthead: true,
            chrome: FushiFloatingChromeBar(
              tabs: _buildNavigation(context),
              slot: _actionsSlot,
            ),
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScroll,
              child: body,
            ),
          ),
        ),
      ),
    );
  }
}
