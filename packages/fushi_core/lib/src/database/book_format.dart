/// 书身份格式的值域(`EpubBooks.format` 列)。
///
/// 三种书共用同一张 `EpubBooks` 表和同一个书目录 `<hoshi_books>/<bookKey>/`,
/// `format` 是**阅读器路由的唯一真相源**:`'pdf'` 进 PDF 阅读器、`'manga'` 进漫画
/// 阅读器、`'epub'`(默认)进 EPUB 阅读器。
///
/// ## 为什么要收敛成枚举
///
/// 列上没有 CHECK 约束,写入侧此前是裸 `String`。一旦写进枚举外的值,路由
/// (`reader_fushi_source.dart` 的 `isPdf ? ... : isManga ? ... : 本源`)会**全部
/// fallback 到 EPUB 阅读器** —— 不是静默隐身,而是用错阅读器打开、在解析路径出错。
/// 收敛成枚举后,「写进未知值」在**编译期**就不可表达。
///
/// ## 为什么没有加 CHECK 约束(刻意的取舍,别当遗漏)
///
/// SQLite 不支持 `ALTER TABLE ADD CONSTRAINT`,加 CHECK 只能重建 `epub_books`
/// 这张核心书表;重建时任何越界行都会让**老库升级中断、app 直接打不开**。而实际
/// 风险面已经为零:落库点只有三个,两个是常量(`pdf_importer` / `manga_importer`),
/// 一个是列默认值 `'epub'`;唯一收裸串的入口 `updateEpubBookFormat` 已改成收本枚举。
/// 实测生产库(`user_version=60`,19 行)`format` 全为 `'epub'`,零 NULL 零越界。
/// 为覆盖「绕过 DAO 直接写裸 SQL」这一本仓不存在的用法去重建书表,不划算。
///
/// [dbValue] 即落库串,**逐字节冻结**(存量持久化名不追改;守卫:
/// `test/tools/book_format_discipline_guard_test.dart`)。
enum BookFormat {
  /// 文字书:EPUB / TextToEpub / 有声书配对壳。列默认值,既有全部行都是它。
  epub('epub'),

  /// pdfrx 渲染的真 PDF。`chapterCount`=页数、`chaptersJson`=`'[]'`。
  pdf('pdf'),

  /// 漫画 OCR(第三种书)。`chapterCount`=页数、`chaptersJson`=`'[]'`。
  manga('manga');

  const BookFormat(this.dbValue);

  /// `EpubBooks.format` 列的落库串。
  final String dbValue;

  /// 严格解析:未知串返回 null(调用方自行决定回退/报错)。
  static BookFormat? tryParse(String? raw) {
    for (final BookFormat format in values) {
      if (format.dbValue == raw) return format;
    }
    return null;
  }

  /// 宽松解析:未知串按 [BookFormat.epub] 处理。
  ///
  /// 这**不是**在容忍脏数据,而是把路由层早就在做的事显式化:未知 format 今天就会
  /// fallback 到 EPUB 阅读器。写成一个有名字的函数,读代码的人一眼看得见这条回退,
  /// 而不用去 `isPdf ? ... : isManga ? ... : 本源` 的三元里倒推。
  static BookFormat parseOrEpub(String? raw) =>
      tryParse(raw) ?? BookFormat.epub;

  /// 是否是「按页翻」的图像书(PDF / 漫画)。
  ///
  /// 这类书的 `chapterCount` 存的是**页数**、`chaptersJson` 是 `'[]'`,阅读位置的
  /// `sectionIndex` 是**页码**而不是章序号 —— 任何「按章计数」的下游(尤其向
  /// Bangumi 上报章进度)都必须先用它把这两种书排除掉,否则会把页码当章数报出去。
  bool get isPagedImageBook =>
      this == BookFormat.pdf || this == BookFormat.manga;
}
