/// Moved to `fushi_engine` so media tracking (pure Dart) reads the same saved
/// episode durations as the app (BUG-4401). Kept as a re-export so existing
/// imports stay valid.
library;

export 'package:fushi_engine/media/video/video_duration_pref.dart';
