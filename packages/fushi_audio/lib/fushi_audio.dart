library hibiki_audio;

// 零 Flutter 子集（解析 / 仓储 / 匹配）——无头服务端只 import 这一半。
export 'fushi_audio_core.dart';

// 重文件：just_audio / audio_session / path_provider / method-channel 插件，
// 只有 Flutter app 需要。
export 'src/audiobook/audiobook_controller.dart';
export 'src/audiobook/audiobook_storage_platform.dart';
export 'src/parsers/platform_charset_detector.dart';
