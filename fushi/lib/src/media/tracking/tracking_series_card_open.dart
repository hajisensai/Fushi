import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/tracking/tracking_series_card_opener.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/models/module_id.dart' show ModuleVisibility;
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/models/shelf_collection_open_request.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi_core/fushi_core.dart'
    show BookFormat, EpubBookRow, FushiDatabase;
import 'package:material_ui/material_ui.dart';

/// What [trackingSeriesCardOpener] reads from the app: the library (which
/// tab a volume lives on) and the modules turned on. AppModel implements it;
/// this file does not import AppModel, so the tracking UI that takes the
/// opener stays out of the big import cycle (import_cycle_guard_test).
abstract interface class TrackingSeriesCardHost {
  FushiDatabase get database;
  ModuleVisibility get moduleVisibility;
}

/// The app's [TrackingSeriesCardOpener]: back to the home shell, onto the
/// card's library tab, and the library opens the card with its own detail
/// page ([requestShelfCollectionOpen], the exit a tap on the card uses).
/// A tab turned off in Modules only shows a hint.
TrackingSeriesCardOpener trackingSeriesCardOpener(
  TrackingSeriesCardHost host,
) => (BuildContext context, int collectionId, String bookKey) async {
  final EpubBookRow? book = await host.database.getEpubBook(bookKey);
  if (!context.mounted) return;
  final bool manga = book?.format == BookFormat.manga.dbValue;
  final HomeTab tab = manga ? HomeTab.manga : HomeTab.books;
  if (!isHomeTabVisible(tab, host.moduleVisibility)) {
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
};
