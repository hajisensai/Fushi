import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart' show MediaItemAppLookup;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/second_screen/companion/companion_cover_files.dart';

/// Cover files for the companion (main engine). The panel runs in its own
/// process of the same app, so it can read any local file path the main app
/// resolves; network covers never cross (the panel makes no requests).

/// A local book / manga cover: the user's override, else the item's own
/// `file://` image. '' when there is none (or the drive is gone).
///
/// Probes the file system: call it only for items that are shown
/// (BUG-3756: covers may live on a network drive).
String companionMediaItemCoverPath(AppModel appModel, MediaItem item) =>
    companionCoverFilePath(
      override: () => item
          .getMediaSource(appModel: appModel)
          .resolveOverrideThumbnailFile(appModel: appModel, item: item),
      imageUrl: item.imageUrl,
    );
