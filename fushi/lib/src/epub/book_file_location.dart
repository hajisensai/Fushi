import 'package:fushi_core/fushi_core.dart' show EpubBookRow;
import 'package:path/path.dart' as p;

import 'package:fushi/src/utils/misc/reveal_in_file_manager.dart';

/// 书在磁盘上的主文件绝对路径。
///
/// EPUB / PDF / 漫画是同一张 `EpubBooks` 表上的三种书身份，路径列的语义完全一致：
/// [EpubBookRow.extractDir] 是书目录绝对路径，[EpubBookRow.epubPath] 是目录内的主文件
/// （EPUB 的 `.epub`、PDF 的 `kPdfFileName`、漫画的 `manga.json`）。因此这里不按
/// `format` 分叉——三种书取路径是同一件事。
///
/// 少数历史行 / 数据根迁移过的行把 `epubPath` 写成绝对路径。不必为此加分支：
/// [p.join] 的契约就是后段为绝对路径时丢弃前段，两种形态自然收敛到同一条语句。
String bookMainFilePath(EpubBookRow row) =>
    p.join(row.extractDir, row.epubPath);

/// 在系统文件管理器里定位这本书：优先选中主文件本身（漫画即直接选中 `manga.json`，
/// 用户要手改 mokuro 数据时省掉一层目录），主文件不在了再退回打开书目录。
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
