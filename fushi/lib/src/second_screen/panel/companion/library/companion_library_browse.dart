import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// Library tab, Browse mode root: the companion's own library.
/// STUB — filled by the S5 Browse work.
class CompanionLibraryBrowseRoot extends StatelessWidget {
  const CompanionLibraryBrowseRoot({super.key});

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
