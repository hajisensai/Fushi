/// native/fushi_music（Rust 音乐胖核心）的 FFI 绑定：曲库扫描 / 标签 / CUE 拆轨 / 内容派生 uid。
/// 硬依赖、没有 Dart 回退：库或符号缺失时抛 [FushiMusicUnavailableError]。
library;

export 'src/fushi_music_library.dart';
export 'src/music_scanner.dart';
export 'src/scan_wire.dart';
