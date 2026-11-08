import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_labels.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_now_playing_bar.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_panel_session.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// Library tab modes: what the main screen's library shows (Main) or the
/// companion's own library (Browse).
enum CompanionLibraryMode { main, browse }

/// The Library tab: Main | Browse. Main is only available while the top
/// screen shows a library (and is the default then); each mode keeps its own
/// state (S5 fills both).
class CompanionLibraryTab extends ConsumerStatefulWidget {
  const CompanionLibraryTab({super.key});

  @override
  ConsumerState<CompanionLibraryTab> createState() =>
      _CompanionLibraryTabState();
}

class _CompanionLibraryTabState extends ConsumerState<CompanionLibraryTab> {
  /// The user's pick; null = follow the top screen (Main when it shows a
  /// library).
  CompanionLibraryMode? _picked;

  @override
  Widget build(BuildContext context) {
    final CompanionPanelSession session = ref.watch(
      companionPanelSessionProvider,
    );
    final CompanionContext top = session.context;
    final bool mainAvailable = top.kind == CompanionContextKind.library;
    final CompanionLibraryMode mode = !mainAvailable
        ? CompanionLibraryMode.browse
        : _picked ?? CompanionLibraryMode.main;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const CompanionNowPlayingBar(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              child: adaptiveSegmentedButton<CompanionLibraryMode>(
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
                    setState(() => _picked = next.first),
              ),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: fushiMotionDuration(context, FushiMotion.medium),
                child: switch (mode) {
                  CompanionLibraryMode.main => _MainMode(
                    key: const ValueKey<String>('companion-library-main'),
                    library: top.library,
                  ),
                  CompanionLibraryMode.browse => const _BrowseMode(
                    key: ValueKey<String>('companion-library-browse'),
                  ),
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MainMode extends StatelessWidget {
  const _MainMode({required this.library, super.key});

  final CompanionLibraryKind? library;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final CompanionLibraryKind? shown = library;
    return FushiEntranceScope(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (shown != null)
            FushiStaggeredEntrance(
              index: 0,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  t.second_screen_library_main_filtering(
                    library: companionLibraryLabel(shown),
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          Expanded(
            child: FushiStaggeredEntrance(
              index: 1,
              child: Center(
                child: FushiPlaceholderMessage(
                  icon: FushiIcons.touch,
                  message: t.second_screen_library_main_hint,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BrowseMode extends StatelessWidget {
  const _BrowseMode({super.key});

  @override
  Widget build(BuildContext context) => FushiEntranceScope(
    child: FushiStaggeredEntrance(
      index: 0,
      child: Center(
        child: FushiPlaceholderMessage(
          icon: FushiIcons.books,
          message: t.second_screen_library_browse_empty,
        ),
      ),
    ),
  );
}

/// The Lookup tab: dictionary results of lookups made on the main screen
/// (S3 fills it).
class CompanionLookupTab extends StatelessWidget {
  const CompanionLookupTab({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      bottom: false,
      child: FushiEntranceScope(
        child: FushiStaggeredEntrance(
          index: 0,
          child: Center(
            child: FushiPlaceholderMessage(
              icon: FushiIcons.lookup,
              message: t.second_screen_lookup_empty,
            ),
          ),
        ),
      ),
    ),
  );
}

/// The Settings tab: the main screen's current settings first, then all of
/// them (S4 fills it).
class CompanionSettingsTab extends StatelessWidget {
  const CompanionSettingsTab({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      bottom: false,
      child: FushiEntranceScope(
        child: FushiStaggeredEntrance(
          index: 0,
          child: Center(
            child: FushiPlaceholderMessage(
              icon: FushiIcons.settings,
              message: t.second_screen_settings_empty,
            ),
          ),
        ),
      ),
    ),
  );
}
