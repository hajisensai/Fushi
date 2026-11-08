import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_labels.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_panel_session.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// Library tab, Main mode root: the library on the main screen (its
/// highlighted item, search / sort / filter driving the top list).
/// STUB — filled by the S5 Main-mode work.
class CompanionLibraryMainRoot extends ConsumerWidget {
  const CompanionLibraryMainRoot({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final CompanionLibraryKind? shown = ref
        .watch(companionPanelSessionProvider)
        .context
        .library;
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
