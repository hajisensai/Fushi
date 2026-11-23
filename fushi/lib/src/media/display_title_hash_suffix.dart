/// 显示名清洗：去掉文件名标题末尾的 CRC 哈希标签与残留扩展名（BUG-4898 / BUG：
/// media-title-crc-suffix-not-cleaned）。
///
/// 没刮到元数据的书 / 漫画以文件名当标题入库，下载工具常在文件名末尾带一段
/// 内容哈希（「十歳の最強魔導師 第16話 前編 [679fb7c9]」）。哈希对读者没有意义，
/// 还把书架卡的标题挤掉一截。判据是全媒体共用的 [cleanImportedTitle]（引擎
/// `media/titles/media_title_clean.dart`）：方括号 / 圆括号、大小写都认、可连续多段，
/// 外加末尾的已知扩展名；出版社 / 版本标签、卷号不动。
///
/// **只改显示，不改存储**：`epub_books.title` 仍是带哈希的原始文件名标题——它是
/// 身份（`bookKey = sanitizeTtuFilename(title)`、统计聚合键、同步资产键、来源扫描
/// 的「已导入」判定 `SourceLibraryScanner.predictTitle`），绝不能经本函数改写。调用点
/// 只在书族的显示出口（`ReaderMediaSource.getDisplayTitleFromMediaItem` 与
/// `displayTitleForBook` 的原名回退），用户自己改过的显示名（override）原样显示、
/// 不清洗。
library;

import 'package:fushi_engine/media/titles/media_title_clean.dart';

/// 去掉 [title] 末尾的 CRC 哈希标签与扩展名；没有原样返回。
///
/// 整个标题只有哈希（去掉后为空）时原样返回：宁可显示哈希也不显示空标题。
String stripTitleHashSuffix(String title) => cleanImportedTitle(title);
