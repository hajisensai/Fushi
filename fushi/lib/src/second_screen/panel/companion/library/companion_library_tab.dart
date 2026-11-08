import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_now_playing_bar.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_panel_session.dart';
import 'package:fushi/src/second_screen/panel/companion/library/companion_library_browse.dart';
import 'package:fushi/src/second_screen/panel/companion/library/companion_library_main.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:material_ui/material_ui.dart';

/// Library tab modes: what the main screen's library shows (Main) or the
/// companion's own library (Browse).
enum CompanionLibraryMode { main, browse }

/// The Library tab: Main | Browse. Main is only available while the top
/// screen shows a library (and is the default then). Each mode has its own
/// navigator, so its pages and back history survive switching modes; Back
/// pops the visible mode's history.
class CompanionLibraryTab extends ConsumerStatefulWidget {
  const CompanionLibraryTab({super.key});

  @override
  ConsumerState<CompanionLibraryTab> createState() =>
      CompanionLibraryTabState();
}

class CompanionLibraryTabState extends ConsumerState<CompanionLibraryTab> {
  /// The user's pick; null = follow the top screen (Main when it shows a
  /// library).
  CompanionLibraryMode? _picked;

  final Map<CompanionLibraryMode, GlobalKey<NavigatorState>> _navigators =
      <CompanionLibraryMode, GlobalKey<NavigatorState>>{
        for (final CompanionLibraryMode mode in CompanionLibraryMode.values)
          mode: GlobalKey<NavigatorState>(
            debugLabel: 'companion-library-${mode.name}',
          ),
      };

  CompanionLibraryMode _mode(CompanionContext top) =>
      top.kind != CompanionContextKind.library
      ? CompanionLibraryMode.browse
      : _picked ?? CompanionLibraryMode.main;

  /// The navigator of [mode] (detail pages are pushed on it).
  NavigatorState? navigatorOf(CompanionLibraryMode mode) =>
      _navigators[mode]!.currentState;

  /// Shows [mode] (Main only when available).
  void selectMode(CompanionLibraryMode mode) => setState(() => _picked = mode);

  /// Back to the visible mode's root page (the Library tab selected again).
  void popToRoot() => navigatorOf(
    _mode(ref.read(companionPanelSessionProvider).context),
  )?.popUntil((Route<Object?> route) => route.isFirst);

  @override
  Widget build(BuildContext context) {
    final CompanionPanelSession session = ref.watch(
      companionPanelSessionProvider,
    );
    final CompanionContext top = session.context;
    final bool mainAvailable = top.kind == CompanionContextKind.library;
    final CompanionLibraryMode mode = _mode(top);
    final Widget toggle = adaptiveSegmentedButton<CompanionLibraryMode>(
      context: context,
      segments: <ButtonSegment<CompanionLibraryMode>>[
        ButtonSegment<CompanionLibraryMode>(
          value: CompanionLibraryMode.main,
          label: Text(t.second_screen_library_mode_main),
          enabled: mainAvailable,
        ),
        ButtonSegment<CompanionLibraryMode>(
          value: CompanionLibraryMode.browse,
          label: Text(t.second_screen_library_mode_browse),
        ),
      ],
      selected: <CompanionLibraryMode>{mode},
      onSelectionChanged: (Set<CompanionLibraryMode> next) =>
          selectMode(next.first),
    );
    return PopScope<Object?>(
      // The tab's own route never pops; Back goes to the visible mode.
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop) navigatorOf(mode)?.maybePop();
      },
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const CompanionNowPlayingBar(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                child: mainAvailable
                    ? toggle
                    : FushiTooltip(
                        message: t.second_screen_library_main_unavailable,
                        child: toggle,
                      ),
              ),
              Expanded(
                child: IndexedStack(
                  index: mode.index,
                  children: <Widget>[
                    for (final CompanionLibraryMode m
                        in CompanionLibraryMode.values)
                      TickerMode(
                        enabled: m == mode,
                        child: ExcludeFocus(
                          excluding: m != mode,
                          child: Navigator(
                            key: _navigators[m],
                            onGenerateRoute: (RouteSettings settings) =>
                                MaterialPageRoute<void>(
                                  settings: settings,
                                  builder: (BuildContext context) =>
                                      switch (m) {
                                        CompanionLibraryMode.main =>
                                          const CompanionLibraryMainRoot(),
                                        CompanionLibraryMode.browse =>
                                          const CompanionLibraryBrowseRoot(),
                                      },
                                ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
