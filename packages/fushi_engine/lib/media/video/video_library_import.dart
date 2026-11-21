/// 视频入库的纯助手（bookUid 派生、字幕解析）。从 app 的 video_import_dialog.dart
/// 抽出：互联 host 收上传视频、无头服务端扫描库都要用，对话框只留 UI。
library;

import 'dart:isolate';

import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_engine/media/video/external_video.dart'
    show decodedSourceBasename;
import 'package:fushi_engine/media/video/subtitle/plain_subtitle_overlap.dart';
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
  for (int i = 2; ; i++) {
    final String candidate = '$base ($i)';
    if (!existingKeys.contains(candidate)) return candidate;
  }
}

/// [parseSubtitleCues] 在调用方 isolate 上直接解析的内容上限（UTF-16 码元数）。
///
/// 实测（JIT，本机）：1500 条的 SRT（86K 字符）约 3 ms、1500 条带特效标签的 ASS
/// （155K）约 6 ms、8000 行的特效字幕 ASS（830K）约 33 ms、30000 行（3.1M，
/// 卡拉 OK / 招牌特效很重的字幕组 ASS）约 124 ms。64K 以内解析在 2 ms 上下，起一个
/// isolate 的固定开销反而更大，就地解析；超过的交给 [Isolate.run]。
const int kSubtitleParseInlineMaxChars = 64 * 1024;

/// 按字幕扩展名路由到对应解析器，返回按 [AudioCue.startMs] 升序排序的 cue。
///
/// 导入对话框、来源扫描、互联 host 收字幕、远端视频下载都在 UI isolate 上调它
/// （#3722 video-36g）：大字幕整段同步解析会把 UI 冻住上百毫秒，扫一个满是特效
/// 字幕的库就是一串卡顿。所以超过 [kSubtitleParseInlineMaxChars] 的内容在
/// [Isolate.run] 里解析；小内容就地解析。
///
/// 只解析，不读文件、不判编码：判编码可能要走移动端的平台通道（只在根 isolate
/// 可用），调用方先 `readTextWithEncoding` 再交进来。
/// - `srt` → [SrtParser]
/// - `vtt` → [VttParser]
/// - `ass` / `ssa` → [AssParser]
/// - 其他 → 返回以 [ArgumentError] 完成的 Future（在起 isolate 之前判）
Future<List<AudioCue>> parseSubtitleCues({
  required String content,
  required String format,
  required String bookUid,
}) async {
  final String normalized = format.toLowerCase();
  if (!_kSubtitleFormats.contains(normalized)) {
    throw ArgumentError.value(format, 'format', 'Unsupported subtitle format');
  }
  if (content.length <= kSubtitleParseInlineMaxChars) {
    return _parseSubtitleCuesSync(content, normalized, bookUid);
  }
  return Isolate.run(
    () => _parseSubtitleCuesSync(content, normalized, bookUid),
    debugName: 'parseSubtitleCues',
  );
}

const Set<String> _kSubtitleFormats = <String>{'srt', 'vtt', 'ass', 'ssa'};

/// [parseSubtitleCues] 的同步核心；[format] 已小写且在 [_kSubtitleFormats] 里。
List<AudioCue> _parseSubtitleCuesSync(
  String content,
  String format,
  String bookUid,
) {
  final List<AudioCue> cues = switch (format) {
    // 纯文本字幕的部分重叠收口，与播放器走的 parseSubtitleContent 同一语义。
    'srt' => clampPlainTextCueOverlaps(
      SrtParser.parseString(content: content, bookKey: bookUid),
    ),
    'vtt' => clampPlainTextCueOverlaps(
      VttParser.parseString(content: content, bookKey: bookUid),
    ),
    _ => AssParser.parseString(content: content, bookKey: bookUid),
  };
  cues.sort((AudioCue a, AudioCue b) => a.startMs.compareTo(b.startMs));
  return cues;
}
