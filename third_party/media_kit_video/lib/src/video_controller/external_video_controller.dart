/// FUSHI FORK (externally rendered players): a [PlatformPlayer] whose frames
/// are drawn by something else — e.g. a WebView2 child window playing
/// hardware-DRM video *under* the Flutter view — so [VideoController] must not
/// create a texture for it (the native path would ask the player for an mpv
/// handle). Controls keep working: they only read `player.state` /
/// `player.stream` and call the player's methods.
import 'dart:async';

import 'package:media_kit/media_kit.dart';

import 'package:media_kit_video/src/video_controller/platform_video_controller.dart';

/// Marker for a [PlatformPlayer] that renders its video outside Flutter.
/// [VideoController] then uses [ExternalVideoController] (no texture, `id`
/// stays null, [Video] paints only its `fill`).
/// (Plain abstract class: this package's language version predates class
/// modifiers; implement it, don't extend it.)
abstract class ExternallyRenderedPlatformPlayer {}

/// [PlatformVideoController] for an [ExternallyRenderedPlatformPlayer].
class ExternalVideoController extends PlatformVideoController {
  ExternalVideoController(super.player, super.configuration) {
    // "First frame" = the player reported a video size.
    if (player.state.width != null && player.state.width! > 0) {
      waitUntilFirstFrameRenderedCompleter.complete();
    } else {
      _width = player.stream.width.listen((int? w) {
        if (w != null &&
            w > 0 &&
            !waitUntilFirstFrameRenderedCompleter.isCompleted) {
          waitUntilFirstFrameRenderedCompleter.complete();
          _width?.cancel();
          _width = null;
        }
      });
    }
  }

  StreamSubscription<int?>? _width;

  /// The output size is the external renderer's business.
  @override
  Future<void> setSize({int? width, int? height}) async {}

  @override
  void dispose() {
    _width?.cancel();
    super.dispose();
  }
}
