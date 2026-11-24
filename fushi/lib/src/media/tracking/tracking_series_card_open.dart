import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/models/shelf_collection_open_request.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi_core/fushi_core.dart' show BookFormat, EpubBookRow;
import 'package:material_ui/material_ui.dart';

/// Opens a series card's detail page, where its series links and the way
/// each volume counts are managed ("Tracking" section). [bookKey] is any
/// volume of the card: it tells the Books tab from the Manga tab.
typedef TrackingSeriesCardOpener =
    Future<void> Function(
      BuildContext context,
      int collectionId,
      String bookKey,
    );

/// [TrackingSeriesCardOpener] of the app: back to the home shell, onto the
/// card's library tab, and the library opens the card with its own detail
/// page ([requestShelfCollectionOpen], the exit a tap on the card uses).
/// A tab turned off in Modules only shows a hint.
Future<void> openTrackingSeriesCard(
  BuildContext context,
  int collectionId,
  String bookKey,
) async {
  final AppModel appModel = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(appProvider);
  final EpubBookRow? book = await appModel.database.getEpubBook(bookKey);
  if (!context.mounted) return;
  final bool manga = book?.format == BookFormat.manga.dbValue;
  final HomeTab tab = manga ? HomeTab.manga : HomeTab.books;
  if (!isHomeTabVisible(tab, appModel.moduleVisibility)) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(FushiSnackBar(content: Text(t.module_disabled_hint)));
    return;
  }
  Navigator.of(
    context,
    rootNavigator: true,
  ).popUntil((Route<Object?> route) => route.isFirst);
  homeShellTabNotifier.value = tab;
  requestShelfCollectionOpen(collectionId: collectionId, manga: manga);
}
