import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/second_screen/input/controller_lookup_mode.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart'
    show FushiM3eShape;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// Keeps a small "Lookup mode" badge on the top screen's navigator overlay
/// while [ControllerLookupMode] is active. One instance per app, installed by
/// the gamepad service (which owns the navigator key).
class ControllerLookupBadgeHost {
  ControllerLookupBadgeHost({
    required GlobalKey<NavigatorState> navigatorKey,
    ControllerLookupMode? mode,
  }) : _navigatorKey = navigatorKey,
       _mode = mode ?? ControllerLookupMode.instance;

  final GlobalKey<NavigatorState> _navigatorKey;
  final ControllerLookupMode _mode;
  OverlayEntry? _entry;

  void install() => _mode.addListener(_sync);

  void dispose() {
    _mode.removeListener(_sync);
    _remove();
  }

  void _sync() {
    if (!_mode.active) {
      _remove();
      return;
    }
    final OverlayEntry? existing = _entry;
    if (existing != null) {
      existing.markNeedsBuild();
      return;
    }
    final OverlayState? overlay = _navigatorKey.currentState?.overlay;
    if (overlay == null) return;
    final OverlayEntry entry = OverlayEntry(
      builder: (BuildContext context) => ControllerLookupBadge(mode: _mode),
    );
    _entry = entry;
    overlay.insert(entry);
  }

  void _remove() {
    _entry?.remove();
    _entry?.dispose();
    _entry = null;
  }
}

/// The badge itself: non-interactive, top centre, "Lookup mode · By word".
class ControllerLookupBadge extends StatelessWidget {
  const ControllerLookupBadge({super.key, required this.mode});

  final ControllerLookupMode mode;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool word =
        mode.wordGranularity && (mode.target?.hasWordSteps ?? false);
    final String label =
        '${t.second_screen_controller_lookup_badge} · '
        '${word ? t.second_screen_controller_lookup_by_word : t.second_screen_controller_lookup_by_char}';
    return IgnorePointer(
      child: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: 1),
              duration: fushiMotionDuration(context, FushiMotion.short),
              curve: FushiMotion.standard,
              builder: (BuildContext context, double v, Widget? child) =>
                  Opacity(opacity: v, child: child),
              child: Semantics(
                liveRegion: true,
                label: label,
                excludeSemantics: true,
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
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        FushiIcon(
                          FushiIcons.lookup,
                          size: 16,
                          color: scheme.onSecondaryContainer,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          label,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: scheme.onSecondaryContainer,
                          ),
                        ),
                      ],
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
