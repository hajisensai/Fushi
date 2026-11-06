/// 阅读器侧「按需取章」的统一接口：WebView 请求到一章正文文件、而它还是占位页
/// （带 `kLnReaderPendingChapterAttribute`）时，先把正文取回写进解压树。
///
/// 两个实现：LNReader 在线书（`LnReaderOnlineChapterLoader`，插件取章）与网页
/// 小说书（`WebNovelChapterLoader`，无界面 WebView 取页 + Rust 提取）。阅读器只认
/// 这个接口，不分来源。
abstract interface class OnlineNovelChapterLoader {
  /// [filePath] 对应的章（0 基）；不是本书的正文文件返回 null。
  int? chapterIndexForFile(String filePath);

  /// 确保 [filePath] 这一章已有正文。返回 true = 占位页刚换成正文、调用方还没
  /// 确认过（调用方据此丢掉这一章的缓存）；不是本书正文 / 早已确认过返回 false。
  /// 取不到抛出（调用方照常下发占位页并提示原因）。
  Future<bool> ensureLoaded(String filePath);
}
