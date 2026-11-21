/// PDF 书目录（`<fushi_books>/<bookKey>/`）的磁盘布局约定，唯一定义处。
///
/// 放在引擎层、不依赖 pdfrx 等插件，导入器（`PdfImporter`）、阅读器与
/// storage 层（孤儿书目录识别）都引用这里，不各自写字面量。
abstract final class PdfBookLayout {
  /// 书目录内固定的 PDF 文件名。阅读器按 `extractDir/epubPath` 还原绝对路径，
  /// 故此名与 `epub_books.epub_path` 列必须一致（存量持久化名，冻结）。
  static const String pdfFileName = 'document.pdf';
}
