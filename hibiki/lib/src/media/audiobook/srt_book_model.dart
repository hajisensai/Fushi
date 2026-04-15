import 'package:isar/isar.dart';

part 'srt_book_model.g.dart';

/// 独立 SRT 有声书元数据。
///
/// 不依赖 EPUB，由 SRT 字幕文件 + 音频目录共同构成一本"书"。
/// 对应的 [AudioCue] 存放在同一 Isar 库，[AudioCue.bookUid] = [uid]，
/// [AudioCue.chapterHref] = `srt://default`（单章节策略）。
@Collection()
class SrtBook {
  Id id = Isar.autoIncrement;

  /// 书的唯一标识，格式 `srtbook_<timestamp_ms>`。
  @Index(unique: true, replace: true)
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

  /// ッツ Ebook Reader IndexedDB 中的 book ID（0 表示尚未导入 ttu）。
  int ttuBookId = 0;
}
