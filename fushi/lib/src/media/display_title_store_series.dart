/// 显示名清洗：去掉电子书店标题里的系列注记 `<系列名>` 与跟在它后面的文库标签
/// `(レーベル)`（设计稿 H4）。
///
/// Kindle / BookWalker 卖的轻小说，书名一律写成
/// 「Re：ゼロから始める異世界生活 1<Re：ゼロから始める異世界生活> (MF文庫J)」——
/// 正文 + 卷号，后面尖括号里再写一遍系列名，最后是文库名。EPUB 元数据原样带进
/// `epub_books.title`，首页 / 书架卡宽度只够显示一行时就成了
/// 「Re：ゼロから始める異世界生活 1<Re：…」：看起来像两段标题粘在一起，卷号还
/// 被挤在中间。系列名已经是正文的前缀、文库名对读者没有信息量，显示时只留
/// 「Re：ゼロから始める異世界生活 1」。
///
/// **只改显示，不改存储**：与 [stripTitleHashSuffix] 同一条红线——`title` 是身份
/// （`bookKey = sanitizeTtuFilename(title)`、统计聚合键、同步资产键），绝不经本
/// 函数改写；用户自己改过的显示名（override）原样显示、不清洗。
///
/// 注记判据本体在引擎 `store_series_annotation.dart`（分卷归组 `parseBookSeriesKey`
/// 也认这种写法，判据只有一份），本文件只做显示出口的组合。
library;

import 'package:fushi/src/media/display_title_hash_suffix.dart';
import 'package:fushi_engine/media/collections/store_series_annotation.dart';

export 'package:fushi_engine/media/collections/store_series_annotation.dart'
    show stripStoreSeriesAnnotation;

/// 书族显示名的统一清洗：先去文件名哈希后缀（[stripTitleHashSuffix]），再去书店
/// 系列注记（[stripStoreSeriesAnnotation]）。书族显示出口（`ReaderMediaSource
/// .getDisplayTitleFromMediaItem` 与 `displayTitleForBook` 的原名回退）只调这一个。
String cleanBookDisplayTitle(String title) =>
    stripStoreSeriesAnnotation(stripTitleHashSuffix(title));
