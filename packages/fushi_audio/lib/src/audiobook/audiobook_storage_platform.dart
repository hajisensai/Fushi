import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import 'audiobook_storage.dart';

/// [AudiobookStorage] 的 Flutter 平台实现。**重文件**：只由全 barrel
/// `fushi_audio.dart` 导出，不进 `fushi_audio_core.dart`——path_provider /
/// just_audio 都是 method-channel 插件，无头服务端不能拖进来。
///
/// 每个文件用一次性 [AudioPlayer]，探完即释放；探测失败（损坏 / 解码不支持 /
/// 插件在本平台不可用）返回 0，与拆分前逐字节一致。
Future<int> justAudioDurationProbeMs(String path) async {
  final AudioPlayer player = AudioPlayer();
  try {
    final Duration? dur = await player.setFilePath(path);
    return dur?.inMilliseconds ?? 0;
  } catch (_) {
    return 0;
  } finally {
    await player.dispose();
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
