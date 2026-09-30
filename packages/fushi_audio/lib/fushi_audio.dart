library hibiki_audio;

// 本包已不依赖 Flutter SDK（2026-09-30）：全 barrel 与 `fushi_audio_core.dart`
// 导出同一份纯 Dart 面。原先只由这里导出的三个重文件（just_audio 播放控制器、
// path_provider / just_audio 的存储平台装配、flutter_charset_detector 插件实现）
// 已搬到 app：`fushi/lib/src/media/audiobook/{audiobook_controller,
// audiobook_storage_platform,platform_charset_detector}.dart`。
export 'fushi_audio_core.dart';
