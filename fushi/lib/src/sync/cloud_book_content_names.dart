import 'package:fushi_engine/sync/ttu_filename.dart';

/// 云盘书文件夹里「书内容资产」的命名契约（写入方 SyncManager 与读取方
/// CloudRemoteBookClient / 对比弹窗 / importRemoteBookFolder 共用，杜绝各写各的判据）。
///
/// - EPUB：`<sanitizeTtuFilename(title)>.epub`。
/// - 漫画包（书目录整树 zip，根含 `manga.json`）：
///   `<sanitizeTtuFilename(title)>.manga.zip`（所有者 2026-10-21：书籍和漫画分开）。
///   旧版本把漫画包也上传成 `<title>.epub`，读取方仍认旧名；下载后一律按内容嗅探
///   （`isMangaPackage`）分流，扩展名只决定「这是不是书内容资产」。
/// - 旧名漫画包的格式标记 [kCloudLegacyMangaMarkerAssetName]：本地持有这本漫画的设备
///   发现远端只有旧名 `<title>.epub` 时补写这个小 sidecar，远端清单据此把旧包归漫画。
///   旧包本身不改名、不删：还没升级的客户端只按 `<title>.epub` 找内容。没有设备补标记
///   的旧包，能做区间读的后端由远端清单读 zip 中央目录判型（`CloudLegacyMangaSniffer`）。
///
/// 两个后缀都不以 `progress_` / `statistics_` / `audioBook_` 开头的前缀起始（那几个是
/// 三件套的前缀判据，按文件名**开头**匹配），资产名的开头是书名，与旧 `.epub` 同形。
const String kCloudEpubContentSuffix = '.epub';

/// 云盘漫画包资产的后缀（双段扩展名）。
const String kCloudMangaContentSuffix = '.manga.zip';

/// 旧名漫画包的格式标记 sidecar（与 `tags.json` 同级）：书文件夹里有它时，旧版本以
/// `<title>.epub` 上传的内容资产是漫画包。内容 `{schemaVersion:1, format:'manga',
/// contentFile:<旧名>}`，读取方只看文件名在不在；不撞 `progress_` / `statistics_` /
/// `audioBook_` 前缀，也不是内容资产名。
const String kCloudLegacyMangaMarkerAssetName = 'manga_content.json';

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

/// 书文件夹里的内容资产**按文件夹文件名**能确认的格式（远端清单据此分架）。
enum CloudBookContentKind { epub, manga }

/// 从书文件夹的文件名里判定内容格式：挑中的内容资产（与下载同一判据
/// [pickRemoteBookContentEntry]）是 `.manga.zip` → [CloudBookContentKind.manga]；
/// `.epub` 且同文件夹有旧名漫画标记 [kCloudLegacyMangaMarkerAssetName] →
/// [CloudBookContentKind.manga]；其余 `.epub` → [CloudBookContentKind.epub]；都没有
/// → null。
///
/// 旧版本把漫画包也传成 `<title>.epub` 且还没有设备补写标记时，单看文件名与 EPUB 无从
/// 区分，如实归 [CloudBookContentKind.epub]；远端清单再按内容判一次
/// （`CloudLegacyMangaSniffer`，仅能区间读的后端），下载导入仍按内容嗅探
/// （`isMangaPackage`）落成漫画。
CloudBookContentKind? cloudBookContentKindOf(Iterable<String> fileNames) {
  final List<String> names = fileNames.toList(growable: false);
  final String? picked = pickRemoteBookContentEntry<String>(
    names,
    (String name) => name,
  );
  if (picked == null) return null;
  if (picked.toLowerCase().endsWith(kCloudMangaContentSuffix)) {
    return CloudBookContentKind.manga;
  }
  return names.contains(kCloudLegacyMangaMarkerAssetName)
      ? CloudBookContentKind.manga
      : CloudBookContentKind.epub;
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
