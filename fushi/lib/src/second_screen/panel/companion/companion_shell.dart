import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_lookup_controller.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_lookup_tab.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_now_tab.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_panel_session.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_settings_tab.dart';
import 'package:fushi/src/second_screen/panel/companion/library/companion_library_actions.dart';
import 'package:fushi/src/second_screen/panel/companion/library/companion_library_tab.dart';
import 'package:fushi/src/shortcuts/dictionary_popup_gamepad.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show gamepadMoveFocusInDirection;
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart'
    show FushiM3eShape;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// The companion's four destinations.
enum CompanionTab {
  now,
  library,
  lookup,
  settings;

  /// [CompanionPanelUiState.tab].
  String get wire => name;

  /// null for an unknown / missing name.
  static CompanionTab? fromWire(String? value) {
    for (final CompanionTab tab in values) {
      if (tab.wire == value) return tab;
    }
    return null;
  }
}

/// The companion panel: four icon-only tabs (Now / Library / Lookup /
/// Settings), each with its own navigator and back history. Back on the
/// panel (gesture / nav bar of its display) pops the current tab; at a tab's
/// root it does nothing (the panel's lifetime belongs to the main screen). A
/// new context on top refreshes Now's content but never switches the tab.
///
/// A lookup made on the main screen surfaces here (the top screen shows no
/// popup): the shell switches to the Lookup tab, and closing that lookup
/// goes back to the tab it came from (unless the user picked another tab
/// meanwhile).
///
/// The tab the user picked is reported to the main engine
/// ([CompanionPanelSession.updateUi]); a panel relaunched after the top
/// activity stopped opens on it again.
class CompanionShell extends ConsumerStatefulWidget {
  const CompanionShell({
    this.contextPanels =
        const <CompanionContextKind, CompanionContextPanelBuilder>{},
    this.lookupTab = const CompanionLookupTab(),
    super.key,
  });

  /// The Lookup tab's root (tests pass one with a stand-in dictionary).
  final Widget lookupTab;

  /// Now tab panels per media context (S3).
  final Map<CompanionContextKind, CompanionContextPanelBuilder> contextPanels;

  @override
  ConsumerState<CompanionShell> createState() => CompanionShellState();
}

class CompanionShellState extends ConsumerState<CompanionShell> {
  CompanionTab _tab = CompanionTab.now;

  /// The tab a main-screen lookup switched away from; null when the user
  /// is where they chose to be.
  CompanionTab? _beforeLookup;

  final Map<CompanionTab, GlobalKey<NavigatorState>> _navigators =
      <CompanionTab, GlobalKey<NavigatorState>>{
        for (final CompanionTab tab in CompanionTab.values)
          tab: GlobalKey<NavigatorState>(debugLabel: 'companion-${tab.name}'),
      };

  CompanionTab get tab => _tab;

  /// The navigator of [tab] (S3–S5 push their detail pages on it).
  NavigatorState? navigatorOf(CompanionTab tab) =>
      _navigators[tab]!.currentState;

  final GlobalKey<CompanionLibraryTabState> _libraryTab =
      GlobalKey<CompanionLibraryTabState>(debugLabel: 'companion-library-tab');

  /// Switches to [next]; the current tab again goes back to its root (the
  /// Library tab also to its visible mode's root).
  void select(CompanionTab next) {
    _beforeLookup = null;
    if (next == _tab) {
      navigatorOf(next)?.popUntil((Route<Object?> route) => route.isFirst);
      if (next == CompanionTab.library) _libraryTab.currentState?.popToRoot();
      _reportTab();
      return;
    }
    setState(() => _tab = next);
    _reportTab();
  }

  /// Reports the tab the user is on (a lookup's detour to the Lookup tab
  /// counts as the tab it came from).
  void _reportTab() {
    final CompanionTab chosen = _beforeLookup ?? _tab;
    ref
        .read(companionPanelSessionProvider)
        .updateUi(
          (CompanionPanelUiState ui) => ui.copyWith(tab: () => chosen.wire),
        );
  }

  /// The main engine handed back the last panel's state: back to its tab
  /// (behind a lookup that is showing, if any: closing it returns there).
  void _restoreUi() {
    final CompanionTab saved =
        CompanionTab.fromWire(
          ref.read(companionPanelSessionProvider).uiState.tab,
        ) ??
        CompanionTab.now;
    if (_beforeLookup != null) {
      _beforeLookup = saved;
      return;
    }
    if (saved != _tab) setState(() => _tab = saved);
  }

  /// After the companion opened something on top (Browse): the Now tab.
  void _showNow() {
    if (_tab != CompanionTab.now) select(CompanionTab.now);
  }

  void _onLookupChanged(
    CompanionLookupController? previous,
    CompanionLookupController lookup,
  ) {
    if (lookup.surfaced != _seenSurfaced) {
      _seenSurfaced = lookup.surfaced;
      if (_tab != CompanionTab.lookup) {
        final CompanionTab from = _tab;
        navigatorOf(
          CompanionTab.lookup,
        )?.popUntil((Route<Object?> route) => route.isFirst);
        setState(() => _tab = CompanionTab.lookup);
        _beforeLookup = from;
      }
      return;
    }
    final CompanionTab? back = _beforeLookup;
    if (lookup.current == null && back != null && _tab == CompanionTab.lookup) {
      _beforeLookup = null;
      setState(() => _tab = back);
      _reportTab();
    }
  }

  int _seenSurfaced = 0;
  StreamSubscription<CompanionHostMessage>? _controllerInput;
  bool _driving = false;
  final GlobalKey _focusScopeKey = GlobalKey(debugLabel: 'companion-focus');

  /// R1 is held on the top screen's controller: the panel shows its focus.
  bool get driving => _driving;

  @override
  void initState() {
    super.initState();
    final CompanionLookupController lookup = ref.read(
      companionLookupControllerProvider,
    );
    _seenSurfaced = lookup.surfaced;
    _tab =
        CompanionTab.fromWire(
          ref.read(companionPanelSessionProvider).uiState.tab,
        ) ??
        CompanionTab.now;
    // A main-screen lookup that arrived before the shell was up (it waited in
    // the panel's backlog and the lookup controller showed it on creation)
    // surfaces like any other: open on the Lookup tab, closing returns to the
    // tab the user was on (Now, or the restored one).
    if (lookup.surfaced > 0 && lookup.current != null) {
      _beforeLookup = _tab;
      _tab = CompanionTab.lookup;
    }
    _controllerInput = ref
        .read(companionPanelSessionProvider)
        .controllerInput
        .listen(_onControllerInput);
  }

  @override
  void dispose() {
    unawaited(_controllerInput?.cancel());
    if (_driving) {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic;
    }
    super.dispose();
  }

  /// Back: pops the current tab's history (nothing at its root).
  void _back() => navigatorOf(_tab)?.maybePop();

  // ---- Controller from the top screen (S6) --------------------------------

  void _onControllerInput(CompanionHostMessage message) {
    if (!mounted) return;
    switch (message) {
      case CompanionPanelNavMessage(:final String action):
        _onPanelNav(action);
      case CompanionLookupActionMessage(
        :final String action,
        :final Map<String, Object?> args,
      ):
        _onLookupAction(action, args);
      default:
        break;
    }
  }

  void _onPanelNav(String action) {
    switch (action) {
      case CompanionPanelNav.begin:
        _setDriving(true);
        _ensureFocus();
      case CompanionPanelNav.end:
        _setDriving(false);
      case CompanionPanelNav.back:
        _setDriving(true);
        _back();
      case CompanionPanelNav.activate:
        _setDriving(true);
        final BuildContext? focused = _focusedContext;
        if (focused == null) {
          _ensureFocus();
        } else {
          Actions.maybeInvoke<ActivateIntent>(focused, const ActivateIntent());
        }
      case CompanionPanelNav.up:
        _move(TraversalDirection.up);
      case CompanionPanelNav.down:
        _move(TraversalDirection.down);
      case CompanionPanelNav.left:
        _move(TraversalDirection.left);
      case CompanionPanelNav.right:
        _move(TraversalDirection.right);
    }
  }

  void _onLookupAction(String action, Map<String, Object?> args) {
    final CompanionLookupController lookup = ref.read(
      companionLookupControllerProvider,
    );
    if (action == CompanionLookupActions.close) {
      if (lookup.current == null) return;
      // Like Back on the Lookup tab: nested dictionary layers first, then the
      // lookup itself.
      if (_tab == CompanionTab.lookup) {
        _back();
      } else {
        lookup.close();
      }
      return;
    }
    // The embedded dictionary registers its gamepad hooks in this engine.
    final DictionaryPopupGamepadHooks? hooks =
        DictionaryPopupGamepadRegistry.current;
    if (hooks == null) return;
    switch (action) {
      case CompanionLookupActions.mine:
        unawaited(hooks.mineFirstEntry());
      case CompanionLookupActions.playAudio:
        unawaited(hooks.playFirstAudio());
      case CompanionLookupActions.nextEntry:
        unawaited(hooks.entryMove(true));
      case CompanionLookupActions.prevEntry:
        unawaited(hooks.entryMove(false));
      case CompanionLookupActions.scroll:
        final Object? dy = args[CompanionLookupActions.dy];
        if (dy is num) unawaited(hooks.scrollBy(dy.toDouble()));
    }
  }

  void _setDriving(bool value) {
    if (_driving == value) return;
    // Controls paint their focus ring only in traditional highlight mode, and
    // nothing on this display flips it (the keys come from the top screen's
    // controller): force it while driven, hand it back afterwards. The focus
    // position itself is kept for the next drive.
    FocusManager.instance.highlightStrategy = value
        ? FocusHighlightStrategy.alwaysTraditional
        : FocusHighlightStrategy.automatic;
    setState(() => _driving = value);
  }

  /// The focused control inside this shell; null when focus is elsewhere
  /// (nothing focused yet, the focus root's fallback node).
  BuildContext? get _focusedContext {
    final FocusNode? primary = FocusManager.instance.primaryFocus;
    final BuildContext? shell = _focusScopeKey.currentContext;
    if (primary == null || shell == null || primary.context == null) {
      return null;
    }
    final FocusScopeNode scope = FocusScope.of(shell);
    if (identical(primary, scope) || !primary.ancestors.contains(scope)) {
      return null;
    }
    return primary.context;
  }

  void _ensureFocus() {
    if (_focusedContext != null) return;
    final BuildContext? shell = _focusScopeKey.currentContext;
    if (shell == null) return;
    FocusScope.of(shell).nextFocus();
  }

  void _move(TraversalDirection direction) {
    _setDriving(true);
    final BuildContext? focused = _focusedContext;
    if (focused == null) {
      _ensureFocus();
      return;
    }
    gamepadMoveFocusInDirection(focused, direction);
  }

  Widget _root(CompanionTab tab) => switch (tab) {
    CompanionTab.now => CompanionNowTab(contextPanels: widget.contextPanels),
    CompanionTab.library => CompanionLibraryTab(key: _libraryTab),
    CompanionTab.lookup => widget.lookupTab,
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
    ref
      ..listen<CompanionLookupController>(
        companionLookupControllerProvider,
        _onLookupChanged,
      )
      ..listen<int>(
        companionPanelSessionProvider.select(
          (CompanionPanelSession s) => s.uiRestores,
        ),
        (int? _, int _) => _restoreUi(),
      );
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop) _back();
      },
      child: CompanionShowNowScope(
        showNow: _showNow,
        child: FocusScope(key: _focusScopeKey, child: _scaffold(context)),
      ),
    );
  }

  Widget _scaffold(BuildContext context) => Scaffold(
    resizeToAvoidBottomInset: false,
    extendBody: true,
    body: Stack(
      children: <Widget>[
        Positioned.fill(
          child: IndexedStack(
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
        ),
        _DriveHint(visible: _driving),
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
  );
}

/// "Controller drives this screen · release R1 to return", shown at the top
/// while R1 panel drive is on (non-interactive).
class _DriveHint extends StatelessWidget {
  const _DriveHint({required this.visible});

  final bool visible;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return IgnorePointer(
      child: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: fushiMotionDuration(context, FushiMotion.short),
            curve: FushiMotion.standard,
            child: Semantics(
              liveRegion: visible,
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: FushiM3eShape.smallRadius,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: Text(
                      t.second_screen_panel_drive_hint,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                ),
              ),
            ),
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
