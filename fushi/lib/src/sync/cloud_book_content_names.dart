import 'package:fushi_engine/sync/ttu_filename.dart';

/// 云盘书文件夹里「书内容资产」的命名契约（写入方 SyncManager 与读取方
/// CloudRemoteBookClient / 对比弹窗 / importRemoteBookFolder 共用，杜绝各写各的判据）。
///
/// - EPUB：`<sanitizeTtuFilename(title)>.epub`。
/// - 漫画包（书目录整树 zip，根含 `manga.json`）：
///   `<sanitizeTtuFilename(title)>.manga.zip`（所有者 2026-10-21：书籍和漫画分开）。
///   旧版本把漫画包也上传成 `<title>.epub`，读取方仍认旧名；下载后一律按内容嗅探
///   （`isMangaPackage`）分流，扩展名只决定「这是不是书内容资产」。
///
/// 两个后缀都不以 `progress_` / `statistics_` / `audioBook_` 开头的前缀起始（那几个是
/// 三件套的前缀判据，按文件名**开头**匹配），资产名的开头是书名，与旧 `.epub` 同形。
const String kCloudEpubContentSuffix = '.epub';

/// 云盘漫画包资产的后缀（双段扩展名）。
const String kCloudMangaContentSuffix = '.manga.zip';

/// 本书 EPUB 内容资产在云盘书文件夹里的文件名。
String cloudEpubContentFileName(String bookTitle) =>
    '${sanitizeTtuFilename(bookTitle)}$kCloudEpubContentSuffix';

/// 本书漫画包内容资产在云盘书文件夹里的文件名。
String cloudMangaContentFileName(String bookTitle) =>
    '${sanitizeTtuFilename(bookTitle)}$kCloudMangaContentSuffix';

/// [name] 是否是书内容资产（`.epub` 或 `.manga.zip`，大小写不敏感）。
bool isRemoteBookContentName(String name) {
  final String lower = name.toLowerCase();
  return lower.endsWith(kCloudEpubContentSuffix) ||
      lower.endsWith(kCloudMangaContentSuffix);
}

/// 从书文件夹的文件名里挑出要下载的内容资产：优先新名 `.manga.zip`，其次 `.epub`，
/// 都没有返回 null。两种并存理论上不会发生（写入方远端已有任一名就不再传），真出现
/// 时取新名——它只可能由新版写入，内容最新。
T? pickRemoteBookContentEntry<T>(
  Iterable<T> entries,
  String Function(T entry) nameOf,
) {
  T? epub;
  for (final T entry in entries) {
    final String lower = nameOf(entry).toLowerCase();
    if (lower.endsWith(kCloudMangaContentSuffix)) return entry;
    if (epub == null && lower.endsWith(kCloudEpubContentSuffix)) epub = entry;
  }
  return epub;
}

/// 内容资产名去掉内容后缀后的书名部分（`.manga.zip` 去两段，`.epub` 去一段）。
/// 不是内容资产名时原样返回。
String remoteBookContentBaseName(String name) {
  final String lower = name.toLowerCase();
  if (lower.endsWith(kCloudMangaContentSuffix)) {
    return name.substring(0, name.length - kCloudMangaContentSuffix.length);
  }
  if (lower.endsWith(kCloudEpubContentSuffix)) {
    return name.substring(0, name.length - kCloudEpubContentSuffix.length);
  }
  return name;
}
