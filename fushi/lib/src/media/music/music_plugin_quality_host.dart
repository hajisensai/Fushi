import 'package:fushi_music/fushi_music.dart' show MusicPluginQuality;

import 'package:fushi/src/media/music/music_player_engine.dart';

/// 播放器音质快切对宿主要的全部能力（生产实现是 `AppModel`）。
///
/// 快切被播放页 / 播放条 / 设置 schema 引用，若它 import `AppModel`，就会把自己拖进
/// `lib/` 的最大 import 环（`import_cycle_guard_test`），所以只经这个窄接口注入。
abstract interface class MusicPluginQualityHost {
  /// 当前播放引擎（读当前曲目、实际流规格，监听换曲 / 重取）。
  MusicPlayerEngine get musicPlayerEngine;

  /// 默认音质档。
  MusicPluginQuality get musicPluginQuality;

  /// [path] 这首的音质档（本次会话的单曲覆盖优先，否则默认档）。
  MusicPluginQuality musicPluginQualityFor(String path);

  /// 设默认音质档并按新档原位重取当前曲。
  Future<void> setMusicPluginQuality(MusicPluginQuality quality);

  /// 只给 [path] 这首设音质档（不改默认）并原位重取。
  Future<void> setMusicPluginQualityOverride(
    String path,
    MusicPluginQuality quality,
  );
}
