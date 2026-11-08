import 'package:fushi_audio/fushi_audio.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

/// [AudiobookStorage] 的 Flutter 平台实现。住在 app 而不是 `fushi_audio`：
/// path_provider / just_audio 都是 method-channel 插件，`fushi_audio` 已不依赖
/// Flutter SDK（无头服务端直接消费它）。
///
/// 每个文件用一次性 [AudioPlayer]，探完即释放；探测失败（损坏 / 解码不支持 /
/// 插件在本平台不可用）返回 0，与拆分前逐字节一致。
///
/// 构造本身也在 try 里：插件不可用时 [AudioPlayer] 的构造就会抛（例如没有 Flutter
/// binding 的上下文），那同样是「探不出」，按契约返回 0，不能把异常抛给导入流程
/// （BUG-4248：所有导入路径都经共享的 cue 归文件入口调这里）。
Future<int> justAudioDurationProbeMs(String path) async {
  AudioPlayer? player;
  try {
    player = AudioPlayer();
    final Duration? dur = await player.setFilePath(path);
    return dur?.inMilliseconds ?? 0;
  } catch (_) {
    return 0;
  } finally {
    await player?.dispose();
  }
}

/// 把平台实现写入 [AudiobookStorage] 的两个装配点。Flutter app 在 `main()`
/// 里调一次。
///
/// documents 根用 `??=`：只补平台默认值（`getApplicationDocumentsDirectory`，
/// 与 TODO-1236 前逐字节等价），不覆盖 app 层 `AppModel` 已注入的 `AppPaths`
/// 解析器（也不覆盖测试预先注入的临时目录）。
void installAudiobookStoragePlatform() {
  AudiobookStorage.documentsRootResolver ??= getApplicationDocumentsDirectory;
  AudiobookStorage.audioDurationProbeMs = justAudioDurationProbeMs;
}
