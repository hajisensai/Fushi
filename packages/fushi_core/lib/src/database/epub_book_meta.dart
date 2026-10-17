/// `epub_books` 的瘦投影：只带身份 / 展示 / 归档元数据列，**不带**
/// `chaptersJson` / `tocJson` / `sourceMetadata` 三个大 TEXT 列（每本几十到几百 KB）。
///
/// 书架映射、统计事实面、导入重复检查、远端去重等十来处调用方只需要 title / uid /
/// importedAt 之类的小列，却一直走 `getAllEpubBooks()` 把整库章节 JSON 从 SQLite
/// 拉出来再丢掉——每导入一本书就重复一次，库越大导入越慢。需要章节 JSON 的调用方
/// （阅读器打开、备份、同步全量比对）继续用 `EpubBookRow`。
class EpubBookMeta {
  const EpubBookMeta({
    required this.bookKey,
    required this.uid,
    required this.title,
    required this.format,
    required this.importedAt,
    required this.extractDir,
    this.completedAt,
    this.localAddedAt,
  });

  /// 跨设备书身份（= sanitizeTtuFilename(title)），主键。
  final String bookKey;

  /// 本机稳定 uid（v81），空串 = 异常旧行。
  final String uid;
  final String title;

  /// `'epub'` / `'pdf'` / `'manga'`（见 `BookFormat`）。
  final String format;

  /// 原始入库时刻（毫秒，跨设备保留；互联下载的书 = 对端入库时刻）。展示与
  /// 「导入时间」排序用。
  final int importedAt;

  /// 本机开始拥有这本书的时刻（毫秒，v118，设备本地）。首页「最近添加」用它；
  /// null = 时刻未知。语义见 `EpubBooks.localAddedAt`。
  final int? localAddedAt;
  final String extractDir;
  final DateTime? completedAt;
}
