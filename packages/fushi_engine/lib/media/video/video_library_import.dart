/// 视频入库的纯助手（bookUid 派生、字幕解析）。从 app 的 video_import_dialog.dart
/// 抽出：互联 host 收上传视频、无头服务端扫描库都要用，对话框只留 UI。
library;

import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_engine/media/video/external_video.dart'
    show decodedSourceBasename;
import 'package:fushi_engine/sync/ttu_filename.dart';

/// 为 m3u8 播放列表生成跨设备稳定 bookUid：`video/playlist/<sanitize(文件名)>`。
///
/// 纯函数（抽出便于单测）。**只取文件名（去扩展名）经 [sanitizeTtuFilename]
/// 派生**，与书的身份哲学（`bookKey = sanitizeTtuFilename(title)`）对齐——
/// 换机器/移动文件夹身份不变，跨设备同步可对齐。同名碰撞交给
/// [uniqueVideoBookUid] 在导入时加后缀去重，而非把完整绝对路径哈希进身份。
String playlistBookUid(String m3u8Path) {
  final String base = _crossPlatformBasenameWithoutExtension(m3u8Path);
  return 'video/playlist/${sanitizeTtuFilename(base)}';
}

/// 取路径最后一段并去扩展名，**同时把 `/` 和 `\` 都当分隔符**（与宿主平台无关），
/// http(s) URL 段先百分号解码（[decodedSourceBasename] 单一派生点）。
///
/// 纯函数。`p.basenameWithoutExtension` 只认宿主平台的分隔符——在 Linux/macOS 上
/// 不会把 Windows 路径的 `\` 当分隔符，于是 `D:\a\x.mkv` 整串被当文件名，破坏
/// 「同一文件名跨不同绝对路径/不同机器得相同 bookUid」的身份不变量。这里两种分隔符
/// 都认，保证 `D:\a\E01.mkv` 与 `/home/u/E01.mkv` 在任何平台都派生出 `E01`；
/// 网络来源的 `https://.../E01.mkv`（含 %20 编码）同理派生出解码后的 `E01`。
String _crossPlatformBasenameWithoutExtension(String path) {
  final String name = decodedSourceBasename(path);
  final int dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

/// 为单个视频文件生成跨设备稳定 bookUid：`video/<sanitize(文件名去扩展名)>`。
///
/// 纯函数。与 [playlistBookUid] 同源：只取文件名经 [sanitizeTtuFilename] 派生，
/// 不含目录/绝对路径，同名碰撞由 [uniqueVideoBookUid] 加后缀去重。
String singleVideoBookUid(String videoPath) {
  final String base = _crossPlatformBasenameWithoutExtension(videoPath);
  return 'video/${sanitizeTtuFilename(base)}';
}

/// 同名去重：若 [base] 已在 [existingKeys] 中，返回首个空位的加后缀变体
/// （`base (2)` / `base (3)`...）；否则原样返回。
///
/// 纯函数。照搬 EpubImporter 的**无回调静默加后缀**策略（见
/// `resolveDuplicateTitle` 的 `_uniqueSuffixedTitle`），保持"本地不出现两个
/// 同 book_uid 视频"的不变量，供同步/导入安全使用。video 导入对话框无重名提示
/// 回调基础设施，故采用与 EpubImporter 无回调路径一致的静默后缀 UX。
String uniqueVideoBookUid(String base, Set<String> existingKeys) {
  if (!existingKeys.contains(base)) return base;
  for (int i = 2;; i++) {
    final String candidate = '$base ($i)';
    if (!existingKeys.contains(candidate)) return candidate;
  }
}

/// 按字幕扩展名路由到对应解析器，返回按 [AudioCue.startMs] 升序排序的 cue。
///
/// 纯函数，无 IO / context 依赖，是 [VideoImportDialog] 的可测核心：
/// - `srt` → [SrtParser]
/// - `vtt` → [VttParser]
/// - `ass` / `ssa` → [AssParser]
/// - 其他 → 抛 [ArgumentError]
List<AudioCue> parseSubtitleCues({
  required String content,
  required String format,
  required String bookUid,
}) {
  final String normalized = format.toLowerCase();
  final List<AudioCue> cues;
  switch (normalized) {
    case 'srt':
      cues = SrtParser.parseString(content: content, bookKey: bookUid);
      break;
    case 'vtt':
      cues = VttParser.parseString(content: content, bookKey: bookUid);
      break;
    case 'ass':
    case 'ssa':
      cues = AssParser.parseString(content: content, bookKey: bookUid);
      break;
    default:
      throw ArgumentError.value(
        format,
        'format',
        'Unsupported subtitle format',
      );
  }
  cues.sort((AudioCue a, AudioCue b) => a.startMs.compareTo(b.startMs));
  return cues;
}
