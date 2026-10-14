import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';
import 'package:path/path.dart' as p;

/// 「从 app 外用 Fushi 打开」时认作书 / 漫画的扩展名（小写、带点）。
///
/// 这是**系统打开方式**的白名单，与 Windows 安装包 `bookassoc` 任务登记的扩展名
/// 逐一对应（守卫 `test/media/import/external_book_test.dart`）。刻意比导入白名单窄：
///
/// - 不收 `.zip`：它同时是词典包扩展名，把 Fushi 挂进所有 zip 的「打开方式」只会添乱；
/// - 不收 `.html` / `.json` / `.xml` / `.md` 等：导入框能把它们转成书，但没有人会
///   想用阅读器去「打开」一个 json。只留 `.txt` 这一个真正当书分发的纯文本格式；
/// - `.mokuro` 收：它就是一卷 OCR 漫画的入口文件。
///
/// 载体身份（书 / PDF / 文本 / 漫画、图片型 EPUB 归漫画）不在这里判，交给导入层的
/// `classifyImportCarrier`——与导入对话框、`fushi_cli library import` 同一判据。
const Set<String> kExternalBookOpenExtensions = <String>{
  '.epub',
  '.pdf',
  '.txt',
  '.cbz',
  '.cbr',
  '.cb7',
  '.mokuro',
};

/// 纯函数：[path] 是不是可以从 app 外直接打开的书 / 漫画文件（只看扩展名）。
bool isSupportedExternalBookFile(String path) =>
    kExternalBookOpenExtensions.contains(p.extension(path).toLowerCase());

/// 纯函数：从 Dart entrypoint 的命令行参数里挑出第一个可打开的书 / 漫画路径。
///
/// 与 `firstExternalVideoArg` 同一约定：跳过 `-` 开头的 flag，只做字符串判定，
/// 存在性检查留给调用方。
String? firstExternalBookArg(List<String> args) {
  for (final String arg in args) {
    if (arg.isEmpty || arg.startsWith('-')) continue;
    if (isSupportedExternalBookFile(arg)) return arg;
  }
  return null;
}

/// 库里与 [title] 同身份的书（`sanitizeTtuFilename` 相同，与 `resolveDuplicateTitle`
/// 判重同一口径）的 bookKey；没有返回 null。
///
/// 外部再次打开同一本书时，导入层按 skip 策略抛 `DuplicateImportCancelledException`
/// （只带拟用标题）；这里把它换回已在库那一本，直接打开它而不是复制一份。
Future<String?> existingBookKeyForTitle(FushiDatabase db, String title) async {
  final String key = sanitizeTtuFilename(title);
  for (final EpubBookMeta meta in await db.getEpubBookMetas()) {
    if (sanitizeTtuFilename(meta.title) == key) return meta.bookKey;
  }
  return null;
}
