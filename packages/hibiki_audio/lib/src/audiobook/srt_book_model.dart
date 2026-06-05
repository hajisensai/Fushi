import 'audiobook_model.dart' show AudioCue;

/// 独立 SRT 有声书元数据。
///
/// 不依赖 EPUB，由 SRT 字幕文件 + 音频目录共同构成一本"书"。
/// 对应的 [AudioCue] 存放在同一数据库，[AudioCue.bookUid] = [uid]，
/// [AudioCue.chapterHref] = `srt://default`（单章节策略）。
class SrtBook {
  int? id;

  /// 书的唯一标识，格式 `srtbook_<timestamp_ms>`。
  late String uid;

  /// 书名（用户可编辑，默认取自 SRT 文件名）。
  late String title;

  /// 作者（可选）。
  String? author;

  /// 音频文件目录（本地绝对路径）。folder 模式下非 null，files 模式下为 null。
  String? audioRoot;

  /// 手动选择的音频文件路径列表。files 模式下非 null，folder 模式下为 null。
  List<String>? audioPaths;

  /// SRT 文件路径（本地绝对路径）。
  late String srtPath;

  /// 封面图片路径（可选，本地绝对路径）。
  String? coverPath;

  /// 导入时间戳（milliseconds since epoch），用于书架排序。
  late int importedAt;

  /// 关联的 EpubBooks.bookKey（空串表示 standalone SRT，不依赖 EPUB）。
  String bookKey = '';
}
