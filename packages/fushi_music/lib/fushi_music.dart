/// native/fushi_music（Rust 音乐胖核心）的 FFI 绑定：曲库扫描 / 标签 / CUE 拆轨 / 内容派生 uid，
/// 歌词全格式解析 → 统一时间轴（[LyricTimeline]），以及在线音源插件运行时（[MusicPluginManager]）。
/// 硬依赖、没有 Dart 回退：库或符号缺失时抛 [FushiMusicUnavailableError]。
library;

export 'src/audio_cd.dart';
export 'src/audio_fingerprint.dart';
export 'src/fushi_music_library.dart';
export 'src/lyric_timeline.dart';
export 'src/lyrics_ffi.dart';
export 'src/music_scanner.dart';
export 'src/music_tag_fields.dart';
export 'src/plugin/plugin_ffi.dart';
export 'src/plugin/plugin_instance.dart';
export 'src/plugin/plugin_manager.dart';
export 'src/plugin/plugin_models.dart';
export 'src/plugin/plugin_net_guard.dart';
export 'src/plugin/plugin_source.dart';
export 'src/scan_wire.dart';
