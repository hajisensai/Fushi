import 'package:fushi_core/fushi_core.dart' show BookFormat, EpubBookRow;
import 'package:path/path.dart' as p;

import 'package:fushi/src/utils/misc/reveal_in_file_manager.dart';

/// 书在磁盘上的主产物绝对路径——「这本书的源在哪」的**唯一**真相源。
/// `book_format_rebuild.dart` 的探测、PDF 阅读器开文件、书架「打开文件位置」都从
/// 这里取，不各自拼一份。
///
/// EPUB / PDF / 漫画是同一张 `EpubBooks` 表上的三种书身份，但主产物形态不同，
/// **不能**一律 `p.join(extractDir, epubPath)`：
/// - `epub`：主产物是**解压书目录本身**。本仓导入即解压、从不在书目录里留一份
///   独立 `.epub`；[EpubBookRow.epubPath] 只是导入时的原始文件名，拼出来的路径
///   永远指不到真实文件（BUG-088 就此坏过一次：同步靠它判「文件存在」，静默跳过
///   了每一次上传）。TextToEpub 文本书、有声书配对壳同属此类。
/// - `pdf`：`extractDir/document.pdf`，导入时真的拷进去了。
/// - `manga`：`extractDir/manga.json`，用户手改 mokuro 数据要的就是它。
///
/// 少数历史行 / 数据根迁移过的行把 `epubPath` 写成绝对路径。Windows 盘符形态
/// （`C:\…`）由 [p.join] 契约丢弃前段；POSIX 风格 `/…` 在 Windows 只是 root-relative，
/// 盘符会被保留。当代所有写入方都写相对文件名，这里不为历史形态加分支。
String bookMainFilePath(EpubBookRow row) {
  final BookFormat format = BookFormat.parseOrEpub(row.format);
  return switch (format) {
    BookFormat.epub => row.extractDir,
    BookFormat.pdf || BookFormat.manga => p.join(row.extractDir, row.epubPath),
  };
}

/// 在系统文件管理器里定位这本书：优先选中主产物本身（漫画即直接选中 `manga.json`，
/// 用户要手改 mokuro 数据时省掉一层目录），主产物不在了再退回打开书目录。
/// EPUB 行的主产物就是书目录，只有一个目标，不会重复定位同一处。
///
/// [reveal] 只为测试注入。返回 false = 两个目标都打不开（移动端无契约、书目录已被
/// 删除、或文件管理器启动失败），调用方必须提示而不是静默。
Future<bool> revealBookLocation(
  EpubBookRow row, {
  Future<bool> Function(String path) reveal = revealInFileManager,
}) async {
  final String mainFile = bookMainFilePath(row);
  if (await reveal(mainFile)) return true;
  if (mainFile == row.extractDir) return false;
  return reveal(row.extractDir);
}
