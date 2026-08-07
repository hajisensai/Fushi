import 'dart:io';

import 'package:path/path.dart' as p;

/// 书库正文树（epub/manga/pdf 三种书共用）的目录名。
///
/// W2-7：新名 `fushi_books`；历史名 `hoshi_books` 由
/// [migrateLegacyBooksDirectoryAt] 在启动期就地改名。库内含旧目录名的绝对路径
/// 列（`epub_books.extract_dir` / `media_items.image_url`）由 fushi_core v72
/// 迁移同批改写。
const String kBooksDirectoryName = 'fushi_books';

/// 存量旧目录名。旧字面量只允许活在本迁移文件、`AppPaths` 双名搬迁白名单与
/// `BackupService` 的旧归档前缀读侧回退里。
const String kLegacyBooksDirectoryName = 'hoshi_books';

/// 在 [documentsRootPath]（documents 根）下做书库目录的存量改名迁移：新目录
/// 不存在且旧目录存在时 rename（同根同盘 O(1)、内容原样保留）。改名失败（句柄
/// 占用等）不阻塞：上报 [onMigrationError] 后放行——DB 路径列已由 v72 指向新
/// 名，本次启动书打不开，下次启动重试改名即自愈；旧目录留在原地，数据零丢失。
/// 幂等：改名成功后旧目录消失，后续调用 exists 短路。新目录**不在这里创建**
/// （由 `EpubStorage` 等消费方按需建），本函数只负责迁移。
void migrateLegacyBooksDirectoryAt(
  String documentsRootPath, {
  void Function(Object error, StackTrace stack)? onMigrationError,
}) {
  final Directory target =
      Directory(p.join(documentsRootPath, kBooksDirectoryName));
  if (target.existsSync()) return;
  final Directory legacy =
      Directory(p.join(documentsRootPath, kLegacyBooksDirectoryName));
  if (!legacy.existsSync()) return;
  try {
    legacy.renameSync(target.path);
  } catch (e, stack) {
    onMigrationError?.call(e, stack);
  }
}
