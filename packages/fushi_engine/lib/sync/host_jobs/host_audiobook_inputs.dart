/// host 可被复用的本地输入候选：本机有声书库里**会播的**音频文件。
///
/// 对端把有声书转录交给本机时，先按内容哈希问「这些音频你有没有」（见
/// [HostInputMatcher]）；本机只在自己的有声书（`Audiobooks`）与字幕书
/// （`SrtBooks`）的音频里找，解析规则与播放端 / 同步资产包同一份
/// （[resolvePlayableAudiobookAudioPaths]：files 模式取 `audioPathsJson`，folder
/// 模式枚举 `audioRoot`）。
library;

import 'package:fushi_core/fushi_core.dart'
    show AudiobookRow, FushiDatabase, SrtBookRow;
import 'package:fushi_engine/sync/sync_asset_package_service.dart'
    show resolvePlayableAudiobookAudioPaths;

/// 本机有声书 / 字幕书音频的绝对路径（去重；不检查存在，匹配时会 stat）。
Future<List<String>> hostAudiobookInputCandidates(FushiDatabase db) async {
  final Set<String> paths = <String>{};
  for (final AudiobookRow row in await db.getAllAudiobooks()) {
    paths.addAll(
      await resolvePlayableAudiobookAudioPaths(
        row.audioPathsJson,
        row.audioRoot,
      ),
    );
  }
  for (final SrtBookRow row in await db.getAllSrtBooks()) {
    paths.addAll(
      await resolvePlayableAudiobookAudioPaths(
        row.audioPathsJson,
        row.audioRoot,
      ),
    );
  }
  return paths.toList(growable: false);
}
