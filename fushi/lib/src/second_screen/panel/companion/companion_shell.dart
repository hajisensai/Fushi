import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_now_tab.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_tabs.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// The companion's four destinations.
enum CompanionTab { now, library, lookup, settings }

/// The companion panel: four icon-only tabs (Now / Library / Lookup /
/// Settings), each with its own navigator and back history. Back on the
/// panel (gesture / nav bar of its display) pops the current tab; at a tab's
/// root it does nothing (the panel's lifetime belongs to the main screen). A
/// new context on top refreshes Now's content but never switches the tab.
class CompanionShell extends StatefulWidget {
  const CompanionShell({
    this.contextPanels =
        const <CompanionContextKind, CompanionContextPanelBuilder>{},
    super.key,
  });

  /// Now tab panels per media context (S3).
  final Map<CompanionContextKind, CompanionContextPanelBuilder> contextPanels;

  @override
  State<CompanionShell> createState() => CompanionShellState();
}

class CompanionShellState extends State<CompanionShell> {
  CompanionTab _tab = CompanionTab.now;

  final Map<CompanionTab, GlobalKey<NavigatorState>> _navigators =
      <CompanionTab, GlobalKey<NavigatorState>>{
        for (final CompanionTab tab in CompanionTab.values)
          tab: GlobalKey<NavigatorState>(debugLabel: 'companion-${tab.name}'),
      };

  CompanionTab get tab => _tab;

  /// The navigator of [tab] (S3–S5 push their detail pages on it).
  NavigatorState? navigatorOf(CompanionTab tab) =>
      _navigators[tab]!.currentState;

  /// Switches to [next]; the current tab again goes back to its root.
  void select(CompanionTab next) {
    if (next == _tab) {
      navigatorOf(next)?.popUntil((Route<Object?> route) => route.isFirst);
      return;
    }
    setState(() => _tab = next);
  }

  /// Back: pops the current tab's history (nothing at its root).
  void _back() => navigatorOf(_tab)?.maybePop();

  Widget _root(CompanionTab tab) => switch (tab) {
    CompanionTab.now => CompanionNowTab(contextPanels: widget.contextPanels),
    CompanionTab.library => const CompanionLibraryTab(),
    CompanionTab.lookup => const CompanionLookupTab(),
    CompanionTab.settings => const CompanionSettingsTab(),
  };

  static List<AdaptiveNavItem> _items() => <AdaptiveNavItem>[
    AdaptiveNavItem(
      icon: FushiIcons.viewAgenda,
      selectedIcon: FushiIcons.filled(FushiIcons.viewAgenda),
      label: t.second_screen_tab_now,
    ),
    AdaptiveNavItem(
      icon: FushiIcons.books,
      selectedIcon: FushiIcons.filled(FushiIcons.books),
      label: t.second_screen_tab_library,
    ),
    AdaptiveNavItem(
      icon: FushiIcons.lookup,
      selectedIcon: FushiIcons.filled(FushiIcons.lookup),
      label: t.second_screen_tab_lookup,
    ),
    AdaptiveNavItem(
      icon: FushiIcons.settings,
      selectedIcon: FushiIcons.filled(FushiIcons.settings),
      label: t.second_screen_tab_settings,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        extendBody: true,
        body: IndexedStack(
          index: _tab.index,
          children: <Widget>[
            for (final CompanionTab tab in CompanionTab.values)
              _TabBody(
                active: tab == _tab,
                child: Navigator(
                  key: _navigators[tab],
                  onGenerateRoute: (RouteSettings settings) =>
                      MaterialPageRoute<void>(
                        settings: settings,
                        builder: (BuildContext context) => _root(tab),
                      ),
                ),
              ),
          ],
        ),
        bottomNavigationBar: FocusTraversalGroup(
          child: adaptiveBottomBar(
            context: context,
            currentIndex: _tab.index,
            onTap: (int index) => select(CompanionTab.values[index]),
            items: _items(),
            showLabels: false,
          ),
        ),
      ),
    );
  }
}

/// A tab's navigator; off-screen tabs keep their state but take no focus and
/// run no animations.
class _TabBody extends StatelessWidget {
  const _TabBody({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) => TickerMode(
    enabled: active,
    child: ExcludeFocus(excluding: !active, child: child),
  );
}
